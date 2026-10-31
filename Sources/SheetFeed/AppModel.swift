import AppKit
import Combine
import PDFKit
import ScanKit
import UniformTypeIdentifiers

struct AppSettings: Codable, Equatable {
    var resolution = 300
    var paperSize = PaperSize.auto
    var colorMode = ColorMode.color
    var trimMargins = true
    var straighten = true
    var skipBlankPages = true
    var format = ExportFormat.pdf
    var quality = ImageQuality.high
    var searchable = true
    /// Scan automatically whenever a page is put in the feed slot.
    var autoFeed = false
    /// Where Quick Save writes; nil means the Documents folder.
    var saveFolder: URL?
    var openAfterSaving = true
    var clearAfterSaving = true

    static let resolutions = [150, 200, 300, 600]

    private static let key = "settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

struct ScannedPage: Identifiable {
    let id = UUID()
    /// The processed page, before any rotation the user applies.
    let fileURL: URL
    let dpi: Int
    let colorMode: ColorMode
    var quarterTurns = 0
    var thumbnail: CGImage
}

@MainActor
final class AppModel: ObservableObject {
    let scanner = ScannerController()

    @Published var settings = AppSettings.load() {
        didSet { settings.save() }
    }
    @Published var pages: [ScannedPage] = []
    @Published var selection: ScannedPage.ID?
    @Published private(set) var isScanning = false
    @Published private(set) var processingCount = 0
    @Published private(set) var exportProgress: (done: Int, total: Int)?
    /// A short note for the status bar, such as skipped blank pages or where a file was saved.
    @Published var notice: String?
    @Published var alert: String?

    private let processingQueue = DispatchQueue(label: "SheetFeed.processing", qos: .userInitiated)
    private var cancellables: Set<AnyCancellable> = []

    init() {
        scanner.onPage = { [weak self] url, dpi in self?.process(url, dpi: dpi) }
        scanner.onButtonPress = { [weak self] in self?.scan() }
        // Forward the scanner's changes so views observing the model refresh.
        scanner.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        scanner.$paperLoaded.removeDuplicates().sink { [weak self] loaded in
            guard let self, loaded, self.settings.autoFeed else { return }
            // Give the feeder a moment to grip the page.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.scan() }
        }.store(in: &cancellables)
    }

    var isBusy: Bool { isScanning || exportProgress != nil }
    var canSave: Bool { !pages.isEmpty && !isBusy && processingCount == 0 }

    // MARK: Scanning

    func scan() {
        guard scanner.canScan, !isBusy else { return }
        isScanning = true
        notice = nil
        let scanSettings = ScanSettings(resolution: settings.resolution, paperSize: settings.paperSize)
        scanner.scan(scanSettings) { [weak self] result in
            guard let self else { return }
            self.isScanning = false
            switch result {
            case .success:
                if self.settings.autoFeed, self.scanner.paperLoaded {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.scan() }
                }
            case .failure(let error):
                self.notice = error.localizedDescription
            }
        }
    }

    func cancelScan() { scanner.cancelScan() }

    /// Cleans up a page the scanner wrote, in scan order, off the main thread.
    private func process(_ rawURL: URL, dpi: Int) {
        processingCount += 1
        let options = ProcessingOptions(colorMode: settings.colorMode, trimScannerMargins: settings.trimMargins,
                                        straighten: settings.straighten, skipBlankPages: settings.skipBlankPages)
        let outputURL = scanner.downloadDirectory.appendingPathComponent("\(UUID().uuidString).tiff")
        processingQueue.async {
            var page: ScannedPage?
            var failure: String?
            var skipped = false
            if let raw = ImageFiles.load(rawURL) {
                if let processed = PageProcessor.process(raw, options: options) {
                    do {
                        try ImageFiles.writeLossless(processed, dpi: Double(dpi), to: outputURL)
                        if let thumb = ImageFiles.thumbnail(outputURL, maxPixels: 400) {
                            page = ScannedPage(fileURL: outputURL, dpi: dpi, colorMode: options.colorMode, thumbnail: thumb)
                        }
                    } catch {
                        failure = error.localizedDescription
                    }
                } else {
                    skipped = true
                }
            } else {
                failure = "A scanned page couldn't be read."
            }
            try? FileManager.default.removeItem(at: rawURL)
            DispatchQueue.main.async {
                self.processingCount -= 1
                if let page {
                    self.pages.append(page)
                    self.selection = page.id
                }
                if skipped { self.notice = "Skipped a blank page." }
                if let failure { self.alert = failure }
            }
        }
    }

    // MARK: Editing pages

    func rotate(_ id: ScannedPage.ID?, by turns: Int) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[index].quarterTurns = (pages[index].quarterTurns + turns + 4) % 4
        pages[index].thumbnail = PageProcessor.rotated(pages[index].thumbnail, quarterTurns: turns)
    }

    func delete(_ id: ScannedPage.ID?) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        let removed = pages.remove(at: index)
        try? FileManager.default.removeItem(at: removed.fileURL)
        selection = pages.isEmpty ? nil : pages[min(index, pages.count - 1)].id
    }

    func move(from source: IndexSet, to destination: Int) {
        pages.move(fromOffsets: source, toOffset: destination)
    }

    func clear() {
        for page in pages { try? FileManager.default.removeItem(at: page.fileURL) }
        pages = []
        selection = nil
    }

    // MARK: Saving

    /// Asks where to save, then writes the document in the chosen format.
    func saveAs() {
        guard canSave else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Exporter.defaultName()
        panel.allowedContentTypes = [UTType(filenameExtension: settings.format.fileExtension) ?? .data]
        panel.directoryURL = settings.saveFolder
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.saveFolder = url.deletingLastPathComponent()
        export(to: url, format: settings.format) { [weak self] files in self?.didSave(files) }
    }

    /// Saves straight to the save folder with a date-and-time name.
    func quickSave() {
        guard canSave else { return }
        let folder = settings.saveFolder ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = folder.appendingPathComponent(Exporter.defaultName()).appendingPathExtension(settings.format.fileExtension)
        export(to: url, format: settings.format) { [weak self] files in self?.didSave(files) }
    }

    func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveFolder
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { settings.saveFolder = url }
    }

    private func didSave(_ files: [URL]) {
        guard let first = files.first else { return }
        notice = files.count == 1 ? "Saved \(first.lastPathComponent)" : "Saved \(files.count) files"
        if settings.openAfterSaving {
            if files.count == 1 { NSWorkspace.shared.open(first) } else { NSWorkspace.shared.activateFileViewerSelecting(files) }
        }
        if settings.clearAfterSaving { clear() }
    }

    /// Shares the document as a PDF through Mail, Messages, AirDrop, Notes and so on.
    func share() {
        guard canSave, let view = NSApp.keyWindow?.contentView else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SheetFeed-share-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Exporter.defaultName()).appendingPathExtension("pdf")
        export(to: url, format: .pdf) { files in
            // Anchor the picker under the toolbar's right-hand end, where the Share button is.
            let anchor = NSRect(x: view.bounds.maxX - 120, y: view.bounds.maxY - 1, width: 1, height: 1)
            NSSharingServicePicker(items: files).show(relativeTo: anchor, of: view, preferredEdge: .minY)
        }
    }

    func printDocument() {
        guard canSave else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(Exporter.defaultName()).pdf")
        export(to: url, format: .pdf) { files in
            guard let file = files.first, let pdf = PDFDocument(url: file),
                  let operation = pdf.printOperation(for: .shared, scalingMode: .pageScaleToFit, autoRotate: true) else { return }
            operation.run()
        }
    }

    private func export(to url: URL, format: ExportFormat, then finish: @escaping ([URL]) -> Void) {
        let snapshot = pages
        let quality = settings.quality
        let searchable = settings.searchable && format == .pdf
        exportProgress = (0, snapshot.count)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try Exporter.export(count: snapshot.count, page: { index in
                    let page = snapshot[index]
                    guard let image = ImageFiles.load(page.fileURL) else { throw ExportError.couldNotCreate("page \(index + 1)") }
                    return ExportPage(image: PageProcessor.rotated(image, quarterTurns: page.quarterTurns),
                                      dpi: Double(page.dpi), colorMode: page.colorMode)
                }, format: format, quality: quality, searchable: searchable, to: url, progress: { done in
                    DispatchQueue.main.async { self.exportProgress = (done, snapshot.count) }
                })
            }
            DispatchQueue.main.async {
                self.exportProgress = nil
                switch result {
                case .success(let files): finish(files)
                case .failure(let error): self.alert = "Couldn't save: \(error.localizedDescription)"
                }
            }
        }
    }
}
