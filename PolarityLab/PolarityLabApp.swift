import SwiftUI

@main
struct PolarityLabApp: App {
    init() {
        print("🚀 PolarityLabApp launched")
    }

    var body: some Scene {
        WindowGroup {
            MainView()    // ← must be MainView, not ContentView
        }
    }
}
