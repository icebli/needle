import Foundation
import Observation

@Observable
final class SettingsStore {
    var value: NeedleSettings { didSet { save() } }
    private let defaults: UserDefaults
    private let key = "needle.settings"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        value = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(NeedleSettings.self, from: $0) } ?? NeedleSettings()
    }
    private func save() {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}

@Observable
final class HistoryStore {
    var tracks: [TrackRequest] { didSet { save() } }
    private let defaults: UserDefaults
    private let key = "needle.history"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tracks = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([TrackRequest].self, from: $0) } ?? []
        tracks = tracks.map {
            var track = $0
            if track.savedPath == nil && [.searching, .saving, .metadata, .download, .convert, .tag].contains(track.stage) {
                track.stage = .interrupted
            }
            return track
        }
        save()
    }
    func upsert(_ track: TrackRequest) {
        tracks.removeAll { $0.id == track.id }
        tracks.insert(track, at: 0)
    }

    /// Merge files found on disk without changing the identity or delivery state of
    /// downloads already tracked by Needle. Paths are the stable key because an
    /// imported file has no source URL or download job to identify it by.
    @discardableResult
    func mergeLibraryTracks(_ imported: [TrackRequest]) -> Int {
        var changed = false
        var added = 0
        var mergedTracks = tracks
        for discovered in imported {
            guard let path = discovered.savedPath, !path.isEmpty else { continue }
            let canonical = Self.canonicalPath(path)
            if let index = mergedTracks.firstIndex(where: { track in
                guard let existingPath = track.savedPath else { return false }
                return Self.canonicalPath(existingPath) == canonical
            }) {
                var existing = mergedTracks[index]
                let isInFlight = [.searching, .saving, .metadata, .download, .convert, .tag].contains(existing.stage)
                if !isInFlight {
                    if !discovered.artist.isEmpty { existing.artist = discovered.artist }
                    if !discovered.title.isEmpty { existing.title = discovered.title }
                    existing.album = discovered.album
                    if existing.sourceURL.isEmpty, !discovered.sourceURL.isEmpty { existing.sourceURL = discovered.sourceURL }
                    if existing.settingsSnapshot == nil { existing.settingsSnapshot = discovered.settingsSnapshot }
                    if existing.date < discovered.date { existing.date = discovered.date }
                    if existing.discoveredFromFolder != true { existing.discoveredFromFolder = false }
                    if existing != mergedTracks[index] { mergedTracks[index] = existing; changed = true }
                }
            } else {
                mergedTracks.append(discovered)
                changed = true
                added += 1
            }
        }
        if changed { tracks = mergedTracks }
        return added
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
    private func save() {
        if let data = try? JSONEncoder().encode(tracks) { defaults.set(data, forKey: key) }
    }
}
