import SwiftUI

struct ContentView: View {
    let model: AppModel
    @State private var showingGuide = false
    var body: some View {
        NavigationSplitView {
            SidebarView(model: model).navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            Group {
                switch model.destination {
                case .addMusic: AddMusicView(model: model)
                case .reviewQueue: ReviewQueueView(model: model)
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
