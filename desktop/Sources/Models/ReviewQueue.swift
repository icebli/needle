import Foundation
import Observation

enum ReviewState: String, Codable {
    case queued, searching, ready, needsInput, approved, downloading, saved, failed, skipped, interrupted
    var label: String {
        switch self {
        case .queued: "Waiting to search"
        case .searching: "Finding recordings…"
        case .ready: "Ready to review"
        case .needsInput: "Add artist and title"
        case .approved: "Approved · waiting to download"
        case .downloading: "Downloading…"
        case .saved: "Saved"
        case .failed: "Needs attention"
        case .skipped: "Skipped"
        case .interrupted: "Interrupted · review before retrying"
        }
    }
}

struct ReviewItem: Codable, Identifiable {
    var id = UUID()
    var artist = ""
    var title = ""
    var sourceURL = ""
    var input: String
    var settings: NeedleSettings
    var state: ReviewState = .queued
    var response: SearchResponse?
    var approvedCandidate: CandidateResult?
    var queueSpotify = false
    var trackID: UUID?
    var detail: String?
    var label: String { artist.isEmpty ? (title.isEmpty ? input : title) : "\(artist) — \(title)" }

    @MainActor static func parse(_ text: String, settings: NeedleSettings) -> [ReviewItem] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.prefix(100).map { line in
                var item = ReviewItem(input: line, settings: settings)
                if AppModel.mediaURL(line) != nil { item.sourceURL = line; return item }
                for separator in ["\t", " — ", " – ", " - "] {
                    if let range = line.range(of: separator) {
                        item.artist = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                        item.title = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
                if item.artist.isEmpty || item.title.isEmpty {
                    item.state = .needsInput
                    item.detail = "Use Artist — Title, or edit this item before searching."
                }
                return item
            }
    }
}

@MainActor @Observable
final class ReviewQueue {
    var items: [ReviewItem] { didSet { persist() } }
    var selectedID: UUID?
    var onSaved: ((TrackRequest, Bool) -> Void)?
    private let defaults: UserDefaults
    private let history: HistoryStore
    private var searchService: NeedleCLIService?
    private var searchID: UUID?
    private var downloads: [UUID: NeedleCLIService] = [:]
    private let key = "needle.reviewQueue"
    var activeDownloads: Int { downloads.count }
    var selected: ReviewItem? { items.first { $0.id == selectedID } }

    init(defaults: UserDefaults = .standard, history: HistoryStore) {
        self.defaults = defaults
        self.history = history
        items = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([ReviewItem].self, from: $0) } ?? []
        for index in items.indices {
            if let trackID = items[index].trackID, history.tracks.contains(where: { $0.id == trackID && $0.savedPath != nil }) {
                items[index].state = .saved
            } else if [.searching, .approved, .downloading].contains(items[index].state) {
                items[index].state = .interrupted
                items[index].detail = "Needle stopped during this item. Review it before retrying; no download starts automatically."
            }
        }
        selectedID = items.first(where: { ![.saved, .skipped].contains($0.state) })?.id ?? items.first?.id
        persist()
    }

    func add(_ text: String, settings: NeedleSettings) {
        let additions = ReviewItem.parse(text, settings: settings)
        items.append(contentsOf: additions)
        if selectedID == nil { selectedID = additions.first?.id }
        searchNext()
    }

    func update(_ item: ReviewItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
    }

    func edit(id: UUID, artist: String, title: String, source: String) {
        guard var item = items.first(where: { $0.id == id }), ![.approved, .downloading, .saved, .searching].contains(item.state) else { return }
        item.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        item.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        item.sourceURL = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard item.sourceURL.isEmpty || AppModel.mediaURL(item.sourceURL) != nil else {
            item.detail = "Use an http or https source link."; update(item); return
        }
        guard !item.artist.isEmpty, !item.title.isEmpty else {
            item.state = .needsInput; item.detail = "Enter artist and title."; update(item); return
        }
        item.state = .queued; item.response = nil; item.approvedCandidate = nil; item.detail = nil
        update(item)
        searchNext()
    }

    func skip(_ id: UUID) {
        guard var item = items.first(where: { $0.id == id }), ![.searching, .approved, .downloading, .saved].contains(item.state) else { return }
        item.state = .skipped; update(item); selectNext(after: id)
    }

    func removeFinished() {
        items.removeAll { [.saved, .skipped].contains($0.state) }
        if !items.contains(where: { $0.id == selectedID }) { selectedID = items.first?.id }
    }

    func approve(_ candidate: CandidateResult, itemID: UUID, spotify: Bool) {
        guard var item = items.first(where: { $0.id == itemID }), item.state == .ready,
              candidate.score.status != "rejected", AppModel.mediaURL(candidate.candidate.url) != nil,
              item.response?.candidates.contains(where: { $0.id == candidate.id && $0.candidate.url == candidate.candidate.url }) == true else { return }
        item.approvedCandidate = candidate; item.queueSpotify = spotify && item.settings.format == "mp3"
        item.state = .approved; item.detail = nil; update(item)
        downloadNext()
        selectNext(after: itemID)
    }

    func cancel(_ id: UUID) {
        if searchID == id, let service = searchService { Task { await service.cancel() } }
        if let service = downloads[id] { Task { await service.cancel() } }
    }

    private func selectNext(after id: UUID) {
        selectedID = items.first(where: { $0.id != id && [.ready, .needsInput, .failed, .interrupted, .queued, .searching].contains($0.state) })?.id ?? id
    }

    func searchNext() {
        guard searchID == nil, var item = items.first(where: { $0.state == .queued }) else { return }
        let service = NeedleCLIService()
        searchID = item.id; searchService = service
        item.state = .searching; item.detail = nil; update(item)
        Task {
            if item.artist.isEmpty || item.title.isEmpty {
                switch await service.identifyURL(item.sourceURL, settings: item.settings) {
                case .success(let identity):
                    item.artist = identity.artist ?? ""; item.title = identity.title ?? ""
                    // Source uploader names are hints. Require a human to check
                    // identity before searching or approving a link-only entry.
                    item.state = .needsInput
                    item.detail = "Check the detected artist and title, then find recordings."
                    update(item)
                case .failure(let error):
                    item.state = .needsInput; item.detail = error.localizedDescription; update(item)
                }
            } else {
                switch await service.search(artist: item.artist, title: item.title, sourceURL: item.sourceURL, settings: item.settings) {
                case .success(let response):
                    item.response = response
                    item.state = response.candidates.isEmpty ? .failed : .ready
                    item.detail = response.candidates.isEmpty ? "No recordings found. Edit the request or try a source link." : nil
                case .failure(let error):
                    item.state = error is CancellationError ? .interrupted : .failed
                    item.detail = error.localizedDescription
                }
                update(item)
            }
            searchID = nil; searchService = nil
            searchNext()
        }
    }

    private func downloadNext() {
        while downloads.count < 2, var item = items.first(where: { $0.state == .approved }) {
            guard let candidate = item.approvedCandidate else { item.state = .ready; update(item); continue }
            let service = NeedleCLIService()
            downloads[item.id] = service
            item.state = .downloading
            let track = TrackRequest(artist: item.artist, title: item.title,
                                     album: item.settings.albumHint,
                                     sourceURL: candidate.candidate.url, stage: .metadata, settingsSnapshot: item.settings)
            item.trackID = track.id; update(item); history.upsert(track)
            let approved = item
            Task {
                let result = await service.get(track: track, settings: approved.settings, onProgress: { [weak self] stage in
                    Task { @MainActor in
                        guard let self, self.downloads[approved.id] != nil,
                              var current = self.history.tracks.first(where: { $0.id == track.id }),
                              let stage = JobStage.progress(stage), current.savedPath == nil else { return }
                        current.stage = stage; self.history.upsert(current)
                    }
                })
                var finished = self.items.first(where: { $0.id == approved.id }) ?? approved
                switch result {
                case .success(var saved):
                    saved.stage = .saved; self.history.upsert(saved)
                    finished.state = .saved; finished.detail = saved.savedPath
                    self.onSaved?(saved, approved.queueSpotify)
                case .failure(let error):
                    var failed = self.history.tracks.first(where: { $0.id == track.id }) ?? track
                    failed.stage = error is CancellationError ? .cancelled : .failed
                    failed.errorDetail = error.localizedDescription; self.history.upsert(failed)
                    finished.state = .failed; finished.detail = error.localizedDescription
                }
                self.update(finished)
                self.downloads.removeValue(forKey: approved.id)
                self.downloadNext()
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: key) }
    }
}
