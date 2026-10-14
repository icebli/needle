import Foundation
import AppKit
import Darwin

struct ProcessResult {
    let output: Data
    let error: Data
    let status: Int32
}

actor NeedleCLIService {
    private var activeProcess: Process?
    private var wasCancelled = false

    private func executable(settings: NeedleSettings) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            settings.cliPath,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/needle").path,
            home.appendingPathComponent("Library/Application Support/Needle/bin/needle").path,
            home.appendingPathComponent(".cargo/bin/needle").path,
            "/usr/local/bin/needle", "/opt/homebrew/bin/needle",
        ]
        return candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func parseLastJSON<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).reversed() {
            if let decoded = try? decoder.decode(T.self, from: Data(line.utf8)) { return decoded }
        }
        throw CLIError.message("Needle returned no structured result. Open details to check its output.")
    }

    func search(artist: String, title: String, sourceURL: String? = nil, settings: NeedleSettings) async -> Result<SearchResponse, Error> {
        var args = ["search", artist, title, "--json", "--source", settings.provider]
        if let sourceURL, !sourceURL.isEmpty { args += ["--url", sourceURL] }
        if !settings.albumHint.isEmpty { args += ["--album", settings.albumHint] }
        appendMetadataOptions(settings, to: &args)
        do {
            let result = try await execute(args, settings: settings)
            let response = try Self.parseLastJSON(SearchResponse.self, data: result.output)
            guard response.ok else { throw CLIError.message(response.error ?? "No recording could be resolved.") }
            return .success(response)
        } catch { return .failure(error) }
    }

    /// Resolve one already-approved source URL to retrieve provider facts that
    /// flat search results often omit, such as the selected audio bitrate.
    /// This deliberately performs a single exact-URL lookup instead of a new
    /// search, and therefore does not change the candidate being inspected.
    func inspectSource(artist: String, title: String, candidate: Candidate, settings: NeedleSettings) async -> Result<Candidate, Error> {
        switch await search(artist: artist, title: title, sourceURL: candidate.url, settings: settings) {
        case .success(let response):
            if let exact = response.candidates.first(where: {
                $0.candidate.url == candidate.url || ($0.candidate.id == candidate.id && $0.candidate.provider == candidate.provider)
            }) {
                return .success(exact.candidate)
            }
            return .failure(CLIError.message("Needle could not inspect this source."))
        case .failure(let error):
            return .failure(error)
        }
    }

    struct SourceIdentity: Decodable {
        let ok: Bool
        let artist: String?
        let title: String?
        let error: String?
    }

    func identifyURL(_ url: String, settings: NeedleSettings) async -> Result<SourceIdentity, Error> {
        do {
            let result = try await execute(["identify-url", url, "--json"], settings: settings)
            let response = try Self.parseLastJSON(SourceIdentity.self, data: result.output)
            guard response.ok else { throw CLIError.message(response.error ?? "Edit artist and title to search this link.") }
            return .success(response)
        } catch { return .failure(error) }
    }

    func runJSONCommand(_ arguments: [String], settings: NeedleSettings) async throws -> Data {
        try await execute(arguments, settings: settings).output
    }

    func doctor(settings: NeedleSettings) async -> Result<DoctorResponse, Error> {
        do {
            let result = try await execute(["doctor", "--json"], settings: settings)
            return .success(try Self.parseLastJSON(DoctorResponse.self, data: result.output))
        } catch { return .failure(error) }
    }

    func get(track: TrackRequest, settings: NeedleSettings,
             onProgress: @escaping @Sendable (String) -> Void = { _ in }) async -> Result<TrackRequest, Error> {
        var args = ["get", track.artist, track.title, "--url", track.sourceURL,
                    "--yes", "--strict", "--json", "--events", "--format", settings.format]
        if !track.album.isEmpty { args += ["--album", track.album] }
        appendMetadataOptions(settings, to: &args)
        do {
            let result = try await execute(args, settings: settings, onProgress: onProgress)
            struct Saved: Decodable {
                let ok: Bool
                let savedPath: String?
                let artist: String?
                let title: String?
                let album: String?
                let sourceUrl: String?
            }
            let saved = try Self.parseLastJSON(Saved.self, data: result.output)
            guard saved.ok, let path = saved.savedPath, !path.isEmpty else {
                throw CLIError.message("Needle did not confirm a saved file.")
            }
            guard saved.sourceUrl == track.sourceURL else {
                throw CLIError.message("The returned recording differs from your approved source. Your file was kept; review its details.")
            }
            var finished = track
            finished.savedPath = path
            finished.artist = saved.artist ?? track.artist
            finished.title = saved.title ?? track.title
            finished.album = saved.album ?? track.album
            return .success(finished)
        } catch { return .failure(error) }
    }

    private func appendMetadataOptions(_ settings: NeedleSettings, to args: inout [String]) {
        if settings.noMetadata { args += ["--no-metadata"] }
        if !settings.durationOverride.isEmpty { args += ["--duration-override", settings.durationOverride] }
    }

    func cancel() {
        guard let process = activeProcess, process.isRunning else { return }
        wasCancelled = true
        Self.terminateOwnedProcess(process)
    }

    private nonisolated static func descendants(of parent: Int32) -> [Int32] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        do { try ps.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let pairs = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> (Int32, Int32)? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { return nil }
            return (pid, ppid)
        }
        var result: [Int32] = []
        var frontier = [parent]
        while let next = frontier.popLast() {
            let children = pairs.filter { $0.1 == next && $0.0 != parent }.map(\.0)
            for child in children where !result.contains(child) { result.append(child); frontier.append(child) }
        }
        return result
    }

    private struct ProcessIdentity: Sendable {
        let pid: Int32
        let start: String
    }

    private nonisolated static func processIdentity(_ pid: Int32) -> ProcessIdentity? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "pid=,lstart="]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let fields = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard fields.count >= 6, let parsed = Int32(fields[0]) else { return nil }
        return ProcessIdentity(pid: parsed, start: fields.dropFirst().joined(separator: " "))
    }

    private nonisolated static func matchesCurrentProcess(_ identity: ProcessIdentity) -> Bool {
        guard let current = processIdentity(identity.pid) else { return false }
        return current.pid == identity.pid && current.start == identity.start
    }

    private nonisolated static func terminateOwnedProcess(_ process: Process) {
        let descendants = descendants(of: process.processIdentifier).compactMap(processIdentity)
        // Stop only descendants of this operation, then its CLI. yt-dlp/ffmpeg
        // otherwise survive terminating their parent and retain the output pipes.
        for identity in descendants.reversed() { Darwin.kill(identity.pid, SIGTERM) }
        if process.isRunning { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            for identity in descendants where matchesCurrentProcess(identity) {
                Darwin.kill(identity.pid, SIGKILL)
            }
        }
    }

    private func execute(_ args: [String], settings: NeedleSettings,
                         onProgress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ProcessResult {
        guard activeProcess == nil else { throw CLIError.message("Needle is already working. Wait or cancel the current operation.") }
        guard let path = executable(settings: settings) else { throw CLIError.missing }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        let bundledTools = Bundle.main.resourceURL?.appendingPathComponent("bin").path
        env["PATH"] = [bundledTools, "/opt/homebrew/bin", "/usr/local/bin", env["PATH"]].compactMap { $0 }.joined(separator: ":")
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()
        activeProcess = process
        wasCancelled = false
        let quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            Self.terminateOwnedProcess(process)
        }
        defer { NotificationCenter.default.removeObserver(quitObserver) }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<ProcessResult, Never>) in
            DispatchQueue.global().async {
                let group = DispatchGroup()
                let stdout = ProcessDataBox(), stderr = ProcessDataBox()
                group.enter()
                DispatchQueue.global().async {
                    stdout.data = out.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    var pending = Data(), captured = Data()
                    while true {
                        let chunk = err.fileHandleForReading.readData(ofLength: 4096)
                        if chunk.isEmpty { break }
                        pending.append(chunk)
                        captured.append(chunk)
                        if captured.count > 262_144 { captured.removeFirst(captured.count - 262_144) }
                        while let newline = pending.firstIndex(of: 10) {
                            let line = pending.prefix(upTo: newline)
                            if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                               object["event"] as? String == "progress", let stage = object["stage"] as? String {
                                onProgress(stage)
                            }
                            pending.removeSubrange(...newline)
                        }
                        // Diagnostics without newlines should not grow unbounded.
                        if pending.count > 262_144 { pending.removeAll() }
                    }
                    stderr.data = captured
                    group.leave()
                }
                terminated.wait()
                group.wait()
                continuation.resume(returning: ProcessResult(output: stdout.data, error: stderr.data, status: process.terminationStatus))
            }
        }
        activeProcess = nil
        if wasCancelled { throw CancellationError() }
        guard result.status == 0 else {
            let detail = String(decoding: result.error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError.message(detail.isEmpty ? "Needle could not complete this operation. Try another source." : detail)
        }
        return result
    }
}

private final class ProcessDataBox: @unchecked Sendable { var data = Data() }

enum CLIError: LocalizedError {
    case missing
    case message(String)
    var errorDescription: String? {
        switch self {
        case .missing: "Needle's audio service was not found. Reinstall Needle or choose the CLI in Advanced settings."
        case .message(let text): text
        }
    }
}
