import CoreGraphics
import CoreImage
import Foundation
import Vision

public enum ColorMode: String, CaseIterable, Codable, Sendable {
    case color, gray, blackAndWhite

    public var label: String {
        switch self {
        case .color: "Color"
        case .gray: "Grayscale"
        case .blackAndWhite: "Black & White"
        }
    }
}

public struct ProcessingOptions: Sendable {
    public var colorMode: ColorMode
    /// Remove the dark feeder backing and blank fill the scanner adds around a page narrower or shorter than the scan area.
    public var trimScannerMargins: Bool
    /// Rotate a page that went through the feeder at a slight angle back to level.
    public var straighten: Bool
    public var skipBlankPages: Bool

    public init(colorMode: ColorMode = .color, trimScannerMargins: Bool = true, straighten: Bool = true, skipBlankPages: Bool = true) {
        self.colorMode = colorMode
        self.trimScannerMargins = trimScannerMargins
        self.straighten = straighten
        self.skipBlankPages = skipBlankPages
    }
}

/// An 8-bit luminance copy of an image. Row 0 is the top of the image.
struct GrayBuffer {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(_ image: CGImage, maxDimension: Int? = nil) {
        let scale = maxDimension.map { min(1, Double($0) / Double(max(image.width, image.height))) } ?? 1
        width = max(1, Int((Double(image.width) * scale).rounded()))
        height = max(1, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 255, count: width * height)
        let (w, h) = (width, height)
        pixels.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        self.pixels = pixels
    }

    subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }

    func makeImage() -> CGImage {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}

public enum PageProcessor {
    private static let ciContext = CIContext()

    /// Cleans up one scanned page. Returns nil when the page is blank and blank pages are skipped.
    public static func process(_ image: CGImage, options: ProcessingOptions) -> CGImage? {
        var page = image
        if options.trimScannerMargins, let rect = scannerMarginTrimRect(page), let cropped = page.cropping(to: rect) {
            page = cropped
        }
        if options.straighten, let level = straightened(page) {
            page = level
        }
        if options.skipBlankPages && isBlank(page) {
            return nil
        }
        return convert(page, to: options.colorMode)
    }

    // MARK: Scanner margins

    /// The part of the scan that is paper, in pixel coordinates (top-left origin, as `CGImage.cropping(to:)` expects),
    /// or nil when there is nothing to trim.
    ///
    /// A sheet-fed scan of a page narrower than the feeder shows the dark backing beside the page, and a page shorter
    /// than the requested size is followed by flat, pure-white fill. Edge rows and columns that look like either are
    /// trimmed; a page's own white margins have paper texture and are kept.
    public static func scannerMarginTrimRect(_ image: CGImage) -> CGRect? {
        let gray = GrayBuffer(image, maxDimension: 1200)
        var left = 0, right = gray.width, top = 0, bottom = gray.height

        func isFill(_ values: [UInt8]) -> Bool {
            guard !values.isEmpty else { return false }
            var sum = 0, pureWhite = 0
            for v in values {
                sum += Int(v)
                if v >= 254 { pureWhite += 1 }
            }
            let mean = Double(sum) / Double(values.count)
            return mean < 70 || Double(pureWhite) / Double(values.count) > 0.97
        }
        func column(_ x: Int) -> [UInt8] { (top..<bottom).map { gray[x, $0] } }
        func row(_ y: Int) -> [UInt8] { (left..<right).map { gray[$0, y] } }

        // Repeat so that, e.g., a white strip under a dark strip does not stop either from being trimmed.
        for _ in 0..<3 {
            while left < right - 1, isFill(column(left)) { left += 1 }
            while right - 1 > left, isFill(column(right - 1)) { right -= 1 }
            while top < bottom - 1, isFill(row(top)) { top += 1 }
            while bottom - 1 > top, isFill(row(bottom - 1)) { bottom -= 1 }
        }

        // Step past the blurred boundary between fill and paper.
        let inset = 1
        if left > 0 { left = min(left + inset, right) }
        if right < gray.width { right = max(right - inset, left) }
        if top > 0 { top = min(top + inset, bottom) }
        if bottom < gray.height { bottom = max(bottom - inset, top) }

        guard left > 0 || top > 0 || right < gray.width || bottom < gray.height else { return nil }
        // Something odd, such as an almost entirely black page: keep the whole scan.
        guard (right - left) * (bottom - top) >= gray.width * gray.height / 5 else { return nil }

        let sx = Double(image.width) / Double(gray.width)
        let sy = Double(image.height) / Double(gray.height)
        return CGRect(x: (Double(left) * sx).rounded(), y: (Double(top) * sy).rounded(),
                      width: (Double(right - left) * sx).rounded(), height: (Double(bottom - top) * sy).rounded())
    }

    // MARK: Straightening

    /// The angle in degrees the page's edges are tilted, counterclockwise positive, if a page outline is found.
    public static func skewAngle(_ image: CGImage) -> Double? {
        let request = VNDetectDocumentSegmentationRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let quad = request.results?.first, quad.confidence > 0.5 else { return nil }
        let w = Double(image.width), h = Double(image.height)
        func angle(_ a: CGPoint, _ b: CGPoint) -> Double {
            atan2((b.y - a.y) * h, (b.x - a.x) * w) * 180 / .pi
        }
        // Vision coordinates are normalized with a bottom-left origin.
        let area = abs((quad.topRight.x - quad.topLeft.x) * (quad.topLeft.y - quad.bottomLeft.y))
        guard area > 0.5 else { return nil }
        let top = angle(quad.topLeft, quad.topRight)
        let bottom = angle(quad.bottomLeft, quad.bottomRight)
        let leftSide = angle(quad.bottomLeft, quad.topLeft) - 90
        let rightSide = angle(quad.bottomRight, quad.topRight) - 90
        return (top + bottom + leftSide + rightSide) / 4
    }

    /// The page rotated level, or nil when it is already level (under 0.3°) or the tilt can't be measured reliably.
    /// Only rotates, never crops into the page, so no content is lost.
    public static func straightened(_ image: CGImage) -> CGImage? {
        guard let degrees = skewAngle(image), abs(degrees) >= 0.3, abs(degrees) <= 10 else { return nil }
        return rotated(image, degrees: -degrees)
    }

    /// Rotates by an arbitrary angle about the center, keeping the original size and filling exposed corners white.
    public static func rotated(_ image: CGImage, degrees: Double) -> CGImage? {
        let source = CIImage(cgImage: image)
        let extent = source.extent
        let turn = CGAffineTransform(translationX: extent.midX, y: extent.midY)
            .rotated(by: degrees * .pi / 180)
            .translatedBy(x: -extent.midX, y: -extent.midY)
        let white = CIImage(color: .white).cropped(to: extent)
        let output = source.transformed(by: turn).composited(over: white).cropped(to: extent)
        return ciContext.createCGImage(output, from: extent, format: .RGBA8, colorSpace: image.colorSpace ?? CGColorSpaceCreateDeviceRGB())
    }

    // MARK: Blank pages

    /// True when the page has almost no marks on it. Ignores a thin border where feeder shadows show up.
    public static func isBlank(_ image: CGImage) -> Bool {
        let gray = GrayBuffer(image, maxDimension: 600)
        let mx = gray.width / 20, my = gray.height / 20
        var histogram = [Int](repeating: 0, count: 256)
        for y in my..<(gray.height - my) {
            for x in mx..<(gray.width - mx) { histogram[Int(gray[x, y])] += 1 }
        }
        let total = histogram.reduce(0, +)
        guard total > 0 else { return true }
        // The paper's own brightness: the median.
        var running = 0, paper = 255
        for (level, count) in histogram.enumerated() {
            running += count
            if running * 2 >= total { paper = level; break }
        }
        let inkLevel = max(0, paper - 60)
        let ink = histogram[0..<inkLevel].reduce(0, +)
        return Double(ink) / Double(total) < 0.002
    }

    // MARK: Color

    public static func convert(_ image: CGImage, to mode: ColorMode) -> CGImage {
        switch mode {
        case .color:
            return image
        case .gray:
            return GrayBuffer(image).makeImage()
        case .blackAndWhite:
            var gray = GrayBuffer(image)
            let threshold = otsuThreshold(gray.pixels)
            for i in gray.pixels.indices { gray.pixels[i] = gray.pixels[i] > threshold ? 255 : 0 }
            return gray.makeImage()
        }
    }

    /// The luminance that best separates ink from paper (Otsu's method).
    static func otsuThreshold(_ pixels: [UInt8]) -> UInt8 {
        var histogram = [Double](repeating: 0, count: 256)
        for p in pixels { histogram[Int(p)] += 1 }
        let total = Double(pixels.count)
        let weightedTotal = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset) * $1.element }
        var backgroundWeight = 0.0, backgroundSum = 0.0, best = 0.0, threshold = 127
        for t in 0..<256 {
            backgroundWeight += histogram[t]
            guard backgroundWeight > 0 else { continue }
            let foregroundWeight = total - backgroundWeight
            guard foregroundWeight > 0 else { break }
            backgroundSum += Double(t) * histogram[t]
            let meanBackground = backgroundSum / backgroundWeight
            let meanForeground = (weightedTotal - backgroundSum) / foregroundWeight
            let between = backgroundWeight * foregroundWeight * pow(meanBackground - meanForeground, 2)
            if between > best { best = between; threshold = t }
        }
        return UInt8(threshold)
    }

    // MARK: Quarter turns

    /// Rotates clockwise by `quarterTurns` × 90°.
    public static func rotated(_ image: CGImage, quarterTurns: Int) -> CGImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let w = image.width, h = image.height
        let (nw, nh) = turns % 2 == 0 ? (w, h) : (h, w)
        let isGray = image.colorSpace?.model == .monochrome
        let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                            space: isGray ? CGColorSpaceCreateDeviceGray() : (image.colorSpace ?? CGColorSpaceCreateDeviceRGB()),
                            bitmapInfo: isGray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
        switch turns {
        case 1: ctx.translateBy(x: 0, y: CGFloat(nh)); ctx.rotate(by: -.pi / 2)
        case 2: ctx.translateBy(x: CGFloat(nw), y: CGFloat(nh)); ctx.rotate(by: .pi)
        default: ctx.translateBy(x: CGFloat(nw), y: 0); ctx.rotate(by: .pi / 2)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }
}
