import SwiftUI

@main
struct VibeStudioApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("VibeStudio")
                .font(.largeTitle.bold())
            Text("Scaffold OK — Phase 1 recorder lands next.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
    }
}
