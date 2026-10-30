import Foundation

enum Destination: String, CaseIterable, Identifiable {
    case addMusic = "Add Music", reviewQueue = "Review Queue", discover = "Discover", bookmarks = "Bookmarks", activity = "Activity", library = "Library"
    var id: String { rawValue }
    var symbol: String { switch self { case .addMusic: "plus.circle.fill"; case .reviewQueue: "list.bullet.rectangle"; case .discover: "sparkles"; case .bookmarks: "bookmark.fill"; case .activity: "clock.fill"; case .library: "music.note.list" } }
}

struct NeedleSettings: Codable, Equatable {
    var provider = "auto"
    var albumHint = ""
    var noMetadata = false
    var durationOverride = ""
    var format = "mp3"
    var playlistName = "Needle"
    var cliPath = ""
    var browserSession: BrowserSessionBrowser?
    var browserProfile: String?
}

enum JobStage: String, Codable {
    case searching, saving, metadata, download, convert, tag, saved, spotifyPending, spotifyAdded, interrupted, failed, cancelled
    var label: String {
        switch self {
        case .searching: "Resolving source"
        case .saving: "Saving file"
        case .metadata: "Identifying recording"
        case .download: "Downloading audio"
        case .convert: "Preparing audio"
        case .tag: "Writing track details"
        case .saved: "Saved to your computer"
        case .spotifyPending: "Waiting for Spotify"
        case .spotifyAdded: "Added to Spotify playlist"
        case .interrupted: "Interrupted — review before retrying"
        case .failed: "Needs attention"
        case .cancelled: "Cancelled"
        }
    }
    static func progress(_ stage: String) -> JobStage? {
        switch stage {
        case "metadata": .metadata
        case "search": .searching
        case "download": .download
        case "convert": .convert
        case "tag": .tag
        case "save": .saving
        default: nil
        }
    }
}

struct TrackRequest: Codable, Equatable, Identifiable {
    let id: UUID
    var artist: String
    var title: String
    var album: String
    var sourceURL: String
    var savedPath: String?
    var spotifyStatus: SpotifyStatus
    var spotifyJobID: String?
    /// Optional fields keep history written by older builds decodable.
    var spotifyPlaylistName: String?
    var spotifyPlaylistURI: String?
    var spotifyMetadataSnapshot: SpotifyMetadataSnapshot?
    var spotifyReconcileNeeded: Bool?
    var stage: JobStage
    var settingsSnapshot: NeedleSettings?
    var errorDetail: String?
    var date: Date
    /// True when the file was discovered on disk rather than downloaded in this app session.
    /// Optional for compatibility with history written by older releases.
    var discoveredFromFolder: Bool?
    var artworkUpdatedAt: Date?
    var artworkSuppressed: Bool?

    init(id: UUID = UUID(), artist: String, title: String, album: String = "", sourceURL: String = "", savedPath: String? = nil, spotifyStatus: SpotifyStatus = .notQueued, spotifyJobID: String? = nil, spotifyPlaylistName: String? = nil, spotifyPlaylistURI: String? = nil, stage: JobStage = .saving, settingsSnapshot: NeedleSettings? = nil, date: Date = .now, discoveredFromFolder: Bool? = nil) {
        self.id = id; self.artist = artist; self.title = title; self.album = album; self.sourceURL = sourceURL; self.savedPath = savedPath; self.spotifyStatus = spotifyStatus; self.spotifyJobID = spotifyJobID; self.spotifyPlaylistName = spotifyPlaylistName; self.spotifyPlaylistURI = spotifyPlaylistURI; self.stage = stage; self.settingsSnapshot = settingsSnapshot; self.date = date
        self.discoveredFromFolder = discoveredFromFolder
    }
}

enum SpotifyStatus: String, Codable { case notQueued, pending, added, unknown, failed }

struct SearchResponse: Codable {
    let ok: Bool
    let request: RequestEcho?
    let metadata: Metadata?
    let candidates: [CandidateResult]
    let error: String?
}
struct RequestEcho: Codable { let artist: String?; let title: String? }
struct ArtworkReference: Codable, Equatable, Sendable {
    let url: String
    let provider: String
    let releaseId: String?
    let releaseGroupId: String?
}

struct Metadata: Codable {
    let artist: String?
    let title: String?
    let album: String?
    let durationMs: Int?
    let artworkURL: String?
    let artwork: ArtworkReference?

    init(artist: String?, title: String?, album: String?, durationMs: Int?, artworkURL: String? = nil, artwork: ArtworkReference? = nil) {
        self.artist = artist
        self.title = title
        self.album = album
        self.durationMs = durationMs
        self.artworkURL = artworkURL
        self.artwork = artwork
    }

    var resolvedArtwork: ArtworkReference? {
        artwork ?? artworkURL.map { ArtworkReference(url: $0, provider: "metadata", releaseId: nil, releaseGroupId: nil) }
    }

    enum CodingKeys: String, CodingKey {
        case artist, title, album, durationMs, artwork
        case artworkURL = "artworkUrl"
        case artworkURLSnake = "artwork_url"
        case durationMsSnake = "duration_ms"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        artist = try values.decodeIfPresent(String.self, forKey: .artist)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        album = try values.decodeIfPresent(String.self, forKey: .album)
        durationMs = try values.decodeIfPresent(Int.self, forKey: .durationMs) ?? values.decodeIfPresent(Int.self, forKey: .durationMsSnake)
        artworkURL = try values.decodeIfPresent(String.self, forKey: .artworkURL) ?? values.decodeIfPresent(String.self, forKey: .artworkURLSnake)
        artwork = try values.decodeIfPresent(ArtworkReference.self, forKey: .artwork)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(artist, forKey: .artist)
        try values.encodeIfPresent(title, forKey: .title)
        try values.encodeIfPresent(album, forKey: .album)
        try values.encodeIfPresent(durationMs, forKey: .durationMs)
        try values.encodeIfPresent(artworkURL, forKey: .artworkURL)
        try values.encodeIfPresent(artwork, forKey: .artwork)
    }
}
struct CandidateResult: Codable, Identifiable {
    var id: String { candidate.provider + ":" + candidate.id }
    let candidate: Candidate
    let score: Score
}
struct Candidate: Codable {
    let provider: String
    let id: String
    let url: String
    let title: String
    let uploader: String?
    /// Whether the provider reports the uploader channel as verified.
    let channelIsVerified: Bool?
    let durationMs: Int?
    let thumbnailURL: String?
    /// View count reported by the source provider, when available.
    var viewCount: UInt64? = nil
    /// Codec selected by yt-dlp for the source audio stream, when available.
    var audioCodec: String? = nil
    /// Source audio bitrate in kbps. This is the input stream quality, not a
    /// later MP3 conversion bitrate.
    var audioBitrateKbps: UInt32? = nil

    init(provider: String, id: String, url: String, title: String, uploader: String?,
         durationMs: Int?, thumbnailURL: String?, channelIsVerified: Bool? = nil, viewCount: UInt64? = nil,
         audioCodec: String? = nil, audioBitrateKbps: UInt32? = nil) {
        self.provider = provider
        self.id = id
        self.url = url
        self.title = title
        self.uploader = uploader
        self.channelIsVerified = channelIsVerified
        self.durationMs = durationMs
        self.thumbnailURL = thumbnailURL
        self.viewCount = viewCount
        self.audioCodec = audioCodec
        self.audioBitrateKbps = audioBitrateKbps
    }

    enum CodingKeys: String, CodingKey {
        case provider, id, url, title, uploader, durationMs, channelIsVerified
        case channelIsVerifiedSnake = "channel_is_verified"
        case thumbnailURL = "thumbnailUrl"
        case viewCount
        case viewCountSnake = "view_count"
        case audioCodec
        case audioCodecSnake = "audio_codec"
        case audioBitrateKbps
        case audioBitrateKbpsSnake = "audio_bitrate_kbps"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(String.self, forKey: .provider)
        id = try container.decode(String.self, forKey: .id)
        url = try container.decode(String.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        uploader = try container.decodeIfPresent(String.self, forKey: .uploader)
        channelIsVerified = try container.decodeIfPresent(Bool.self, forKey: .channelIsVerified)
            ?? (try container.decodeIfPresent(Bool.self, forKey: .channelIsVerifiedSnake))
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        thumbnailURL = try container.decodeIfPresent(String.self, forKey: .thumbnailURL)
        viewCount = try container.decodeIfPresent(UInt64.self, forKey: .viewCount)
            ?? (try container.decodeIfPresent(UInt64.self, forKey: .viewCountSnake))
        audioCodec = try container.decodeIfPresent(String.self, forKey: .audioCodec)
            ?? (try container.decodeIfPresent(String.self, forKey: .audioCodecSnake))
        audioBitrateKbps = try container.decodeIfPresent(UInt32.self, forKey: .audioBitrateKbps)
            ?? (try container.decodeIfPresent(UInt32.self, forKey: .audioBitrateKbpsSnake))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(uploader, forKey: .uploader)
        try container.encodeIfPresent(channelIsVerified, forKey: .channelIsVerifiedSnake)
        try container.encodeIfPresent(durationMs, forKey: .durationMs)
        try container.encodeIfPresent(thumbnailURL, forKey: .thumbnailURL)
        try container.encodeIfPresent(viewCount, forKey: .viewCountSnake)
        try container.encodeIfPresent(audioCodec, forKey: .audioCodecSnake)
        try container.encodeIfPresent(audioBitrateKbps, forKey: .audioBitrateKbpsSnake)
    }
}
struct Score: Codable { let confidence: Double?; let status: String; let positives: [String]; let warnings: [String]; let rejects: [String] }

struct HostReceipt: Codable { let ok: Bool; let jobId: String?; let error: String? }
struct SpotifyMetadataSnapshot: Codable, Equatable {
    let name: String
    let artist: String
    let album: String?
    let savedPath: String?
    var durationMs: UInt64? = nil
    var fileRevision: String? = nil

    init(track: TrackRequest) {
        name = track.title; artist = track.artist; album = track.album.isEmpty ? nil : track.album; savedPath = track.savedPath
    }
}

struct HostStatus: Codable {
    let ok: Bool
    let status: String
    let playlistUri: String?
    let addedUri: String?
    var detail: String? = nil
    var track: SpotifyMetadataSnapshot? = nil
}
struct DoctorResponse: Codable { let ok: Bool; let tools: [DoctorTool] }
struct DoctorTool: Codable { let name: String?; let path: String?; let ok: Bool?; let optional: Bool?; let message: String?; let version: String? }
