import SwiftUI

@main
struct AudioVisualizerApp: App {
    @State private var engine = VisualizerEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}
