import Foundation

struct SpotifyArtist: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let uri: String
    var imageUrl: String?
}

struct SpotifyCatalogTrack: Codable {
    let id: String
    let name: String
    let uri: String
    let artists: [SpotifyArtistCredit]
    var durationMs: Int?
}

struct SpotifyArtistCredit: Codable { let id: String; let name: String }

enum CatalogAvailability: String, Codable {
    case found, noMatch, unknown
    var label: String {
        switch self {
        case .found: "Found on Spotify"
        case .noMatch: "No exact match on Spotify"
        case .unknown: "Spotify availability unknown"
        }
    }
}

struct DiscoveryRecording: Codable, Identifiable {
    var id: String { artist.id + ":" + candidate.provider + ":" + candidate.id }
    let artist: SpotifyArtist
    let title: String
    let candidate: Candidate
    let availability: CatalogAvailability
    var catalogURI: String?
    var detail: String?
}

enum DiscoverySection: String, CaseIterable {
    case leads, unchecked, onSpotify

    var title: String {
        switch self {
        case .leads: "Leads"
        case .unchecked: "Unconfirmed"
        case .onSpotify: "On Spotify"
        }
    }

    func recordings(in recordings: [DiscoveryRecording]) -> [DiscoveryRecording] {
        let availability: CatalogAvailability = switch self {
        case .leads: .noMatch
        case .unchecked: .unknown
        case .onSpotify: .found
        }
        return recordings.filter { $0.availability == availability }
    }
}

/// Read-only metadata calls through the installed Spicetify companion. Spotify
/// credentials stay in Spotify; this process only receives bounded metadata.
actor SpotifyDiscoveryService {
    struct Response: Decodable {
        let ok: Bool
        var artists: [SpotifyArtist]?
        var tracks: [SpotifyCatalogTrack]?
        var error: String?
    }

    func topArtists() async throws -> [SpotifyArtist] {
        let result = try await request(["top-artists"])
        guard let artists = result.artists else { throw CLIError.message("Spotify returned no artist list.") }
        return Array(artists.prefix(100))
    }

    func catalog(artist: String, title: String) async throws -> [SpotifyCatalogTrack] {
        let result = try await request(["catalog", artist, DiscoveryMatching.catalogTitle(title, artist: artist)])
        guard let tracks = result.tracks else { throw CLIError.message("Spotify returned no catalog result.") }
        return tracks
    }

    private func request(_ args: [String]) async throws -> Response {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/needle-browser-host").path,
                     home.appendingPathComponent("Library/Application Support/Needle/bin/needle-browser-host").path,
                     home.appendingPathComponent(".cargo/bin/needle-browser-host").path]
        guard let host = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CLIError.message("Needle’s Spotify companion is missing. Reinstall Needle and enable its companion in setup.")
        }
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: host)
            process.arguments = ["discover"] + args
            let out = Pipe(), err = Pipe()
            process.standardOutput = out; process.standardError = err
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let diagnostic = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
                throw CLIError.message(process.terminationStatus == 0 ? "Spotify returned an unreadable response." :
                    "Spotify discovery could not start. Enable Needle’s companion and open Spotify. \(String(decoding: diagnostic.prefix(400), as: UTF8.self))")
            }
            guard response.ok else { throw CLIError.message(response.error ?? "Spotify could not complete this check.") }
            return response
        }.value
    }
}

enum DiscoveryMatching {
    private static let featureMarkers = [" ft. ", " ft ", " feat. ", " feat ", " featuring ", " w/ ", "(ft. ", "(feat. ", "(featuring ", "(with ", "(w/ ", "[ft. ", "[feat. ", "[featuring ", "[with ", "[w/ "]

    static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "(?<=[\\p{L}\\p{N}])['’](?=[\\p{L}\\p{N}])", with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func title(_ raw: String, artist: String) -> String {
        var result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // This program names the performer and session in prose on YouTube,
        // but uses a title/session suffix in Spotify. Retain the session identity.
        let coverPattern = "(?i)^" + NSRegularExpression.escapedPattern(for: artist)
            + " covers .+ ['‘\"](.+?)['’\"] for Like A Version$"
        if let expression = try? NSRegularExpression(pattern: coverPattern),
           let match = expression.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
           let song = Range(match.range(at: 1), in: result) {
            result = String(result[song]) + " - triple j Like A Version"
        }
        // Remove only complete, known upload labels. A label containing a live,
        // remix, or other version qualifier must remain part of the identity.
        let labels = "(?:official (?:music )?video release|bonus track|(?:official )?(?:audio visualizer|visualizer|music video|lyric video|audio|video|lyrics))"
        result = result.replacingOccurrences(of: "(?i)\\(" + labels + "\\)|\\[" + labels + "\\]",
                                             with: "", options: .regularExpression)
        let quotedPattern = "(?i)^" + NSRegularExpression.escapedPattern(for: artist) + "\\s+[\"“](.+)[\"”]\\s*$"
        if let expression = try? NSRegularExpression(pattern: quotedPattern),
           let match = expression.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
           let song = Range(match.range(at: 1), in: result) {
            result = String(result[song])
        }
        for separator in [" - ", " — ", " – "] {
            if let range = result.range(of: separator) {
                let prefix = String(result[..<range.lowerBound])
                if normalized(prefix) == normalized(artist) || artistListContains(prefix, artist: artist) {
                    result = String(result[range.upperBound...]); break
                }
            }
        }
        // Uploads commonly put the artist after the title, especially for
        // multi-artist radio-style titles ("One Dance ... - Drake").
        for separator in [" - ", " — ", " – "] {
            let suffix = separator + artist
            if result.lowercased().hasSuffix(suffix.lowercased()) {
                result.removeLast(suffix.count)
                break
            }
        }
        for suffix in [" (Official Audio)", " [Official Audio]", " (Official Video)", " [Official Video]", " (Lyrics)", " [Lyrics]"] {
            if result.lowercased().hasSuffix(suffix.lowercased()) { result.removeLast(suffix.count) }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matchingTrack(_ tracks: [SpotifyCatalogTrack], artist: SpotifyArtist, title: String) -> SpotifyCatalogTrack? {
        tracks.first { track in
            guard track.artists.contains(where: { $0.id == artist.id || normalized($0.name) == normalized(artist.name) }) else { return false }
            // A favorite artist may be a guest: use the returned credits to
            // recognize "Main Artist - Song feat. Favorite Artist" uploads.
            // Spotify still credits FERG under his previous artist name.
            let aliases = track.artists.filter { $0.id == "5dHt1vcEm9qb8fCyLcB3HL" }.map { _ in "FERG" }
            return ([artist.name] + track.artists.map(\.name) + aliases).contains { credit in
                comparableTitle(track.name, artist: credit) == comparableTitle(title, artist: credit)
            }
        }
    }

    static func assessingCatalog(_ recording: DiscoveryRecording, tracks: [SpotifyCatalogTrack]) -> DiscoveryRecording {
        let match = matchingTrack(tracks, artist: recording.artist, title: recording.title)
        var availability: CatalogAvailability = match == nil ? .noMatch : .found
        var detail = match == nil ? "No exact artist/title/version match in Spotify’s search results. Availability varies by region." : nil
        if match == nil, let credited = tracks.first(where: { track in
            guard !track.artists.contains(where: { $0.id == recording.artist.id || normalized($0.name) == normalized(recording.artist.name) }),
                  let source = explicitPerformerTitle(recording.title, credits: track.artists) else { return false }
            return track.artists.contains { comparableTitle(source, artist: $0.name) == comparableTitle(track.name, artist: $0.name) }
        }) {
            availability = .unknown
            detail = "Spotify has “\(credited.name)” credited to \(credited.artists.map(\.name).joined(separator: ", ")). \(recording.artist.name) is not listed as a performer. Review the recording credits before approving."
        } else if match == nil, let version = tracks.first(where: { needsVersionReview(recording.title, artist: recording.artist, track: $0) }) {
            availability = .unknown
            detail = "Spotify has “\(version.name)” with this artist, but the upload does not fully identify that version. Review the source and Spotify version before approving."
        }
        if availability == .noMatch && !hasSourceArtistCredit(recording) {
            availability = .unknown
            detail = "The source does not clearly credit \(recording.artist.name). Review the upload’s performer credits before treating this as a discovery lead."
        }
        return DiscoveryRecording(artist: recording.artist, title: recording.title, candidate: recording.candidate,
            availability: availability, catalogURI: match?.uri, detail: detail)
    }

    private static func hasSourceArtistCredit(_ recording: DiscoveryRecording) -> Bool {
        let artist = recording.artist.name
        let target = normalized(artist)
        if let uploader = recording.candidate.uploader {
            let channel = normalized(uploader)
            if channel == target || channel == target + " topic" { return true }
            if uploader.lowercased().hasSuffix("vevo"),
               normalized(String(uploader.dropLast(4))).replacingOccurrences(of: " ", with: "") == target.replacingOccurrences(of: " ", with: "") { return true }
        }
        let raw = recording.candidate.title
        if raw.range(of: "(?i)^" + NSRegularExpression.escapedPattern(for: artist) + "\\s+[\"“].+[\"”](?:\\s|$)", options: .regularExpression) != nil { return true }
        if let separator = try? NSRegularExpression(pattern: "[-–—]\\s+") {
            for match in separator.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
                guard let range = Range(match.range, in: raw) else { continue }
                let prefix = String(raw[..<range.lowerBound]).replacingOccurrences(of: "+", with: ",")
                if artistListContains(prefix, artist: artist) { return true }
            }
        }
        for marker in featureMarkers {
            guard let range = raw.range(of: marker, options: .caseInsensitive) else { continue }
            var credit = String(raw[range.upperBound...])
            if let boundary = credit.range(of: "[()\\[\\]]|\\s[-–—]\\s", options: .regularExpression) { credit = String(credit[..<boundary.lowerBound]) }
            if artistListContains(credit.replacingOccurrences(of: "+", with: ","), artist: artist) { return true }
        }
        return false
    }

    private static let versionQualifiers = ["remix", "live", "acoustic", "instrumental", "edit", "version", "remaster", "extended", "sped", "slowed", "demo", "clean", "karaoke", "part", "pt"]

    private static func isVersionQualifier(_ word: String) -> Bool {
        versionQualifiers.contains(word) || word.range(of: "^(?:part|pt)[0-9]+$", options: .regularExpression) != nil
    }

    private static func versionTitle(_ raw: String, artist: String) -> (base: String, descriptor: [String])? {
        let cleaned = catalogTitle(raw, artist: artist)
        guard let decoration = cleaned.range(of: "(?:\\s+[-–—]\\s+[^()\\[\\]]+|\\s*\\([^()]+\\)|\\s*\\[[^\\[\\]]+\\])\\s*$", options: .regularExpression) else { return nil }
        let descriptor = normalized(String(cleaned[decoration])).split(separator: " ").map(String.init)
        guard descriptor.contains(where: { versionQualifiers.contains($0) }) else { return nil }
        return (comparableTitle(String(cleaned[..<decoration.lowerBound]), artist: artist), descriptor)
    }

    private static func needsVersionReview(_ source: String, artist: SpotifyArtist, track: SpotifyCatalogTrack) -> Bool {
        guard track.artists.contains(where: { $0.id == artist.id || normalized($0.name) == normalized(artist.name) }) else { return false }
        return ([artist.name] + track.artists.map(\.name)).contains { credit in
            guard let catalog = versionTitle(track.name, artist: credit) else { return false }
            if let requested = versionTitle(source, artist: credit) {
                return !requested.base.isEmpty && requested.base == catalog.base
                    && !requested.descriptor.contains("extended") && catalog.descriptor.contains("extended")
                    && catalog.descriptor.filter { $0 != "extended" } == requested.descriptor
            }
            let requested = comparableTitle(source, artist: credit)
            return !requested.isEmpty && requested == catalog.base
                && !requested.split(separator: " ").contains(where: { versionQualifiers.contains(String($0)) })
        }
    }

    private static func explicitPerformerTitle(_ raw: String, credits: [SpotifyArtistCredit]) -> String? {
        guard let separator = try? NSRegularExpression(pattern: "[-–—]\\s+") else { return nil }
        let names = Set(credits.map { normalized($0.name) })
        for match in separator.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            guard let range = Range(match.range, in: raw) else { continue }
            let prefix = String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let performers = prefix.replacingOccurrences(of: "(?i)\\s*(?:[+&,])\\s*|\\s+(?:and|x|ft\\.?|feat\\.?|featuring)\\s+", with: "|", options: .regularExpression)
                .components(separatedBy: "|").map { normalized($0) }
            if names.contains(normalized(prefix)) || (!performers.isEmpty && performers.allSatisfy { !$0.isEmpty && names.contains($0) }) {
                return String(raw[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    static func catalogTitle(_ raw: String, artist: String) -> String {
        var cleaned = title(raw, artist: artist)
        for (opening, closing) in [("(", ")"), ("[", "]")] {
            let pattern = NSRegularExpression.escapedPattern(for: opening)
                + "\\s*(?:prod\\.?\\s+(?:by\\s+)?|produced\\s+by\\s+)([^()\\[\\]]+)"
                + NSRegularExpression.escapedPattern(for: closing)
            guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            for match in expression.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)).reversed() {
                guard let range = Range(match.range, in: cleaned), let content = Range(match.range(at: 1), in: cleaned),
                      cleaned[content].range(of: "\\s[-–—]\\s", options: .regularExpression) == nil else { continue }
                let nesting = cleaned[..<range.lowerBound].reduce(0) { depth, character in
                    depth + ((character == "(" || character == "[") ? 1 : (character == ")" || character == "]") ? -1 : 0)
                }
                let words = normalized(String(cleaned[content])).split(separator: " ").map(String.init)
                guard nesting == 0, !words.contains(where: isVersionQualifier) else { continue }
                cleaned.removeSubrange(range)
            }
        }
        if let credit = cleaned.range(of: "(?i)\\s+prod\\s+by[;:]\\s+[^()\\[\\]]+$", options: .regularExpression),
           cleaned[credit].range(of: "\\s[-–—]\\s", options: .regularExpression) == nil {
            cleaned = String(cleaned[..<credit.lowerBound])
        }
        // Remove a featured/with-artist decoration, but retain a meaningful
        // parenthesized version that follows it ("feat. X (Live)").
        for marker in featureMarkers {
            if let range = cleaned.range(of: marker, options: .caseInsensitive) {
                let prefix = String(cleaned[..<range.lowerBound])
                let suffix = String(cleaned[range.upperBound...])
                if marker.hasPrefix("(") || marker.hasPrefix("[") {
                    let closing: Character = marker.hasPrefix("(") ? ")" : "]"
                    if let end = suffix.firstIndex(of: closing) {
                        let credit = String(suffix[..<end])
                        let tail = String(suffix[suffix.index(after: end)...])
                        if let separator = credit.range(of: "\\s[-–—]\\s", options: .regularExpression) {
                            cleaned = prefix + " " + credit[separator.upperBound...] + " " + tail
                        } else if !credit.contains("("), !credit.contains("["),
                            !normalized(credit).split(separator: " ").contains(where: { isVersionQualifier(String($0)) }) {
                            cleaned = prefix + " " + tail
                        }
                    }
                } else if let versionStart = suffix.firstIndex(where: { $0 == "(" || $0 == "[" }) {
                    cleaned = prefix + String(suffix[versionStart...])
                } else if let separator = suffix.range(of: "\\s[-–—]\\s", options: .regularExpression) {
                    cleaned = prefix + " " + suffix[separator.upperBound...]
                } else {
                    let words = normalized(suffix).split(separator: " ")
                    if !words.contains(where: { isVersionQualifier(String($0)) }) { cleaned = prefix }
                }
                break
            }
        }
        cleaned = cleaned.replacingOccurrences(of: "(?i)\\s+[-–—]\\s+bonus track\\s*$", with: "", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func comparableTitle(_ raw: String, artist: String) -> String {
        var value = normalized(catalogTitle(raw, artist: artist))
        // "Audio" and its official/lyrics decorations identify the upload,
        // not a distinct recording. Strip only trailing neutral decorations;
        // remix/live/version tokens remain part of the identity.
        for suffix in [" official music video", " official lyric video", " official audio", " official video", " lyric video", " audio", " video", " lyrics"] {
            if value.hasSuffix(suffix) { value.removeLast(suffix.count) }
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func artistListContains(_ prefix: String, artist: String) -> Bool {
        let target = normalized(artist)
        guard !target.isEmpty else { return false }
        let feature = prefix.range(of: "(?i)\\s+(?:ft\\.?|feat\\.?|featuring)\\s+", options: .regularExpression)
        let performers = feature.map { String(prefix[..<$0.lowerBound]) } ?? prefix
        let list = performers.replacingOccurrences(of: "(?i)\\s+(?:&|and|x)\\s+", with: ",", options: .regularExpression)
            .components(separatedBy: ",")
        return list.contains { normalized($0.trimmingCharacters(in: .whitespacesAndNewlines)) == target }
    }

    static func isInLibrary(candidate: Candidate, artist: String, title: String, tracks: [TrackRequest]) -> Bool {
        tracks.contains { track in
            guard let path = track.savedPath, FileManager.default.fileExists(atPath: path) else { return false }
            return track.sourceURL == candidate.url || (normalized(track.artist) == normalized(artist) && normalized(track.title) == normalized(title))
        }
    }
}
