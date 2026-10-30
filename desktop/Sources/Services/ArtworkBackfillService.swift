import Foundation
import Observation

struct ArtworkBackfillRequest: Sendable {
    let artist: String
    let title: String
    let album: String
    let path: String?
    var sourceTitle: String? = nil

    var arguments: [String] {
        var args = ["artwork", "--artist", artist, "--title", title, "--album", album, "--json"]
        if let path { args += ["--path", path] }
        if let sourceTitle { args += ["--source-title", sourceTitle] }
        return args
    }
}

struct ArtworkBackfillResponse: Decodable {
    let ok: Bool
    let artwork: ArtworkReference?
    let status: String?
    let error: String?
    let reason: String?

    init(ok: Bool, artwork: ArtworkReference?, status: String?, error: String?, reason: String? = nil) {
        self.ok = ok
        self.artwork = artwork
        self.status = status
        self.error = error
        self.reason = reason
    }
}

@MainActor @Observable
final class ArtworkBackfillService {
    var onFileUpdated: ((TrackRequest, TrackRequest) -> Void)?
    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var checked = 0
    private(set) var total = 0
    private(set) var filled = 0
    private(set) var unavailable = 0
    private(set) var needsMetadataReview = 0
    private(set) var missingSourceEvidence = 0
    private(set) var catalogMisses = 0
    private(set) var temporaryFailures = 0
    var unspecifiedMisses: Int {
        unavailable - needsMetadataReview - missingSourceEvidence - catalogMisses - temporaryFailures
    }
    private let defaults: UserDefaults
    private let cli = NeedleCLIService()
    private let lookup: ((ArtworkBackfillRequest, NeedleSettings) async throws -> ArtworkBackfillResponse)?
    private let now: () -> Date
    private var nextAttempts: [String: Date]
    private let ledgerKey = "needle.artworkBackfill.v2"

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         lookup: ((ArtworkBackfillRequest, NeedleSettings) async throws -> ArtworkBackfillResponse)? = nil) {
        self.defaults = defaults
        self.now = now
        self.lookup = lookup
        nextAttempts = defaults.data(forKey: ledgerKey).flatMap {
            try? JSONDecoder().decode([String: Date].self, from: $0)
        } ?? [:]
    }

    func stop() {
        isPaused = true
        Task { await cli.cancel() }
    }

    func run(bookmarks: BookmarkStore, history: HistoryStore, settings: NeedleSettings, retry: Bool = false) async {
        guard !isRunning, retry || !isPaused else { return }
        guard Self.jobs(bookmarks: bookmarks, history: history).contains(where: {
            retry || nextAttempts[$0.key, default: .distantPast] <= now()
        }) else { return }
        isRunning = true
        isPaused = false
        checked = 0; total = 0; filled = 0; unavailable = 0
        needsMetadataReview = 0; missingSourceEvidence = 0; catalogMisses = 0; temporaryFailures = 0
        defer { isRunning = false }
        var attempted = Set<String>()
        while !isPaused && !Task.isCancelled {
            let jobs = Self.jobs(bookmarks: bookmarks, history: history).filter {
                !attempted.contains($0.key) && (retry || nextAttempts[$0.key, default: .distantPast] <= now())
            }
            guard !jobs.isEmpty else { break }
            total += jobs.count
            for job in jobs {
                guard !isPaused, !Task.isCancelled else { return }
                if lookup == nil, checked > 0 {
                    do { try await Task.sleep(for: .milliseconds(1100)) }
                    catch { return }
                    guard !isPaused else { return }
                }
                attempted.insert(job.key)
                let timeout = Task {
                    do { try await Task.sleep(for: .seconds(45)); await cli.cancel() }
                    catch { }
                }
                do {
                    let response: ArtworkBackfillResponse
                    if let lookup { response = try await lookup(job.request, settings) }
                    else {
                        response = try NeedleCLIService.parseLastJSON(ArtworkBackfillResponse.self,
                            data: await cli.runJSONCommand(job.request.arguments, settings: settings))
                    }
                    timeout.cancel()
                    guard !isPaused, !Task.isCancelled else { return }
                    guard response.ok else { throw CLIError.message("Artwork lookup is unavailable.") }
                    switch response.status {
                    case "matched":
                        if let artwork = response.artwork, let bookmark = job.bookmark,
                           bookmarks.fillArtwork(artwork, for: bookmark) { filled += 1 }
                        remember(job.key, after: 7 * 24 * 3600)
                    case "filled", "existing":
                        if response.status == "filled", let original = job.track,
                           let index = history.tracks.firstIndex(where: { $0.id == original.id }),
                           Self.sameRecording(history.tracks[index], original) {
                            history.tracks[index].artworkUpdatedAt = now()
                            onFileUpdated?(history.tracks[index], original)
                            filled += 1
                        }
                        remember(job.key, after: 7 * 24 * 3600)
                    case "unmatched":
                        unavailable += 1
                        switch response.reason {
                        case "source_identity_or_filename_conflict", "unverified_album_variant_requires_metadata_review":
                            needsMetadataReview += 1
                        case "missing_independent_source_evidence":
                            missingSourceEvidence += 1
                        case "no_verified_catalog_cover":
                            catalogMisses += 1
                        default:
                            break
                        }
                        remember(job.key, after: 6 * 3600)
                    default:
                        throw CLIError.message("Artwork lookup returned an unsupported result.")
                    }
                } catch {
                    timeout.cancel()
                    guard !isPaused, !Task.isCancelled else { return }
                    unavailable += 1
                    temporaryFailures += 1
                    remember(job.key, after: 15 * 60)
                }
                checked += 1
            }
        }
    }

    private struct Job {
        let request: ArtworkBackfillRequest
        let key: String
        let bookmark: ReleaseBookmark?
        let track: TrackRequest?
    }

    private static func jobs(bookmarks: BookmarkStore, history: HistoryStore) -> [Job] {
        var jobs = bookmarks.items.filter { $0.artwork == nil }.map { bookmark in
            let request = ArtworkBackfillRequest(artist: bookmark.artist, title: bookmark.title, album: bookmark.album, path: nil, sourceTitle: bookmark.candidate.title)
            return Job(request: request,
                       key: key(["bookmark", bookmark.id, bookmark.candidate.url, String(bookmark.date.timeIntervalSince1970), bookmark.artist, bookmark.title, bookmark.album]),
                       bookmark: bookmark, track: nil)
        }
        var paths = Set<String>()
        for track in history.tracks {
            guard let path = track.savedPath, !path.isEmpty,
                  track.artworkSuppressed != true,
                  ![.searching, .saving, .metadata, .download, .convert, .tag].contains(track.stage) else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard paths.insert(url.path).inserted,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            jobs.append(Job(request: ArtworkBackfillRequest(artist: track.artist, title: track.title, album: track.album, path: url.path),
                            key: key(["file", url.path, track.artist, track.title, track.album,
                                      String(values.fileSize ?? 0), String(values.contentModificationDate?.timeIntervalSince1970 ?? 0)]),
                            bookmark: nil, track: track))
        }
        return jobs
    }

    private static func key(_ parts: [String]) -> String {
        (try? JSONEncoder().encode(parts).base64EncodedString()) ?? ""
    }

    private static func sameRecording(_ current: TrackRequest, _ original: TrackRequest) -> Bool {
        current.savedPath == original.savedPath && current.artist == original.artist && current.title == original.title
            && current.album == original.album && current.sourceURL == original.sourceURL && current.artworkSuppressed != true
    }

    private func remember(_ key: String, after seconds: TimeInterval) {
        nextAttempts[key] = now().addingTimeInterval(seconds)
        if nextAttempts.count > 30_000 {
            nextAttempts = Dictionary(uniqueKeysWithValues: nextAttempts.sorted { $0.value > $1.value }.prefix(30_000).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(nextAttempts) { defaults.set(data, forKey: ledgerKey) }
    }
}
