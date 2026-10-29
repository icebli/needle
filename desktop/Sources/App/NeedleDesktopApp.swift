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
    @FocusedValue(\.bookmarkSearch) private var focusBookmarkSearch
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.isConfigured || !updates.canCheckForUpdates)
        }
        CommandGroup(after: .newItem) {
            Button("Add Music") { model.destination = .addMusic }
                .keyboardShortcut("n", modifiers: [.command])
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Bookmarks") { focusBookmarkSearch?() }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(focusBookmarkSearch == nil)
        }
        CommandMenu("Go") {
            ForEach(Array(Destination.allCases.enumerated()), id: \.element) { index, destination in
                Button(destination.rawValue) { model.destination = destination }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command])
            }
        }
    }
}

private struct BookmarkSearchKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var bookmarkSearch: (() -> Void)? {
        get { self[BookmarkSearchKey.self] }
        set { self[BookmarkSearchKey.self] = newValue }
    }
}
