import SwiftUI

struct ContentView: View {
    let model: AppModel
    var body: some View {
        NavigationSplitView {
            SidebarView(model: model).navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            Group {
                switch model.destination {
                case .addMusic: AddMusicView(model: model)
                case .activity: ActivityView(model: model)
                case .library: LibraryView(model: model)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    SettingsLink { Label("Settings", systemImage: "gear") }
                }
            }
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
