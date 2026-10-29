import SwiftUI

struct BookmarksView: View {
    let model: AppModel
    @State private var query = BookmarkQuery()
    @FocusState private var searchFocused: Bool
    @State private var layout: BookmarkLayout = .gallery

    private var providers: [String] {
        Set(model.bookmarks.items.map(\.candidate.provider)).sorted()
    }

    var body: some View {
        let visible = query.apply(to: model.bookmarks.items)
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Bookmarks").font(.largeTitle.bold())
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { searchField; collectionOptions }
                VStack(alignment: .leading, spacing: 12) { searchField; collectionOptions }
            }
            HStack(alignment: .center) {
                Text("\(visible.count) of \(model.bookmarks.items.count) bookmarks")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("bookmarkResultCount")
                Spacer()
                Picker("View", selection: $layout) {
                    Label("Gallery", systemImage: "square.grid.2x2").tag(BookmarkLayout.gallery)
                    Label("List", systemImage: "list.bullet").tag(BookmarkLayout.list)
                }
                .pickerStyle(.segmented)
                .frame(width: 92)
                .labelsHidden()
                .help("Choose gallery or list view")
            }

            if model.bookmarks.items.isEmpty {
                ContentUnavailableView {
                    Label("No bookmarks yet", systemImage: "bookmark")
                } description: {
                    Text("Bookmark a promising source from Discover or a song search. Come back here when you are ready to listen and review.")
                } actions: {
                    Button("Discover recordings") { model.destination = .discover }
                }
            } else if visible.isEmpty {
                ContentUnavailableView {
                    Label("No matching bookmarks", systemImage: "magnifyingglass")
                } description: {
                    Text(query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "No saved recordings match the selected source."
                         : "No saved recordings match “\(query.text)” with the current source filter.")
                } actions: {
                    Button("Clear search and filters") {
                        query.text = ""
                        query.provider = nil
                    }
                }
            } else if layout == .gallery {
                ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 18)], spacing: 18) {
                    ForEach(visible) { bookmark in
                        BookmarkGalleryCard(bookmark: bookmark) {
                            model.reviewQueue.addBookmark(bookmark, settings: model.settings.value)
                            model.destination = .reviewQueue
                        } remove: {
                            model.bookmarks.remove(bookmark)
                        }
                    }
                }
                }
            } else {
                List(visible) { bookmark in
                    BookmarkRow(bookmark: bookmark) {
                        model.reviewQueue.addBookmark(bookmark, settings: model.settings.value)
                        model.destination = .reviewQueue
                    } remove: {
                        model.bookmarks.remove(bookmark)
                    }
                }.listStyle(.inset)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusedSceneValue(\.bookmarkSearch, { searchFocused = true })
        .onChange(of: providers) { _, available in
            if let provider = query.provider, !available.contains(provider) { query.provider = nil }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search bookmarks", text: $query.text)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Search bookmarks")
                .help("Search artist, song, album, uploader, or source. Press Command-F to focus.")
            if !query.text.isEmpty {
                Button { query.text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Clear bookmark search")
            }
        }
        .padding(8)
        .frame(minWidth: 220)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var collectionOptions: some View {
        HStack(spacing: 12) {
            Picker("Source", selection: $query.provider) {
                Text("All sources").tag(String?.none)
                ForEach(providers, id: \.self) { provider in
                    Text(provider.capitalized).tag(Optional(provider))
                }
            }
            .accessibilityLabel("Filter bookmarks by source")
            Picker("Sort", selection: $query.sort) {
                ForEach(BookmarkSort.allCases) { sort in Text(sort.rawValue).tag(sort) }
            }
            .accessibilityLabel("Sort bookmarks")
        }.fixedSize()
    }
}

private enum BookmarkLayout: String, CaseIterable {
    case gallery
    case list
}

struct BookmarkGalleryCard: View {
    let bookmark: ReleaseBookmark
    let review: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BookmarkArtwork(bookmark: bookmark)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(bookmark.title).font(.headline).lineLimit(2)
                Text(bookmark.artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Text(bookmark.candidate.provider.capitalized + (bookmark.candidate.uploader.map { " · \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 10) {
                Button("Review", action: review).buttonStyle(.borderedProminent).tint(.orange)
                Spacer()
                Menu {
                    Button("Remove bookmark", role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Actions for \(bookmark.title) by \(bookmark.artist)")
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if let warning = bookmark.score?.rejects.first ?? bookmark.score?.warnings.first {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(7)
                    .background(.thinMaterial, in: Capsule())
                    .padding(10)
                    .help(warning)
            }
        }
    }
}

private struct BookmarkArtwork: View {
    let bookmark: ReleaseBookmark

    var body: some View {
        Group {
            if let artwork = bookmark.artwork {
                AlbumArtworkView(artwork: artwork) { sourceArtwork }
            } else {
                sourceArtwork
            }
        }
    }

    private var sourceArtwork: some View {
        AsyncImage(url: bookmark.candidate.thumbnailURL.flatMap(AppModel.mediaURL)) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            case .empty:
                fallback.overlay {
                    if bookmark.candidate.thumbnailURL != nil { ProgressView().controlSize(.small) }
                }
            case .failure: fallback
            @unknown default: fallback
            }
        }
        .accessibilityLabel("Source artwork for \(bookmark.title) by \(bookmark.artist)")
        .help("Artwork from the source upload. It does not verify the recording.")
    }

    private var fallback: some View {
        ZStack {
            Rectangle().fill(.orange.opacity(0.18))
            Circle().fill(.white.opacity(0.16)).frame(width: 130).offset(x: 55, y: -38)
            VStack(alignment: .leading, spacing: 3) {
                Image(systemName: "music.note").font(.title2)
                Text(bookmark.title).font(.system(.title3, design: .serif).weight(.semibold)).lineLimit(2)
                Text(bookmark.artist.uppercased()).font(.caption2.weight(.semibold)).tracking(1.2).lineLimit(1)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(16)
        }
    }
}

private struct BookmarkRow: View {
    let bookmark: ReleaseBookmark
    let review: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BookmarkArtwork(bookmark: bookmark)
            .frame(width: 56, height: 56)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(bookmark.title).font(.headline).lineLimit(2)
                Text(bookmark.artist).font(.callout).lineLimit(1)
                if !bookmark.album.isEmpty {
                    Text(bookmark.album).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(bookmark.candidate.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { sourceFacts }
                    VStack(alignment: .leading, spacing: 4) { sourceFacts }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let warning = bookmark.score?.rejects.first ?? bookmark.score?.warnings.first {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).lineLimit(2).help(warning)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("Review", action: review)
                .buttonStyle(.bordered)
                .accessibilityLabel("Review \(bookmark.title) by \(bookmark.artist)")
            Menu {
                Button("Remove bookmark", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Actions for \(bookmark.title) by \(bookmark.artist)")
        }.padding(.vertical, 8)
    }

    @ViewBuilder private var sourceFacts: some View {
        Text(bookmark.candidate.provider.capitalized)
        if let uploader = bookmark.candidate.uploader, !uploader.isEmpty {
            Text(uploader).lineLimit(1)
        }
        if let ms = bookmark.candidate.durationMs, ms > 0 {
            Label(String(format: "%d:%02d", ms / 60_000, ms / 1_000 % 60), systemImage: "clock")
        }
        Text(bookmark.date, format: .dateTime.month(.abbreviated).day().year())
            .help("Date bookmarked")
    }
}
