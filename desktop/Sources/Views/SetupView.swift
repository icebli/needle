import SwiftUI
import AppKit

struct SetupView: View {
    let model: AppModel
    private var folder: String { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/needle").path }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("1. In Spotify desktop Settings, enable Show Local Files.")
                Text("2. Add this folder as a source:")
                Text(folder).font(.callout.monospaced()).textSelection(.enabled)
                Text("3. Optional playlist delivery uses the Needle Spicetify companion. Without it, saved music is still available through Spotify Local Files.")
                    .foregroundStyle(.secondary)
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
