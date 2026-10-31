import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import ScanKit

// MARK: Synthetic pages

/// An RGB image filled by `shade(x, y)` (row 0 at the top), optionally with text drawn on it.
private func makeImage(width: Int, height: Int, text: String? = nil, fontSize: CGFloat = 60,
                       shade: (Int, Int) -> UInt8) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let buffer = ctx.data!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            let v = shade(x, y)
            let i = (y * width + x) * 4
            buffer[i] = v; buffer[i + 1] = v; buffer[i + 2] = v
        }
    }
    if let text {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font]))
        ctx.textPosition = CGPoint(x: 60, y: CGFloat(height) - 200)
        CTLineDraw(line, ctx)
    }
    return ctx.makeImage()!
}

/// Off-white paper with a little sensor noise, like a real scan.
private func paper(_ x: Int, _ y: Int) -> UInt8 { UInt8(236 + (x * 7 + y * 13) % 9) }

// MARK: Tests

@Test func quarterTurnClockwiseMovesLeftToTop() {
    let image = makeImage(width: 40, height: 20) { x, _ in x < 20 ? 0 : 255 }
    let turned = PageProcessor.rotated(image, quarterTurns: 1)
    #expect(turned.width == 20 && turned.height == 40)
    let gray = GrayBuffer(turned)
    #expect(gray[10, 5] < 30)    // top half: what was on the left
    #expect(gray[10, 35] > 225)  // bottom half: what was on the right
    let back = PageProcessor.rotated(turned, quarterTurns: -1)
    #expect(GrayBuffer(back)[5, 10] < 30)
}

@Test func trimsFeederBackingAndWhiteFillButNotPaper() throws {
    // A 700×1000 page in an 850×1100 scan: dark backing to the right, pure-white fill below.
    let scan = makeImage(width: 850, height: 1100) { x, y in
        if y >= 1000 { return 255 }
        if x >= 700 { return UInt8(25 + (x + y) % 11) }
        return paper(x, y)
    }
    let rect = try #require(PageProcessor.scannerMarginTrimRect(scan))
    #expect(abs(rect.minX) <= 2 && abs(rect.minY) <= 2)
    #expect(abs(rect.width - 700) <= 6)
    #expect(abs(rect.height - 1000) <= 6)

    let plainPage = makeImage(width: 850, height: 1100, text: "Margins stay", shade: paper)
    #expect(PageProcessor.scannerMarginTrimRect(plainPage) == nil)
}

@Test func detectsBlankPages() {
    #expect(PageProcessor.isBlank(makeImage(width: 850, height: 1100, shade: paper)))
    #expect(!PageProcessor.isBlank(makeImage(width: 850, height: 1100, text: "Not blank at all", shade: paper)))
}

@Test func straightensATiltedPage() throws {
    let level = makeImage(width: 850, height: 1100) { x, y in
        (x > 100 && x < 750 && y > 100 && y < 1000) ? 245 : 20
    }
    let tilted = try #require(PageProcessor.rotated(level, degrees: 3))
    let angle = try #require(PageProcessor.skewAngle(tilted))
    #expect(abs(angle - 3) < 1)
    #expect(PageProcessor.straightened(level) == nil)
}

@Test func blackAndWhiteIsPureBlackAndWhite() {
    let page = makeImage(width: 400, height: 300, text: "Ink", shade: paper)
    let bw = GrayBuffer(PageProcessor.convert(page, to: .blackAndWhite))
    #expect(bw.pixels.allSatisfy { $0 == 0 || $0 == 255 })
    #expect(bw.pixels.contains(0) && bw.pixels.contains(255))
}

@Test func searchablePDFHasTextPagesAndSize() throws {
    let page = makeImage(width: 1700, height: 2200, text: "Quarterly invoice SheetFeed 2026", shade: paper)
    let pages = [ExportPage(image: page, dpi: 200, colorMode: .color), ExportPage(image: page, dpi: 200, colorMode: .gray)]
    let data = try Exporter.makePDF(pages, quality: .medium, searchable: true)
    let pdf = try #require(PDFDocument(data: data))
    #expect(pdf.pageCount == 2)
    let bounds = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
    #expect(abs(bounds.width - 612) < 1 && abs(bounds.height - 792) < 1)  // US Letter in points
    #expect(pdf.string?.contains("SheetFeed") == true)
    #expect(data.count < 2_000_000)  // stored as JPEG, not raw pixels

    let plain = try #require(PDFDocument(data: try Exporter.makePDF(pages, quality: .medium, searchable: false)))
    #expect((plain.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}

@Test func writesMultiPageTiffAndPerPageJpegs() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let page = makeImage(width: 400, height: 500, text: "Hi", shade: paper)
    let bw = PageProcessor.convert(page, to: .blackAndWhite)
    let pages = [ExportPage(image: page, dpi: 150, colorMode: .color), ExportPage(image: bw, dpi: 150, colorMode: .blackAndWhite)]

    let tiff = dir.appendingPathComponent("doc.tiff")
    #expect(try Exporter.export(pages, format: .tiff, quality: .high, searchable: false, to: tiff) == [tiff])
    let source = try #require(CGImageSourceCreateWithURL(tiff as CFURL, nil))
    #expect(CGImageSourceGetCount(source) == 2)

    let jpegs = try Exporter.export(pages, format: .jpeg, quality: .high, searchable: false, to: dir.appendingPathComponent("doc.jpg"))
    #expect(jpegs.map(\.lastPathComponent) == ["doc-1.jpg", "doc-2.jpg"])
    #expect(jpegs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
}

@Test func defaultNameIsReadableAndSortable() {
    var parts = DateComponents()
    parts.year = 2026; parts.month = 10; parts.day = 31; parts.hour = 8; parts.minute = 5; parts.second = 9
    let date = Calendar.current.date(from: parts)!
    #expect(Exporter.defaultName(for: date) == "Scan 2026-10-31 at 08.05.09")
}
