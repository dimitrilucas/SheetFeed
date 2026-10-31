import AppKit
import SwiftUI

@main
struct SheetFeedApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("SheetFeed", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan") { model.scan() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.scanner.canScan || model.isBusy)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save…") { model.saveAs() }
                    .keyboardShortcut("s")
                    .disabled(!model.canSave)
                Button("Quick Save") { model.quickSave() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(!model.canSave)
            }
            CommandGroup(replacing: .printItem) {
                Button("Print…") { model.printDocument() }
                    .keyboardShortcut("p")
                    .disabled(!model.canSave)
            }
            CommandMenu("Page") {
                Button("Rotate Left") { model.rotate(model.selection, by: -1) }
                    .keyboardShortcut("l")
                    .disabled(model.selection == nil)
                Button("Rotate Right") { model.rotate(model.selection, by: 1) }
                    .keyboardShortcut("r")
                    .disabled(model.selection == nil)
                Divider()
                Button("Delete Page") { model.delete(model.selection) }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(model.selection == nil)
                Button("Remove All Pages") { model.clear() }
                    .disabled(model.pages.isEmpty)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run straight from `swift run`, outside an app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
