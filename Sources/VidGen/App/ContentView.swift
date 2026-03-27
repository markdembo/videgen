import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: Tab = .library

    enum Tab { case library, music, export }

    var body: some View {
        TabView(selection: $selectedTab) {
            MediaSelectionView()
                .tabItem { Label("Library", systemImage: "photo.stack") }
                .tag(Tab.library)

            MusicView()
                .tabItem { Label("Music", systemImage: "music.note") }
                .tag(Tab.music)

            ExportView()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
                .tag(Tab.export)
        }
        .tint(.white)
        .alert("Error", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.clearError() } }
        )) {
            Button("OK") { appState.clearError() }
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }
}
