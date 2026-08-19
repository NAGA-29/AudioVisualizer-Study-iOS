import SwiftUI

struct ContentView: View {
    @Environment(VisualizerEngine.self) private var engine
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch engine.status {
            case .permissionDenied:
                PermissionDeniedView()
            default:
                VisualizerScreen()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: engine.status)
        .onChange(of: scenePhase) { _, phase in
            // バックグラウンドではキャプチャを止める (バックグラウンド録音は本アプリのスコープ外)。
            engine.handleScenePhaseChange(isActive: phase == .active)
        }
    }
}

#Preview {
    ContentView()
        .environment(VisualizerEngine())
}
