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
    private func save() {
        if let data = try? JSONEncoder().encode(tracks) { defaults.set(data, forKey: key) }
    }
}
