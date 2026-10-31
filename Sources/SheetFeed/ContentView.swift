import ScanKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showSettings = true

    var body: some View {
        NavigationSplitView {
            PageList()
                .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
        } detail: {
            VStack(spacing: 0) {
                PagePreview()
                Divider()
                StatusBar()
            }
        }
        .inspector(isPresented: $showSettings) {
            SettingsPanel()
                .inspectorColumnWidth(min: 250, ideal: 270, max: 340)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.scan() } label: { Label("Scan", systemImage: "scanner") }
                    .help("Scan the page in the feeder (⌘↩)")
                    .disabled(!model.scanner.canScan || model.isBusy)
                Button { model.rotate(model.selection, by: -1) } label: { Label("Rotate Left", systemImage: "rotate.left") }
                    .help("Rotate left (⌘L)")
                    .disabled(model.selection == nil)
                Button { model.rotate(model.selection, by: 1) } label: { Label("Rotate Right", systemImage: "rotate.right") }
                    .help("Rotate right (⌘R)")
                    .disabled(model.selection == nil)
                Button { model.delete(model.selection) } label: { Label("Delete Page", systemImage: "trash") }
                    .help("Delete the selected page (⌫)")
                    .disabled(model.selection == nil)
                Button { model.share() } label: { Label("Share", systemImage: "square.and.arrow.up") }
                    .help("Share as PDF by Mail, Messages, AirDrop…")
                    .disabled(!model.canSave)
                Button { model.saveAs() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .help("Save… (⌘S). Quick Save to your save folder: ⌥⌘S")
                    .disabled(!model.canSave)
                Button { showSettings.toggle() } label: { Label("Settings", systemImage: "sidebar.right") }
                    .help("Show or hide scan settings")
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
    }
}

// MARK: Pages

private struct PageList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                VStack(spacing: 4) {
                    Image(decorative: page.thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 150)
                        .shadow(radius: 1)
                    Text("Page \(index + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .tag(page.id)
                .contextMenu {
                    Button("Rotate Left") { model.rotate(page.id, by: -1) }
                    Button("Rotate Right") { model.rotate(page.id, by: 1) }
                    Divider()
                    Button("Delete Page") { model.delete(page.id) }
                }
            }
            .onMove { model.move(from: $0, to: $1) }
        }
        .onDeleteCommand { model.delete(model.selection) }
        .overlay {
            if model.pages.isEmpty {
                Text("Scanned pages appear here. Drag to reorder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
    }
}

private struct PagePreview: View {
    @EnvironmentObject private var model: AppModel
    @State private var image: CGImage?

    private var selected: ScannedPage? { model.pages.first { $0.id == model.selection } }

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let selected, let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .shadow(radius: 3)
                    .padding(24)
                    .id(selected.id)
            } else if model.pages.isEmpty {
                EmptyState()
            }
        }
        .task(id: "\(selected?.id.uuidString ?? "")-\(selected?.quarterTurns ?? 0)") {
            guard let page = selected else { image = nil; return }
            image = await Task.detached(priority: .userInitiated) {
                ImageFiles.thumbnail(page.fileURL, maxPixels: 2000).map { PageProcessor.rotated($0, quarterTurns: page.quarterTurns) }
            }.value
        }
    }
}

private struct EmptyState: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
            Text(model.scanner.paperLoaded ? "A page is in the feeder" : "Put a page in the scanner")
                .font(.title2)
            Text(model.settings.autoFeed
                 ? "Auto-feed is on: each page scans as soon as you insert it."
                 : "Then click Scan, press ⌘↩, or press the scanner's button. Add more pages the same way, then save them as one document.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Scan") { model.scan() }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(!model.scanner.canScan || model.isBusy)
        }
        .padding()
    }
}

// MARK: Status

private struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            Text(scannerText).lineLimit(1)
            if let notice = model.notice {
                Text("·").foregroundStyle(.tertiary)
                Text(notice).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning…")
                Button("Cancel") { model.cancelScan() }.controlSize(.small)
            } else if model.processingCount > 0 {
                ProgressView().controlSize(.small)
                Text("Cleaning up page…")
            } else if let progress = model.exportProgress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 120)
                Text(model.settings.searchable && model.settings.format == .pdf
                     ? "Reading text, page \(min(progress.done + 1, progress.total)) of \(progress.total)…"
                     : "Saving…")
            } else if !model.pages.isEmpty {
                Text(model.pages.count == 1 ? "1 page" : "\(model.pages.count) pages").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    private var scannerText: String {
        switch model.scanner.status {
        case .searching: "Looking for the scanner… Check the USB cable."
        case .connecting(let name): "Connecting to \(name)…"
        case .ready, .scanning:
            "\(model.scanner.scannerName ?? "Scanner") ready" + (model.scanner.paperLoaded ? " · page in feeder" : "")
        case .failed(let message): message
        }
    }

    private var dotColor: Color {
        switch model.scanner.status {
        case .ready, .scanning: .green
        case .searching, .connecting: .orange
        case .failed: .red
        }
    }
}

// MARK: Settings

private struct SettingsPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Scan") {
                Picker("Resolution", selection: $model.settings.resolution) {
                    ForEach(AppSettings.resolutions, id: \.self) { Text("\($0) dpi").tag($0) }
                }
                Picker("Color", selection: $model.settings.colorMode) {
                    ForEach(ColorMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Paper size", selection: $model.settings.paperSize) {
                    ForEach(PaperSize.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Auto-feed: scan when a page is inserted", isOn: $model.settings.autoFeed)
            }
            Section("Clean up") {
                Toggle("Trim the scanner's margins", isOn: $model.settings.trimMargins)
                Toggle("Straighten crooked pages", isOn: $model.settings.straighten)
                Toggle("Skip blank pages", isOn: $model.settings.skipBlankPages)
            }
            Section("Save") {
                Picker("Format", selection: $model.settings.format) {
                    ForEach(ExportFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if model.settings.format == .pdf {
                    Toggle("Searchable text (OCR)", isOn: $model.settings.searchable)
                }
                if model.settings.format != .png {
                    Picker("Image quality", selection: $model.settings.quality) {
                        ForEach(ImageQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                LabeledContent("Quick Save folder") {
                    Button(model.settings.saveFolder?.lastPathComponent ?? "Documents") { model.chooseSaveFolder() }
                }
                Toggle("Open after saving", isOn: $model.settings.openAfterSaving)
                Toggle("Clear pages after saving", isOn: $model.settings.clearAfterSaving)
            }
            Section {
                Text("Resolution, color and clean-up apply to pages scanned after you change them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
