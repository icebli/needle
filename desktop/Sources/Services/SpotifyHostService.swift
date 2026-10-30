import Foundation

actor SpotifyHostService {
    func enqueue(track: TrackRequest, playlistName: String) async -> Result<String, Error> {
        guard let host = findHost() else { return .failure(CLIError.message("Needle's Spotify bridge is missing. Reinstall Needle.")) }
        do {
            var payload: [String: String] = ["artist": track.artist, "title": track.title, "playlistName": playlistName]
            if !track.album.isEmpty { payload["album"] = track.album }
            if let savedPath = track.savedPath { payload["savedPath"] = savedPath }
            let input = try JSONSerialization.data(withJSONObject: payload)
            let result = try await run(host, ["enqueue"], input: input)
            let receipt = try JSONDecoder().decode(HostReceipt.self, from: result.output)
            guard receipt.ok, let id = receipt.jobId, !id.isEmpty else { throw CLIError.message("Spotify did not accept the handoff.") }
            return .success(id)
        } catch { return .failure(error) }
    }

    func reconcile(track: TrackRequest, previous: TrackRequest) async -> Result<String, Error> {
        guard let jobID = track.spotifyJobID, let host = findHost() else {
            return .failure(CLIError.message("The original Spotify delivery receipt is unavailable. Your file is saved."))
        }
        struct Request: Encodable {
            let previousJobId: String
            let track: SpotifyMetadataSnapshot
            let previousTrack: SpotifyMetadataSnapshot
        }
        do {
            let input = try JSONEncoder().encode(Request(previousJobId: jobID, track: SpotifyMetadataSnapshot(track: track), previousTrack: SpotifyMetadataSnapshot(track: previous)))
            let result = try await run(host, ["reconcile"], input: input)
            let receipt = try JSONDecoder().decode(HostReceipt.self, from: result.output)
            guard receipt.ok, let id = receipt.jobId, !id.isEmpty else { throw CLIError.message("Spotify did not accept the metadata repair.") }
            return .success(id)
        } catch { return .failure(error) }
    }

    func status(jobID: String, resume: Bool = false) async -> Result<HostStatus, Error> {
        guard let host = findHost() else { return .failure(CLIError.message("Needle's Spotify bridge is missing. Your audio file is still saved.")) }
        do {
            let result = try await run(host, [resume ? "resume" : "status", jobID], input: nil)
            return .success(try JSONDecoder().decode(HostStatus.self, from: result.output))
        } catch { return .failure(error) }
    }

    private func findHost() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/needle-browser-host").path,
            home.appendingPathComponent("Library/Application Support/Needle/bin/needle-browser-host").path,
            home.appendingPathComponent(".cargo/bin/needle-browser-host").path,
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func run(_ executable: String, _ args: [String], input: Data?) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let stdin = Pipe(), out = Pipe(), err = Pipe()
        process.standardInput = stdin
        process.standardOutput = out
        process.standardError = err
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()
        if let input { stdin.fileHandleForWriting.write(input) }
        try stdin.fileHandleForWriting.close()
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<ProcessResult, Never>) in
            DispatchQueue.global().async {
                let group = DispatchGroup()
                let stdout = HostDataBox(), stderr = HostDataBox()
                group.enter()
                DispatchQueue.global().async {
                    stdout.data = out.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    stderr.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                terminated.wait()
                group.wait()
                continuation.resume(returning: ProcessResult(output: stdout.data, error: stderr.data, status: process.terminationStatus))
            }
        }
        guard result.status == 0 else {
            let detail = String(decoding: result.error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError.message(detail.isEmpty ? "Spotify delivery could not start. Your file is safe; retry from Activity." : detail)
        }
        return result
    }
}

private final class HostDataBox: @unchecked Sendable { var data = Data() }
