import SwiftUI
import AppKit

@main
struct NeedleDesktopApp: App {
    @NSApplicationDelegateAdaptor(NeedleAppDelegate.self) private var delegate
    @State private var model = AppModel()
    @State private var updates = UpdateService()

    var body: some Scene {
        WindowGroup("Needle", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 650)
                .onAppear { delegate.model = model }
        }
        .commands { AppCommands(model: model, updates: updates) }

        Settings {
            SettingsView(model: model)
        }
    }
}

@MainActor
final class NeedleAppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { await model.cli.cancel(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

struct AppCommands: Commands {
    let model: AppModel
    let updates: UpdateService
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.isConfigured || !updates.canCheckForUpdates)
        }
        CommandGroup(after: .newItem) {
            Button("Add Music") { model.destination = .addMusic }
                .keyboardShortcut("n", modifiers: [.command])
        }
    }
}
