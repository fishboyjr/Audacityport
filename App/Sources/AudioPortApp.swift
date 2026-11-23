import AudioCore
import SwiftUI

@main
struct AudioPortApp: App {
    @State private var model = EditorModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            EditorView(model: model)
                .onOpenURL { url in model.open(url) }
                .onChange(of: scenePhase) { _, phase in
                    // Crash/termination safety, like the desktop autosave journal.
                    if phase == .background { model.autosave() }
                }
                .task { model.restoreAutosaveIfNeeded() }
        }
    }
}
