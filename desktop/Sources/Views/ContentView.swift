import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let model: AppModel
    @State private var showingGuide = false
    @State private var isDropTargeted = false
    @State private var dropFeedback: String?
    @State private var dropFeedbackGeneration = UUID()

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model).navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            Group {
                switch model.destination {
                case .addMusic: AddMusicView(model: model)
                case .reviewQueue: ReviewQueueView(model: model)
                case .discover: DiscoveryView(model: model)
                case .activity: ActivityView(model: model)
                case .library: LibraryView(model: model)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingGuide = true
                    } label: {
                        Label("How to use \(model.destination.rawValue)", systemImage: "questionmark.circle")
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("How to use \(model.destination.rawValue)")
                    .help("How to use \(model.destination.rawValue)")
                }
                ToolbarItem(placement: .primaryAction) {
                    SettingsLink { Label("Settings", systemImage: "gear") }
                }
            }
        }
        .sheet(isPresented: $showingGuide) {
            TabGuideView(destination: model.destination)
        }
        .alert("Needle", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 7]))
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "link.badge.plus")
                                .font(.system(size: 28, weight: .semibold))
                            Text("Drop source links to add them to Review Queue")
                                .font(.headline)
                            Text("Needle accepts SoundCloud, YouTube, and other http(s) links")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(28)
                    }
                    .padding(16)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: SourceURLDropImporter.supportedContentTypes, isTargeted: $isDropTargeted) { providers in
            SourceURLDropImporter.start(providers: providers) { result in
                guard !result.accepted.isEmpty else {
                    model.message = "Drop one or more http(s) source links. Local files and other link types are not supported."
                    return
                }
                let existingIDs = Set(model.reviewQueue.items.map(\.id))
                model.reviewQueue.add(result.accepted.joined(separator: "\n"), settings: model.settings.value,
                                      automaticallySearchLinks: true)
                if let firstNewItem = model.reviewQueue.items.first(where: { !existingIDs.contains($0.id) }) {
                    model.reviewQueue.selectedID = firstNewItem.id
                }
                model.destination = .reviewQueue
                var details = ["Added \(result.accepted.count) link\(result.accepted.count == 1 ? "" : "s") to Review Queue"]
                if result.duplicateCount > 0 { details.append("\(result.duplicateCount) duplicate\(result.duplicateCount == 1 ? "" : "s") skipped") }
                if result.invalidCount > 0 { details.append("\(result.invalidCount) unsupported item\(result.invalidCount == 1 ? "" : "s") skipped") }
                if result.truncatedCount > 0 || result.ignoredProviderCount > 0 || result.oversizedProviderCount > 0 {
                    details.append("some drops were over Needle’s intake limit")
                }
                let feedbackGeneration = UUID()
                dropFeedbackGeneration = feedbackGeneration
                dropFeedback = details.joined(separator: " · ")
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    if dropFeedbackGeneration == feedbackGeneration { dropFeedback = nil }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Image(systemName: "link")
                Text(dropFeedback ?? "Drop links anywhere to add them to Review Queue")
            }
            .font(.caption)
            .foregroundStyle(dropFeedback == nil ? .secondary : Color.accentColor)
            .padding(.vertical, 5)
        }
        .task { if model.tools == nil { model.checkTools() } }
    }
}

struct SidebarView: View {
    let model: AppModel
    var body: some View {
        List(selection: Binding(get: { model.destination }, set: { if let value = $0 { model.destination = value } })) {
            Section("Needle") {
                ForEach(Destination.allCases) { destination in
                    Label(destination.rawValue, systemImage: destination.symbol).tag(destination)
                }
            }
        }.listStyle(.sidebar)
    }
}
