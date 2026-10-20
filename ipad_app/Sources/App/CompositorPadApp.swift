import SwiftUI

@main
struct CompositorPadApp: App {
    @StateObject private var model = EditorModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            EditorView(model: model)
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.43, green: 0.85, blue: 0.75))
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.restartRecovery() }
                    else { model.suspend() }
                }
        }
    }
}
