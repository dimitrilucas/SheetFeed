import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportFormat: String, CaseIterable, Codable, Sendable {
    case pdf, tiff, jpeg, png

    public var label: String {
        switch self {
        case .pdf: "PDF"
        case .tiff: "TIFF (multi-page)"
        case .jpeg: "JPEG (one file per page)"
        case .png: "PNG (one file per page)"
        }
    }

    public var fileExtension: String {
        switch self {
        case .pdf: "pdf"
        case .tiff: "tiff"
        case .jpeg: "jpg"
        case .png: "png"
        }
    }

    var type: UTType {
        switch self {
        case .pdf: .pdf
        case .tiff: .tiff
        case .jpeg: .jpeg
        case .png: .png
        }
    }
}

public enum ImageQuality: String, CaseIterable, Codable, Sendable {
    case high, medium, low

    public var label: String { rawValue.capitalized }

    var jpegQuality: Double {
        switch self {
        case .high: 0.9
        case .medium: 0.75
        case .low: 0.5
        }
    }
}

public struct ExportPage: Sendable {
    public let image: CGImage
    public let dpi: Double
    public let colorMode: ColorMode

    public init(image: CGImage, dpi: Double, colorMode: ColorMode) {
        self.image = image
        self.dpi = dpi
        self.colorMode = colorMode
    }

    /// Page size in PDF points (1/72 inch).
    var pointSize: CGSize {
        CGSize(width: Double(image.width) / dpi * 72, height: Double(image.height) / dpi * 72)
    }
}

public enum ExportError: LocalizedError {
    case noPages
    case couldNotCreate(String)

    public var errorDescription: String? {
        switch self {
        case .noPages: "There are no pages to save."
        case .couldNotCreate(let what): "Could not create \(what)."
        }
    }
}

public enum Exporter {
    /// Writes the pages and returns the files written. For JPEG and PNG with several pages, `url` is the base name and
    /// pages are written as "name-1.jpg", "name-2.jpg", ….
    @discardableResult
    public static func export(_ pages: [ExportPage], format: ExportFormat, quality: ImageQuality, searchable: Bool,
                              to url: URL, progress: ((Int) -> Void)? = nil) throws -> [URL] {
        try export(count: pages.count, page: { pages[$0] }, format: format, quality: quality, searchable: searchable,
                   to: url, progress: progress)
    }

    /// Like `export(_:…)`, loading each page only when it is written so long documents don't fill memory.
    @discardableResult
    public static func export(count: Int, page: (Int) throws -> ExportPage, format: ExportFormat, quality: ImageQuality,
                              searchable: Bool, to url: URL, progress: ((Int) -> Void)? = nil) throws -> [URL] {
        guard count > 0 else { throw ExportError.noPages }
        switch format {
        case .pdf:
            let title = url.deletingPathExtension().lastPathComponent
            try makePDF(count: count, page: page, quality: quality, searchable: searchable, title: title, progress: progress)
                .write(to: url, options: .atomic)
            return [url]
        case .tiff:
            try writeImages(count: count, page: page, type: .tiff, quality: quality, to: url, progress: progress)
            return [url]
        case .jpeg, .png:
            if count == 1 {
                try writeImages(count: 1, page: page, type: format.type, quality: quality, to: url, progress: progress)
                return [url]
            }
            let base = url.deletingPathExtension()
            var written: [URL] = []
            for index in 0..<count {
                let pageURL = base.deletingLastPathComponent()
                    .appendingPathComponent("\(base.lastPathComponent)-\(index + 1)")
                    .appendingPathExtension(format.fileExtension)
                try writeImages(count: 1, page: { _ in try page(index) }, type: format.type, quality: quality, to: pageURL, progress: nil)
                written.append(pageURL)
                progress?(index + 1)
            }
            return written
        }
    }

    /// A file name like "Scan 2026-10-31 at 08.15.32".
    public static func defaultName(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "'Scan' yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }

    // MARK: PDF

    public static func makePDF(_ pages: [ExportPage], quality: ImageQuality, searchable: Bool, title: String? = nil,
                               progress: ((Int) -> Void)? = nil) throws -> Data {
        try makePDF(count: pages.count, page: { pages[$0] }, quality: quality, searchable: searchable, title: title, progress: progress)
    }

    public static func makePDF(count: Int, page pageAt: (Int) throws -> ExportPage, quality: ImageQuality, searchable: Bool,
                               title: String? = nil, progress: ((Int) -> Void)? = nil) throws -> Data {
        let data = NSMutableData()
        var info: [CFString: Any] = [kCGPDFContextCreator: "SheetFeed"]
        if let title { info[kCGPDFContextTitle] = title }
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, info as CFDictionary) else {
            throw ExportError.couldNotCreate("the PDF")
        }
        for index in 0..<count {
            let page = try pageAt(index)
            var box = CGRect(origin: .zero, size: page.pointSize)
            ctx.beginPage(mediaBox: &box)
            ctx.interpolationQuality = .high
            ctx.draw(try embeddable(page, quality: quality), in: box)
            if searchable, let lines = try? TextRecognizer.recognize(page.image) {
                drawInvisibleText(lines, in: box, ctx: ctx)
            }
            ctx.endPage()
            progress?(index + 1)
        }
        ctx.closePDF()
        return data as Data
    }

    /// The image in the form that keeps the PDF small: JPEG data (which PDF stores as-is) for color and gray,
    /// 1-bit for black & white.
    static func embeddable(_ page: ExportPage, quality: ImageQuality) throws -> CGImage {
        if page.colorMode == .blackAndWhite {
            return oneBit(page.image)
        }
        let data = try encode(page.image, type: .jpeg, quality: quality, dpi: page.dpi)
        guard let provider = CGDataProvider(data: data as CFData),
              let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw ExportError.couldNotCreate("a page image")
        }
        return jpeg
    }

    /// Lays the recognized text over the page image without drawing it, so the PDF can be searched and text selected.
    static func drawInvisibleText(_ lines: [RecognizedLine], in box: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for line in lines {
            let rect = CGRect(x: box.minX + line.box.minX * box.width, y: box.minY + line.box.minY * box.height,
                              width: line.box.width * box.width, height: line.box.height * box.height)
            guard rect.width > 1, rect.height > 1, !line.text.isEmpty else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.8, nil)
            let attributed = NSAttributedString(string: line.text, attributes: [.init(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            var descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(ctLine, nil, &descent, nil)
            guard width > 0 else { continue }
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: rect.minX, y: rect.minY + descent)
            ctx.scaleBy(x: rect.width / width, y: 1)
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    // MARK: Images

    static func writeImages(count: Int, page pageAt: (Int) throws -> ExportPage, type: UTType, quality: ImageQuality,
                            to url: URL, progress: ((Int) -> Void)?) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, count, nil) else {
            throw ExportError.couldNotCreate(url.lastPathComponent)
        }
        for index in 0..<count {
            let page = try pageAt(index)
            let image = page.colorMode == .blackAndWhite && type != .jpeg ? oneBit(page.image) : page.image
            CGImageDestinationAddImage(destination, image, properties(type: type, quality: quality, dpi: page.dpi, colorMode: page.colorMode))
            progress?(index + 1)
        }
        guard CGImageDestinationFinalize(destination) else { throw ExportError.couldNotCreate(url.lastPathComponent) }
    }

    static func encode(_ image: CGImage, type: UTType, quality: ImageQuality, dpi: Double, colorMode: ColorMode = .color) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw ExportError.couldNotCreate("an image")
        }
        CGImageDestinationAddImage(destination, image, properties(type: type, quality: quality, dpi: dpi, colorMode: colorMode))
        guard CGImageDestinationFinalize(destination) else { throw ExportError.couldNotCreate("an image") }
        return data as Data
    }

    static func properties(type: UTType, quality: ImageQuality, dpi: Double, colorMode: ColorMode) -> CFDictionary {
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if type == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = quality.jpegQuality }
        if type == .tiff {
            // CCITT Group 4 for black & white, LZW otherwise.
            props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: colorMode == .blackAndWhite ? 4 : 5]
        }
        return props as CFDictionary
    }

    /// Packs an image that is already black and white into 1 bit per pixel.
    static func oneBit(_ image: CGImage) -> CGImage {
        let gray = GrayBuffer(image)
        let bytesPerRow = (gray.width + 7) / 8
        var packed = [UInt8](repeating: 0, count: bytesPerRow * gray.height)
        for y in 0..<gray.height {
            for x in 0..<gray.width where gray[x, y] >= 128 {
                packed[y * bytesPerRow + x / 8] |= 0x80 >> UInt8(x % 8)
            }
        }
        return CGImage(width: gray.width, height: gray.height, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: CGDataProvider(data: Data(packed) as CFData)!, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }
}
