import AVFoundation
import AppKit
import Combine
import Darwin
import Foundation

enum AudioPreviewState: Equatable {
    case idle
    case preparing
    case ready
    case playing
    case paused
    case failed(String)
}

/// Owns the short-lived audio preview pipeline. A preview never writes to the
/// Needle library or invokes the Spotify bridge; it only creates a temporary
/// excerpt from the exact candidate URL the user selected.
@MainActor
final class AudioPreviewService: NSObject, ObservableObject {
    @Published private(set) var state: AudioPreviewState = .idle
    @Published private(set) var candidateID: String?
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var keepTimestampAcrossCandidates = true

    private var player: AVPlayer?
    private var itemObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var process: Process?
    private var processToken: UUID?
    private var preparationTask: Task<Void, Never>?
    private var temporaryDirectory: URL?
    private var pendingSeek: Double?
    private var positions: [String: Double] = [:]
    private var sharedTimestamp: Double?
    private var generation = UUID()
    private var endObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private let ytDLPOverride: String?

    init(ytDLPPath: String? = nil) {
        ytDLPOverride = ytDLPPath
        super.init()
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    var isVisible: Bool { candidateID != nil }
    var isPreparing: Bool { state == .preparing }
    var isPlaying: Bool { state == .playing }

    func start(candidate: CandidateResult) {
        rememberPosition()
        let requestedPosition: Double?
        if keepTimestampAcrossCandidates, let sharedTimestamp {
            requestedPosition = sharedTimestamp
        } else {
            requestedPosition = positions[candidate.id]
        }
        stop()
        guard let source = AppModel.mediaURL(candidate.candidate.url) else {
            candidateID = candidate.id
            state = .failed("This source does not have a valid web URL to preview.")
            return
        }

        let token = UUID()
        generation = token
        candidateID = candidate.id
        elapsed = 0
        duration = 0
        pendingSeek = requestedPosition
        state = .preparing
        preparationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token { self.preparationTask = nil }
            }
            do {
                let output = try await self.prepare(source: source, token: token)
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.installPlayer(output, token: token)
            } catch is CancellationError {
                guard self.generation == token else { return }
                self.resetAfterPreparation()
            } catch {
                guard self.generation == token else { return }
                self.state = .failed(error.localizedDescription)
                self.cleanupTemporaryFiles()
            }
        }
    }

    func retry(candidate: CandidateResult) { start(candidate: candidate) }

    func togglePlayback() {
        guard let player else { return }
        switch state {
        case .playing:
            player.pause()
            state = .paused
        case .ready, .paused:
            if elapsed >= duration - 0.05 {
                player.seek(to: .zero)
                elapsed = 0
            }
            player.play()
            state = .playing
        default:
            break
        }
    }

    func seek(to value: Double) {
        guard let player else { return }
        let clamped = min(max(value, 0), max(duration, 0))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        elapsed = clamped
        rememberPosition()
    }

    func seek(by offset: Double) {
        seek(to: elapsed + offset)
    }

    func skipIntro() {
        seek(by: 30)
    }

    func stop() {
        rememberPosition()
        let wasPreparing = preparationTask != nil && state == .preparing
        generation = UUID()
        preparationTask?.cancel()
        preparationTask = nil
        terminateProcess()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        self.timeObserver = nil
        itemObservation?.invalidate()
        itemObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.currentItem?.cancelPendingSeeks()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        if wasPreparing { cleanupIncompletePreview() }
        candidateID = nil
        elapsed = 0
        duration = 0
        pendingSeek = nil
        state = .idle
    }

    nonisolated static func previewArguments(sourceURL: String, outputTemplate: String) -> [String] {
        ["--ignore-config", "--no-playlist", "--extractor-args", "youtube:player_client=android", "-f",
         "bestaudio[ext=m4a]/bestaudio", "-x", "--audio-format", "mp3",
         "--audio-quality", "5", "-o", outputTemplate, sourceURL]
    }

    private func prepare(source: URL, token: UUID) async throws -> URL {
        let cacheDirectory = Self.previewCacheDirectory(for: candidateID ?? token.uuidString,
                                                        sourceURL: source.absoluteString)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("needle-preview-work-\(token.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = directory
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let template = directory.appendingPathComponent("excerpt.%(ext)s").path
        let cachedOutput = cacheDirectory.appendingPathComponent("excerpt.mp3")
        let cacheMarker = cacheDirectory.appendingPathComponent("complete")
        if FileManager.default.fileExists(atPath: cachedOutput.path),
           FileManager.default.fileExists(atPath: cacheMarker.path) {
            Self.touch(cacheDirectory)
            Self.trimCache(keeping: cacheDirectory)
            temporaryDirectory = nil
            return cachedOutput
        }
        let output = directory.appendingPathComponent("excerpt.mp3")
        let executable = try ytDLPOverride ?? Self.findExecutable(named: "yt-dlp")
        let result = try await run(executable: executable,
                                   arguments: Self.previewArguments(sourceURL: source.absoluteString, outputTemplate: template),
                                   token: token)
        if result.status == 0, FileManager.default.fileExists(atPath: output.path) {
            guard generation == token else { throw CancellationError() }
            guard let committed = Self.commitPreview(output, to: cacheDirectory) else {
                throw PreviewError.message("Needle could not cache this preview.")
            }
            temporaryDirectory = nil
            Self.trimCache(keeping: cacheDirectory)
            return committed
        }

        // Some YouTube sessions return a media URL that ffmpeg cannot open
        // directly (for example a transient 403). Download the source file
        // first, then trim locally. This is one bounded fallback, not a retry
        // loop, and it remains inside this preview's temporary directory.
        let sourceTemplate = directory.appendingPathComponent("source.%(ext)s").path
        let sourceResult = try await run(executable: executable,
                                         arguments: ["--ignore-config", "--no-playlist", "-f", "bestaudio[ext=m4a]/bestaudio",
                                                     "-o", sourceTemplate, source.absoluteString], token: token)
        guard sourceResult.status == 0,
              let downloaded = Self.firstOutput(in: directory, prefix: "source.") else {
            let detail = String(decoding: sourceResult.error.isEmpty ? result.error : sourceResult.error,
                                as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw PreviewError.message(detail.isEmpty ? "Needle could not prepare this preview." : detail)
        }
        let ffmpeg = try Self.findExecutable(named: "ffmpeg")
        let trimResult = try await run(executable: ffmpeg,
                                       arguments: ["-hide_banner", "-loglevel", "error", "-y", "-i", downloaded.path,
                                                   "-vn", "-acodec", "libmp3lame", "-q:a", "5", output.path],
                                       token: token)
        guard trimResult.status == 0, FileManager.default.fileExists(atPath: output.path) else {
            let detail = String(decoding: trimResult.error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw PreviewError.message(detail.isEmpty ? "The preview converter did not produce an audio file." : detail)
        }
        guard generation == token else { throw CancellationError() }
        guard let committed = Self.commitPreview(output, to: cacheDirectory) else {
            throw PreviewError.message("Needle could not cache this preview.")
        }
        temporaryDirectory = nil
        Self.trimCache(keeping: cacheDirectory)
        return committed
    }

    private func installPlayer(_ url: URL, token: UUID) {
        guard generation == token else { return }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        itemObservation = item.observe(\AVPlayerItem.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                switch item.status {
                case .readyToPlay:
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard self.generation == token else { return }
                        if let seconds = try? await item.asset.load(.duration), seconds.seconds.isFinite, seconds.seconds > 0 {
                            guard self.generation == token else { return }
                            self.duration = seconds.seconds
                            if let pending = self.pendingSeek {
                                let initial = min(max(pending, 0), self.duration)
                                if initial > 0 {
                                    await player.seek(to: CMTime(seconds: initial, preferredTimescale: 600))
                                    self.elapsed = initial
                                }
                                self.pendingSeek = nil
                            }
                        }
                        guard self.generation == token else { return }
                        self.state = .ready
                    }
                case .failed:
                    self.state = .failed(item.error?.localizedDescription ?? "This preview could not be played.")
                    self.cleanupTemporaryFiles()
                default:
                    break
                }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.elapsed = min(max(time.seconds.isFinite ? time.seconds : 0, 0), self.duration)
                self.rememberPosition()
                if self.duration > 0, self.elapsed >= self.duration - 0.05 {
                    player.pause()
                    self.state = .paused
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.elapsed = self.duration
                self.state = .paused
            }
        }
    }

    private func run(executable: String, arguments: [String], token: UUID) async throws -> PreviewProcessResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        let bundledTools = Bundle.main.resourceURL?.appendingPathComponent("bin").path
        environment["PATH"] = [bundledTools, "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"]].compactMap { $0 }.joined(separator: ":")
        process.environment = environment
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }
        try process.run()
        self.process = process
        self.processToken = token

        let result = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let group = DispatchGroup()
                    let stdout = ProcessDataBox(), stderr = ProcessDataBox()
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        stdout.data = Self.readBounded(output.fileHandleForReading)
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        stderr.data = Self.readBounded(error.fileHandleForReading)
                        group.leave()
                    }
                    termination.wait()
                    group.wait()
                    continuation.resume(returning: PreviewProcessResult(output: stdout.data, error: stderr.data, status: process.terminationStatus))
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.terminateProcess(token: token) }
        })
        if self.processToken == token, self.process === process {
            self.process = nil
            self.processToken = nil
        }
        return result
    }

    private nonisolated static func readBounded(_ handle: FileHandle) -> Data {
        var captured = Data()
        while true {
            let chunk = handle.readData(ofLength: 4096)
            if chunk.isEmpty { return captured }
            captured.append(chunk)
            if captured.count > 262_144 { captured.removeFirst(captured.count - 262_144) }
        }
    }

    private nonisolated static func firstOutput(in directory: URL, prefix: String) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .first(where: { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension != "part" })
    }

    private func resetAfterPreparation() {
        terminateProcess()
        candidateID = nil
        state = .idle
    }

    private func rememberPosition() {
        guard let candidateID,
              [.ready, .playing, .paused].contains(state),
              elapsed.isFinite else { return }
        positions[candidateID] = min(max(elapsed, 0), max(duration, 0))
        if keepTimestampAcrossCandidates { sharedTimestamp = positions[candidateID] }
    }

    private func terminateProcess(token: UUID? = nil) {
        guard let process else { return }
        guard token == nil || processToken == token else { return }
        let descendants = Self.descendants(of: process.processIdentifier).compactMap(Self.processIdentity)
        for identity in descendants.reversed() { kill(identity.pid, SIGTERM) }
        if process.isRunning { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            for identity in descendants where Self.matchesCurrentProcess(identity) {
                kill(identity.pid, SIGKILL)
            }
        }
        self.process = nil
        processToken = nil
    }

    private func cleanupTemporaryFiles() {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    private func cleanupIncompletePreview() {
        guard let directory = temporaryDirectory,
              !FileManager.default.fileExists(atPath: directory.appendingPathComponent("excerpt.mp3").path) else { return }
        try? FileManager.default.removeItem(at: directory)
        temporaryDirectory = nil
    }

    nonisolated static func previewCacheDirectory(for candidateID: String, sourceURL: String = "") -> URL {
        var hash: UInt64 = 14695981039346656037
        for byte in (candidateID + "\n" + sourceURL).utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("needle-preview-cache", isDirectory: true)
            .appendingPathComponent(String(format: "%016llx", hash), isDirectory: true)
    }

    private nonisolated static func trimCache(keeping current: URL) {
        let root = current.deletingLastPathComponent()
        guard let directories = try? FileManager.default.contentsOfDirectory(at: root,
                                                                                includingPropertiesForKeys: [.contentModificationDateKey],
                                                                                options: .skipsHiddenFiles) else { return }
        for directory in directories where directory != current &&
                !FileManager.default.fileExists(atPath: directory.appendingPathComponent("complete").path) {
            try? FileManager.default.removeItem(at: directory)
        }
        let complete = directories.filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("excerpt.mp3").path) &&
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("complete").path)
        }
        let ordered = complete.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
        for directory in ordered.dropFirst(3) where directory != current {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private nonisolated static func touch(_ directory: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
    }

    private nonisolated static func commitPreview(_ output: URL, to directory: URL) -> URL? {
        let fileManager = FileManager.default
        let marker = directory.appendingPathComponent("complete")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("excerpt.mp3")
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.moveItem(at: output, to: destination)
            try Data("complete\n".utf8).write(to: marker, options: .atomic)
            touch(directory)
            return destination
        } catch {
            try? fileManager.removeItem(at: marker)
            return nil
        }
    }

    private static func findExecutable(named name: String) throws -> String {
        var paths = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        if let bundledTools = Bundle.main.resourceURL?.appendingPathComponent("bin") {
            paths.insert(bundledTools.appendingPathComponent(name).path, at: 0)
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            paths += path.split(separator: ":").map { "\($0)/\(name)" }
        }
        if let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return path }
        throw PreviewError.message("yt-dlp was not found. Check Needle’s tool setup before previewing.")
    }

    private nonisolated static func descendants(of parent: Int32) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let pairs = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> (Int32, Int32)? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { return nil }
            return (pid, ppid)
        }
        var result: [Int32] = []
        var frontier = [parent]
        while let current = frontier.popLast() {
            for (pid, ppid) in pairs where ppid == current && pid != parent && !result.contains(pid) {
                result.append(pid)
                frontier.append(pid)
            }
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
}

private struct PreviewProcessResult: Sendable {
    let output: Data
    let error: Data
    let status: Int32
}

private final class ProcessDataBox: @unchecked Sendable {
    var data = Data()
}

enum PreviewError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}
