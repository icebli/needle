import Foundation

struct AddMusicRequest: Equatable {
    let artist: String
    let title: String
    let sourceURL: String

    init(artist: String, title: String, sourceURL: String) {
        self.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceURL = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var needsIdentification: Bool { artist.isEmpty || title.isEmpty }

    var canSearch: Bool {
        if sourceURL.isEmpty { return !needsIdentification }
        guard let components = URLComponents(string: sourceURL),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return false }
        return true
    }

    func identifying(artist: String?, title: String?) -> AddMusicRequest {
        AddMusicRequest(artist: self.artist.isEmpty ? artist ?? "" : self.artist,
                        title: self.title.isEmpty ? title ?? "" : self.title,
                        sourceURL: sourceURL)
    }
}
