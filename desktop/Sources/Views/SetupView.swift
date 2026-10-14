import SwiftUI
import AppKit

struct SetupView: View {
    let model: AppModel
    @State private var installingCompanion = false
    @State private var companionMessage: String?
    private var folder: String { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/needle").path }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("1. In Spotify desktop Settings, enable Show Local Files.")
                Text("2. Add this folder as a source:")
                Text(folder).font(.callout.monospaced()).textSelection(.enabled)
                Text("3. Playlist delivery and artist discovery use Needle’s bundled Spicetify companion. Enable it after installing Spicetify. Spotify will restart when you enable or update the companion.")
                    .foregroundStyle(.secondary)
                HStack {
                    Link("Install Spicetify", destination: URL(string: "https://spicetify.app/")!)
                    Button(installingCompanion ? "Enabling companion…" : "Enable / update Needle companion") {
                        installingCompanion = true; companionMessage = nil
                        Task {
                            defer { installingCompanion = false }
                            do {
                                try await CompanionSetupService().install()
                                companionMessage = "Needle’s companion is enabled. Open Spotify, then sync artists or check delivery."
                            } catch { companionMessage = error.localizedDescription }
                        }
                    }.disabled(installingCompanion)
                }
                if let companionMessage { Text(companionMessage).font(.caption).textSelection(.enabled) }
                HStack {
                    Button("Open Spotify") {
                        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
                            NSWorkspace.shared.open(app)
                        } else { model.message = "Install the Spotify desktop app, then enable Local Files in its Settings." }
                    }
                    Button(model.isCheckingTools ? "Checking…" : "Check audio tools") { model.checkTools() }
                        .disabled(model.isBusy || model.isCheckingTools)
                }
                if let response = model.tools {
                    ForEach(Array(response.tools.enumerated()), id: \.offset) { _, tool in
                        Label(tool.name ?? "Audio tool", systemImage: tool.ok == true ? "checkmark.circle.fill" : "exclamationmark.triangle")
                            .foregroundStyle(tool.ok == true ? Color.secondary : Color.orange)
                        Text(tool.message ?? "").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if let message = model.setupMessage { Text(message).font(.callout).foregroundStyle(.orange) }
                Text("The app checks installed audio tools. It never silently installs software or changes Spotify settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.callout).padding(.top, 14)
        } label: {
            Label(model.tools?.ok == true ? "Audio tools ready · Spotify setup guide" : "Set up Spotify Local Files",
                  systemImage: model.tools?.ok == true ? "checkmark.circle" : "slider.horizontal.3")
                .font(.callout.weight(.medium))
        }
        .padding(18).background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }
}
