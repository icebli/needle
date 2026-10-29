import Foundation

enum BookmarkSort: String, CaseIterable, Identifiable {
    case newest = "Newest first"
    case oldest = "Oldest first"
    case artist = "Artist"
    case title = "Title"

    var id: Self { self }
}

struct BookmarkQuery {
    var text = ""
    var provider: String?
    var sort: BookmarkSort = .newest

    func apply(to bookmarks: [ReleaseBookmark]) -> [ReleaseBookmark] {
        let terms = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return bookmarks.filter { bookmark in
            guard provider == nil || bookmark.candidate.provider == provider else { return false }
            let fields = [bookmark.artist, bookmark.title, bookmark.album, bookmark.candidate.title,
                          bookmark.candidate.uploader ?? "", bookmark.candidate.provider]
            return terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(term) } }
        }.sorted { left, right in
            switch sort {
            case .newest, .oldest:
                if left.date != right.date {
                    return sort == .newest ? left.date > right.date : left.date < right.date
                }
            case .artist, .title:
                let leftFields = sort == .artist ? [left.artist, left.title] : [left.title, left.artist]
                let rightFields = sort == .artist ? [right.artist, right.title] : [right.title, right.artist]
                for (leftField, rightField) in zip(leftFields, rightFields) {
                    let order = leftField.localizedStandardCompare(rightField)
                    if order != .orderedSame { return order == .orderedAscending }
                }
            }
            return left.id < right.id
        }
    }
}
