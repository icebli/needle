import SwiftUI

struct SettingsView: View {
    let model: AppModel
    private func binding<T>(_ path: WritableKeyPath<NeedleSettings, T>) -> Binding<T> {
        Binding(get: { model.settings.value[keyPath: path] }, set: { model.settings.value[keyPath: path] = $0 })
    }

    var body: some View {
        Form {
            Section("Spotify") {
                TextField("Default playlist", text: binding(\.playlistName))
                Text("The playlist destination is captured when you search. Spotify delivery requires the optional Needle companion; saving a file does not require it.")
                    .font(.caption).foregroundStyle(.secondary)
                SetupView(model: model)
            }
            Section("Advanced workflow") {
                Picker("Search sources", selection: binding(\.provider)) {
                    Text("YouTube & SoundCloud").tag("auto")
                    Text("YouTube").tag("youtube")
                    Text("SoundCloud").tag("soundcloud")
                }
                Picker("Output format", selection: binding(\.format)) {
                    Text("MP3 · Spotify workflow").tag("mp3")
                    Text("M4A · advanced").tag("m4a")
                    Text("FLAC · advanced").tag("flac")
                    Text("Opus · advanced").tag("opus")
                }
                Text("Advanced outputs are saved locally. Automatic Spotify delivery is enabled for MP3 only. Conversion never improves the original source quality.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Default album hint", text: binding(\.albumHint))
                TextField("Duration override", text: binding(\.durationOverride), prompt: Text("For example, 4:54"))
                Toggle("Skip metadata lookup", isOn: binding(\.noMetadata))
                TextField("CLI executable (optional)", text: binding(\.cliPath))
                Text("Leave blank to use the bundled CLI. Identity rejection remains enforced in the desktop workflow.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Command line") {
                Text("The full CLI remains available for expert workflows, including explicit direct-source overrides.")
                Text("needle get --help\nneedle search --help\nneedle doctor")
                    .font(.callout.monospaced()).textSelection(.enabled)
            }
        }
        .formStyle(.grouped).frame(width: 620, height: 680).padding(8)
    }
}
