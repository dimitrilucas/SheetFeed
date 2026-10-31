import Foundation
import ImageCaptureCore
import ScanKit

enum PaperSize: String, CaseIterable, Codable {
    case auto, letter, legal, a4, a5

    var label: String {
        switch self {
        case .auto: "Auto (trim to page)"
        case .letter: "US Letter"
        case .legal: "US Legal"
        case .a4: "A4"
        case .a5: "A5"
        }
    }

    /// What the feeder is asked for. Auto scans legal length and the page is trimmed afterwards.
    var documentType: ICScannerDocumentType {
        switch self {
        case .auto, .legal: .typeUSLegal
        case .letter: .typeUSLetter
        case .a4: .typeA4
        case .a5: .typeA5
        }
    }
}

struct ScanSettings: Equatable {
    var resolution = 300
    var paperSize = PaperSize.auto
}

/// Finds the scanner, keeps a session open, and runs scans through Apple's ImageCaptureCore with Epson's driver.
/// ImageCaptureCore calls its delegates on the main thread.
@MainActor
final class ScannerController: NSObject, ObservableObject {
    enum Status: Equatable {
        case searching
        case connecting(String)
        case ready
        case scanning
        case failed(String)
    }

    @Published private(set) var status = Status.searching
    @Published private(set) var scannerName: String?
    @Published private(set) var paperLoaded = false

    /// Called for each page file the scanner writes.
    var onPage: ((URL, Int) -> Void)?
    /// Called when the scanner's own button is pressed.
    var onButtonPress: (() -> Void)?

    private let browser = ICDeviceBrowser()
    private var scanner: ICScannerDevice?
    private var unitReady = false
    private var scanResolution = 300
    private var pagesThisScan = 0
    private var scanCompletion: ((Result<Int, Error>) -> Void)?
    private var paperTimer: Timer?
    let downloadDirectory: URL

    override init() {
        downloadDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SheetFeed-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
    }

    var canScan: Bool { status == .ready }

    private var feeder: ICScannerFunctionalUnitDocumentFeeder? {
        scanner?.selectedFunctionalUnit as? ICScannerFunctionalUnitDocumentFeeder
    }

    /// Scans every page the feeder takes in. Completes with the number of pages scanned.
    func scan(_ settings: ScanSettings, completion: @escaping (Result<Int, Error>) -> Void) {
        guard let scanner, canScan else {
            completion(.failure(ScanError.notReady))
            return
        }
        let unit = scanner.selectedFunctionalUnit
        unit.resolution = Self.nearest(settings.resolution, in: unit.supportedResolutions)
        // Always scan 8-bit color; grayscale and black & white are made afterwards, which is known to work with this driver.
        unit.pixelDataType = .RGB
        unit.bitDepth = .depth8Bits
        if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder {
            feeder.documentType = settings.paperSize.documentType
            if feeder.supportsDuplexScanning { feeder.duplexScanningEnabled = false }
        }
        scanResolution = unit.resolution
        scanner.transferMode = .fileBased
        scanner.downloadsDirectory = downloadDirectory
        scanner.documentName = "page-\(UUID().uuidString)"
        scanner.documentUTI = "public.tiff"
        pagesThisScan = 0
        scanCompletion = completion
        status = .scanning
        scanner.requestScan()
    }

    func cancelScan() {
        scanner?.cancelScan()
    }

    private static func nearest(_ dpi: Int, in supported: IndexSet) -> Int {
        guard !supported.isEmpty else { return dpi }
        return supported.min { abs($0 - dpi) < abs($1 - dpi) } ?? dpi
    }

    /// The feeder reports whether paper is in the slot; poll it so the window can show it and auto-feed can start.
    private func startWatchingPaper() {
        paperTimer?.invalidate()
        paperTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let feeder = self.feeder else { return }
                if self.paperLoaded != feeder.documentLoaded { self.paperLoaded = feeder.documentLoaded }
            }
        }
    }

    private func finishScan(_ result: Result<Int, Error>) {
        guard let completion = scanCompletion else { return }
        scanCompletion = nil
        if case .scanning = status { status = .ready }
        completion(result)
    }

    private func disconnect(_ message: String?) {
        paperTimer?.invalidate()
        scanner = nil
        scannerName = nil
        unitReady = false
        paperLoaded = false
        status = message.map(Status.failed) ?? .searching
        finishScan(.failure(ScanError.disconnected))
    }
}

enum ScanError: LocalizedError {
    case notReady, disconnected, feederEmpty

    var errorDescription: String? {
        switch self {
        case .notReady: "The scanner isn't ready yet."
        case .disconnected: "The scanner was disconnected."
        case .feederEmpty: "Put a page in the scanner's feed slot, then scan."
        }
    }
}

extension ScannerController: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        MainActor.assumeIsolated {
            guard scanner == nil, let found = device as? ICScannerDevice else { return }
            scanner = found
            scannerName = found.name
            status = .connecting(found.name ?? "scanner")
            found.delegate = self
            found.requestOpenSession()
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        MainActor.assumeIsolated {
            if device === scanner { disconnect(nil) }
        }
    }
}

extension ScannerController: ICScannerDeviceDelegate {
    nonisolated func didRemove(_ device: ICDevice) {
        MainActor.assumeIsolated { disconnect(nil) }
    }

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        MainActor.assumeIsolated {
            if let error { status = .failed("Couldn't open the scanner: \(error.localizedDescription)") }
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    nonisolated func deviceDidBecomeReady(_ device: ICDevice) {
        MainActor.assumeIsolated {
            // The driver selects the document feeder itself shortly after this; select it only if it hasn't.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let scanner = self.scanner, !self.unitReady else { return }
                scanner.requestSelect(.documentFeeder)
            }
        }
    }

    nonisolated func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                if !unitReady { status = .failed("The scanner's feeder isn't available: \(error.localizedDescription)") }
                return
            }
            unitReady = true
            status = .ready
            startWatchingPaper()
        }
    }

    nonisolated func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        MainActor.assumeIsolated {
            pagesThisScan += 1
            onPage?(url, scanResolution)
        }
    }

    nonisolated func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
        MainActor.assumeIsolated {
            if let error, pagesThisScan == 0 {
                finishScan(.failure(Self.isFeederEmpty(error) ? ScanError.feederEmpty : error))
            } else {
                finishScan(.success(pagesThisScan))
            }
        }
    }

    nonisolated func device(_ device: ICDevice, didEncounterError error: Error?) {
        MainActor.assumeIsolated {
            guard let error, scanCompletion == nil else { return }
            if !Self.isFeederEmpty(error) { status = .failed(error.localizedDescription) }
        }
    }

    nonisolated func device(_ device: ICDevice, didReceiveButtonPress buttonType: String) {
        MainActor.assumeIsolated { onButtonPress?() }
    }

    private static func isFeederEmpty(_ error: Error) -> Bool {
        (error as NSError).code == -9933
    }
}
