import Foundation

@MainActor
final class LibraryRepairService {
    struct ArtworkInfo: Codable, Identifiable, Equatable {
        let index: Int; let mimeType: String?; let bytes: Int; let extractedPath: String?
        var id: Int { index }
    }
    struct Inspection: Codable, Equatable {
        let path: String; let tagType: String?; let artist: String?; let title: String?; let album: String?
        let albumArtist: String?; let track: Int?; let disc: Int?; let date: String?; let genre: String?; let comment: String?
        let artwork: [ArtworkInfo]
    }
    struct InspectionResponse: Codable { let ok: Bool; let track: Inspection; let error: String? }
    struct RepairResponse: Codable { let ok: Bool; let track: Inspection; let backupPath: String?; let error: String? }
    struct Suggestion: Codable, Identifiable, Equatable {
        let artist: String?; let title: String?; let album: String?; let artworkURL: String?
        var id: String { [artist, title, album].compactMap { $0 }.joined(separator: "|") }
        enum CodingKeys: String, CodingKey { case artist, title, album; case artworkURL = "artworkUrl" }
    }
    struct SuggestionsResponse: Codable { let ok: Bool; let current: Inspection?; let suggestion: Suggestion?; let warning: String?; let error: String? }

    private let cli: NeedleCLIService
    private let artworkDirectory: URL
    init(cli: NeedleCLIService = NeedleCLIService()) {
        self.cli = cli
        artworkDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("needle-library-artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
    }
    func inspect(_ track: TrackRequest, settings: NeedleSettings) async -> Result<Inspection, Error> {
        guard let path = track.savedPath, !path.isEmpty else { return .failure(CLIError.message("This recording has not been saved yet.")) }
        do {
            let response = try NeedleCLIService.parseLastJSON(InspectionResponse.self, data: await cli.runJSONCommand(["inspect", path, "--artwork-dir", artworkDirectory.path, "--json"], settings: settings))
            guard response.ok else { throw CLIError.message(response.error ?? "Needle could not read this recording.") }
            return .success(response.track)
        } catch { return .failure(error) }
    }
    func suggestions(for inspection: Inspection, settings: NeedleSettings) async -> Result<([Suggestion], String?), Error> {
        do {
            let response = try NeedleCLIService.parseLastJSON(SuggestionsResponse.self, data: await cli.runJSONCommand(["repair-suggestions", inspection.path, "--json"], settings: settings))
            guard response.ok else { throw CLIError.message(response.error ?? "No metadata suggestions were found.") }
            return .success((response.suggestion.map { [$0] } ?? [], response.warning))
        } catch { return .failure(error) }
    }
    func sourceArtwork(_ track: TrackRequest, settings: NeedleSettings) async -> Result<URL, Error> {
        guard !track.sourceURL.isEmpty else { return .failure(CLIError.message("This recording has no saved source link.")) }
        var lookup = settings; lookup.noMetadata = true
        switch await cli.search(artist: track.artist, title: track.title, sourceURL: track.sourceURL, settings: lookup) {
        case .success(let response):
            guard let candidate = response.candidates.first(where: { $0.candidate.url == track.sourceURL }), let artwork = candidate.candidate.thumbnailURL, let url = URL(string: artwork) else { return .failure(CLIError.message("The original source did not provide artwork.")) }
            return .success(url)
        case .failure(let error): return .failure(error)
        }
    }
    func repair(_ track: TrackRequest, artist: String?, title: String?, album: String?, clearAlbum: Bool, artworkURL: URL?, remoteArtworkURL: URL? = nil, settings: NeedleSettings) async -> Result<(Inspection, String?), Error> {
        guard let path = track.savedPath, !path.isEmpty else { return .failure(CLIError.message("This recording has not been saved yet.")) }
        var args = ["repair", path]
        if let artist, !artist.isEmpty { args += ["--artist", artist] }
        if let title, !title.isEmpty { args += ["--title", title] }
        if clearAlbum { args += ["--clear-album"] } else if let album, !album.isEmpty { args += ["--album", album] }
        if let artworkURL { args += ["--artwork", artworkURL.path] }
        if let remoteArtworkURL { args += ["--artwork-url", remoteArtworkURL.absoluteString] }
        args += ["--json"]
        do {
            let response = try NeedleCLIService.parseLastJSON(RepairResponse.self, data: await cli.runJSONCommand(args, settings: settings))
            guard response.ok else { throw CLIError.message(response.error ?? "Needle could not repair this recording.") }
            return .success((response.track, response.backupPath))
        } catch { return .failure(error) }
    }
}
