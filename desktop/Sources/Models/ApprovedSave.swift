import Foundation
import CryptoKit
import ImageIO

enum SaveRetrySafety: String, Codable {
    case retryable, requiresReview, requiresArtworkReview
}

enum ApprovedArtwork: Codable, Equatable {
    case none
    case pending
    case captured(fileName: String, sha256: String)
}

struct ApprovedSave: Codable, Equatable {
    let metadata: MetadataDraft
    let settings: NeedleSettings
    let queueSpotify: Bool
    let artwork: ApprovedArtwork

    init(metadata: MetadataDraft, settings: NeedleSettings, queueSpotify: Bool, artwork: ApprovedArtwork? = nil) {
        self.metadata = metadata
        self.settings = settings
        self.queueSpotify = queueSpotify && settings.format == "mp3"
        self.artwork = artwork ?? (metadata.artworkSuppressed == true || metadata.artworkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .none : .pending)
    }
}

struct ApprovedArtworkStore: Sendable {
    let directory: URL
    private let load: @Sendable (URL) async throws -> Data
    private static let limit = 10 * 1024 * 1024

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Needle/Approved Artwork", isDirectory: true),
         load: @escaping @Sendable (URL) async throws -> Data = ApprovedArtworkStore.loadImage) {
        self.directory = directory
        self.load = load
    }

    func capture(_ approval: ApprovedSave, trackID: UUID) async throws -> ApprovedSave {
        guard case .pending = approval.artwork else { return approval }
        guard let location = URL(string: approval.metadata.artworkURL),
              ["file", "https", "http"].contains(location.scheme?.lowercased() ?? ""),
              !location.isFileURL || location.host == nil || location.host == "" || location.host == "localhost" else {
            throw CLIError.message("The approved artwork location is invalid. Your approval is retained.")
        }
        let bytes = try await load(location)
        try Self.validate(bytes)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = trackID.uuidString + ".image"
        try bytes.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        return ApprovedSave(metadata: approval.metadata, settings: approval.settings, queueSpotify: approval.queueSpotify,
                            artwork: .captured(fileName: fileName, sha256: Self.digest(bytes)))
    }

    func commandMetadata(_ approval: ApprovedSave) throws -> MetadataDraft {
        var metadata = approval.metadata
        switch approval.artwork {
        case .none:
            metadata.artworkURL = ""
        case .pending:
            throw CLIError.message("The approved artwork has not been captured. Retry to fetch the same approved image.")
        case .captured(let fileName, let expectedDigest):
            guard fileName == URL(fileURLWithPath: fileName).lastPathComponent else {
                throw SaveAttemptFailure(detail: "The retained artwork reference is invalid. No replacement image was selected.", safety: .requiresArtworkReview)
            }
            let location = directory.appendingPathComponent(fileName)
            guard let bytes = try? Self.readFile(location), Self.digest(bytes) == expectedDigest,
                  (try? Self.validate(bytes)) != nil else {
                throw SaveAttemptFailure(detail: "The retained approved artwork is missing or damaged. Needle will not substitute another image.", safety: .requiresArtworkReview)
            }
            metadata.artworkURL = location.absoluteString
        }
        return metadata
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func validate(_ bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= limit,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = values[kCGImagePropertyPixelWidth] as? Int,
              let height = values[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8_192, height <= 8_192, width * height <= 32_000_000,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw CLIError.message("The approved artwork did not return a usable image under 10 MiB. Your approval is retained for Retry.")
        }
    }

    private static func readFile(_ location: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: location)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw CLIError.message("The approved artwork exceeds 10 MiB.") }
        return bytes
    }

    private static func loadImage(_ location: URL) async throws -> Data {
        if location.isFileURL { return try readFile(location) }
        var request = URLRequest(url: location)
        request.timeoutInterval = 15
        let (stream, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.expectedContentLength <= Int64(limit) else {
            throw CLIError.message("The approved artwork could not be fetched. Your approval is retained for Retry.")
        }
        var bytes = Data()
        for try await byte in stream {
            guard bytes.count < limit else { throw CLIError.message("The approved artwork exceeds 10 MiB.") }
            bytes.append(byte)
        }
        return bytes
    }
}

struct SaveAttemptFailure: LocalizedError {
    let detail: String
    let safety: SaveRetrySafety
    var cancelled = false
    var savedPath: String?
    var errorDescription: String? { detail }
}

extension TrackRequest {
    var saveNeedsLibraryReview: Bool {
        if saveRetrySafety == .requiresReview || stage == .interrupted && approvedSave != nil { return true }
        guard let errorDetail else { return false }
        if errorDetail.localizedCaseInsensitiveContains("file was kept") { return true }
        return errorDetail.components(separatedBy: .newlines).contains { line in
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
            return event["event"] as? String == "progress" && event["stage"] as? String == "save"
        }
    }
}

extension HistoryStore {
    func canRetrySave(_ track: TrackRequest) -> Bool {
        guard let current = tracks.first(where: { $0.id == track.id }), current.stage == .failed,
              current.savedPath == nil, current.saveRetrySafety == .retryable, !current.saveNeedsLibraryReview,
              let approval = current.approvedSave, approval.metadata.sourceURL == current.sourceURL,
              !current.sourceURL.isEmpty else { return false }
        return !tracks.contains {
            $0.id != current.id && $0.sourceURL == current.sourceURL &&
            ($0.savedPath != nil || $0.saveNeedsLibraryReview || $0.stage == .interrupted ||
             [.metadata, .searching, .download, .convert, .tag, .saving].contains($0.stage))
        }
    }
}

@MainActor
enum ApprovedSaveOperation {
    static func run(_ initial: TrackRequest, history: HistoryStore, artworkStore: ApprovedArtworkStore,
                    service: NeedleCLIService) async -> Result<TrackRequest, Error> {
        var track = initial
        guard let approval = track.approvedSave else {
            return .failure(CLIError.message("This save has no retained approval. Review its source and tags in Add Music."))
        }
        track.stage = .metadata
        track.errorDetail = nil
        track.saveRetrySafety = .requiresReview
        history.upsert(track)
        do {
            let captured = try await artworkStore.capture(approval, trackID: track.id)
            track.approvedSave = captured
            history.upsert(track)
            let metadata = try artworkStore.commandMetadata(captured)
            let id = track.id
            let report: @MainActor @Sendable (String) -> Void = { stage in
                guard var current = history.tracks.first(where: { $0.id == id }),
                      [.metadata, .searching, .download, .convert, .tag, .saving].contains(current.stage),
                      let stage = JobStage.progress(stage) else { return }
                current.stage = stage
                history.upsert(current)
            }
            let result = await service.get(track: track, settings: captured.settings, approved: metadata, onProgress: { stage in
                Task { @MainActor in report(stage) }
            })
            switch result {
            case .success(var saved):
                saved.stage = .saved
                history.upsert(saved)
                return .success(saved)
            case .failure(let error):
                throw error
            }
        } catch {
            let failure = error as? SaveAttemptFailure ?? SaveAttemptFailure(detail: error.localizedDescription, safety: .retryable)
            track.stage = failure.cancelled ? .cancelled : .failed
            track.errorDetail = failure.detail
            track.saveRetrySafety = failure.safety
            track.unconfirmedSavedPath = failure.savedPath
            history.upsert(track)
            return .failure(failure)
        }
    }
}
