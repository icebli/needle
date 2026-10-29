import Foundation

@MainActor
final class LibraryScanService {
    struct ResultSummary {
        let imported: Int
        let warnings: [String]
    }

    private let cli: NeedleCLIService
    init(cli: NeedleCLIService = NeedleCLIService()) { self.cli = cli }

    func scan(root: URL, settings: NeedleSettings, history: HistoryStore) async -> Result<ResultSummary, Error> {
        do {
            let response = try await cli.scanLibrary(root: root.path, settings: settings).get()
            let tracks = response.tracks.compactMap(Self.track(from:))
            let imported = history.mergeLibraryTracks(tracks)
            return .success(ResultSummary(imported: imported, warnings: response.warnings))
        } catch { return .failure(error) }
    }

    static func track(from item: NeedleCLIService.LibraryScanTrack) -> TrackRequest? {
        let fileURL = URL(fileURLWithPath: item.path).standardizedFileURL
        let path = fileURL.path
        guard !path.isEmpty else { return nil }
        let extensionName = fileURL.pathExtension.lowercased()
        let supported = Set(["mp3", "flac", "m4a", "aac", "opus", "wav", "ogg", "aiff", "aif"])
        guard supported.contains(extensionName) else { return nil }

        let filename = fileURL.deletingPathExtension().lastPathComponent
        let parent = fileURL.deletingLastPathComponent().lastPathComponent
        let artist = nonEmpty(item.artist) ?? (parent.isEmpty ? "Unknown artist" : parent)
        let title = nonEmpty(item.title) ?? (filename.isEmpty ? "Unknown title" : filename)
        let album = nonEmpty(item.album) ?? ""
        let modified = item.modifiedMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } ?? .now
        var settings = NeedleSettings()
        settings.format = extensionName
        return TrackRequest(artist: artist, title: title, album: album,
                            sourceURL: nonEmpty(item.sourceURL) ?? "", savedPath: path,
                            stage: .saved, settingsSnapshot: settings, date: modified,
                            discoveredFromFolder: true)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
