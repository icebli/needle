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
    var id: String { candidate.provider + ":" + candidate.id }
    let artist: SpotifyArtist
    let title: String
    let candidate: Candidate
    let availability: CatalogAvailability
    var catalogURI: String?
    var detail: String?
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
        let result = try await request(["catalog", artist, title])
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
    static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
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
        let labels = "(?:official )?(?:audio visualizer|visualizer|music video|lyric video|audio|video|lyrics)"
        result = result.replacingOccurrences(of: "(?i)\\(" + labels + "\\)|\\[" + labels + "\\]",
                                             with: "", options: .regularExpression)
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

    private static func comparableTitle(_ raw: String, artist: String) -> String {
        var cleaned = title(raw, artist: artist)
        let versionWords = ["remix", "live", "acoustic", "instrumental", "edit", "version", "remaster", "extended", "sped", "slowed"]
        // Remove a featured/with-artist decoration, but retain a meaningful
        // parenthesized version that follows it ("feat. X (Live)").
        for marker in [" ft. ", " ft ", " feat. ", " feat ", " featuring ", "(ft. ", "(feat. ", "(featuring ", "[ft. ", "[feat. ", "[featuring ", "(with ", "[with "] {
            if let range = cleaned.range(of: marker, options: .caseInsensitive) {
                let prefix = String(cleaned[..<range.lowerBound])
                let suffix = String(cleaned[range.upperBound...])
                if marker.hasPrefix("(") || marker.hasPrefix("[") {
                    let closing: Character = marker.hasPrefix("(") ? ")" : "]"
                    if let end = suffix.firstIndex(of: closing) {
                        let credit = String(suffix[..<end])
                        let tail = String(suffix[suffix.index(after: end)...])
                        if normalized(credit).split(separator: " ").contains(where: { versionWords.contains(String($0)) }) {
                            // A version can be inside the credit's brackets.
                            // Keep ambiguous/nested content rather than matching studio audio.
                            if let separator = credit.range(of: "\\s[-–—]\\s", options: .regularExpression) {
                                cleaned = prefix + " " + credit[separator.upperBound...] + " " + tail
                            }
                        } else {
                            cleaned = prefix + " " + tail
                        }
                    }
                } else if let versionStart = suffix.firstIndex(where: { $0 == "(" || $0 == "[" }) {
                    cleaned = prefix + String(suffix[versionStart...])
                } else {
                    let words = normalized(suffix).split(separator: " ")
                    if let versionIndex = words.firstIndex(where: { versionWords.contains(String($0)) }) {
                        // Keep the remixer's name before "Remix", when separated
                        // from the artist credit ("feat. X - DJ Y Remix").
                        let versionTail = suffix.range(of: "\\s[-–—]\\s", options: .regularExpression)
                        cleaned = prefix + " " + (versionTail.map { String(suffix[$0.upperBound...]) }
                            ?? words[versionIndex...].joined(separator: " "))
                    } else {
                        cleaned = prefix
                    }
                }
                break
            }
        }
        var value = normalized(cleaned)
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
        let list = prefix.replacingOccurrences(of: " & ", with: ",")
            .replacingOccurrences(of: " and ", with: ",")
            .replacingOccurrences(of: " x ", with: ",")
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
