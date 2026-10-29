import SwiftUI

struct ListeningRoomWelcome: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !model.bookmarks.items.isEmpty {
                HStack {
                    Text("Recently bookmarked").font(.headline)
                    Spacer()
                    Button("View all") { model.destination = .bookmarks }
                        .buttonStyle(.borderless)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 18)], spacing: 18) {
                    ForEach(Array(model.bookmarks.items.prefix(3))) { bookmark in
                        BookmarkGalleryCard(bookmark: bookmark) {
                            model.reviewQueue.addBookmark(bookmark, settings: model.settings.value)
                            model.destination = .reviewQueue
                        } remove: {
                            model.bookmarks.remove(bookmark)
                        }
                    }
                }
            }
            HStack(spacing: 18) {
                Button("Discover", systemImage: "sparkles") { model.destination = .discover }
                Button("Bookmarks", systemImage: "bookmark") { model.destination = .bookmarks }
                Spacer()
            }
            .buttonStyle(.borderless)
            SetupView(model: model)
        }
    }
}
