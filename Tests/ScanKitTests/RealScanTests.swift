import Foundation
import Testing
@testable import ScanKit

/// Checks against a real ES-50 scan, which isn't kept in the repository. Run with
/// `SHEETFEED_SAMPLE=/path/to/scan.jpeg SHEETFEED_OUT=/path/to/folder swift test --filter RealScan`.
private let samplePath = ProcessInfo.processInfo.environment["SHEETFEED_SAMPLE"]

@Suite(.enabled(if: samplePath != nil, "set SHEETFEED_SAMPLE to a real scan"))
struct RealScanTests {
    @Test func cleansUpAndReadsARealScan() throws {
        let raw = try #require(ImageFiles.load(URL(fileURLWithPath: samplePath!)))
        let trim = PageProcessor.scannerMarginTrimRect(raw)
        print("scan \(raw.width)×\(raw.height), trim \(String(describing: trim)), skew \(String(describing: PageProcessor.skewAngle(raw)))")

        let start = Date()
        let page = try #require(PageProcessor.process(raw, options: ProcessingOptions()))
        print("processed \(page.width)×\(page.height) in \(Date().timeIntervalSince(start))s, blank=\(PageProcessor.isBlank(page))")

        let ocrStart = Date()
        let lines = try TextRecognizer.recognize(page)
        print("OCR \(lines.count) lines in \(Date().timeIntervalSince(ocrStart))s: \(lines.map(\.text))")

        if let out = ProcessInfo.processInfo.environment["SHEETFEED_OUT"] {
            let pdf = try Exporter.makePDF([ExportPage(image: page, dpi: 200, colorMode: .color)], quality: .high, searchable: true)
            try pdf.write(to: URL(fileURLWithPath: out).appendingPathComponent("real-scan.pdf"))
            try ImageFiles.writeLossless(page, dpi: 200, to: URL(fileURLWithPath: out).appendingPathComponent("real-scan-processed.tiff"))
            print("PDF \(pdf.count) bytes")
        }
        #expect(trim != nil)
        #expect(!PageProcessor.isBlank(page))
    }
}
