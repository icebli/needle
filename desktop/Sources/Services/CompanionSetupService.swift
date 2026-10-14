import Foundation

actor CompanionSetupService {
    /// User-initiated setup; appending extensions preserves the user's other
    /// Spicetify customizations. Applying extensions restarts Spotify.
    func install() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".spicetify/spicetify").path,
                          "/opt/homebrew/bin/spicetify", "/usr/local/bin/spicetify"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CLIError.message("Install Spicetify first using spicetify.app, then return here to enable Needle’s companion.")
        }
        let root = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/spicetify")
        let names = ["needle-local-playlist.js", "needle-discovery.js"]
        guard names.allSatisfy({ FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }) else {
            throw CLIError.message("Companion files are missing from this app. Reinstall the latest Needle installer.")
        }
        let config = try await run(executable, ["-c"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.hasPrefix("/"), config.hasSuffix(".ini") else {
            throw CLIError.message("Spicetify did not return its configuration folder.")
        }
        let extensions = URL(fileURLWithPath: config).deletingLastPathComponent().appendingPathComponent("Extensions")
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        for name in names {
            try Data(contentsOf: root.appendingPathComponent(name)).write(to: extensions.appendingPathComponent(name), options: .atomic)
            _ = try await run(executable, ["config", "extensions", name])
        }
        _ = try await run(executable, ["apply"])
    }

    private func run(_ executable: String, _ arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardOutput = output; process.standardError = output
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: bytes, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw CLIError.message("Spicetify setup needs attention: \(String(text.suffix(800)))")
            }
            return text
        }.value
    }
}
