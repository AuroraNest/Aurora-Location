import SwiftUI

@main
struct AuroraLocationApp: App {
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .onOpenURL { state.handleURL($0) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active, !state.isBusy { state.refresh() }
                    if phase == .background { state.enteredBackground() }
                }
        }
    }
}
