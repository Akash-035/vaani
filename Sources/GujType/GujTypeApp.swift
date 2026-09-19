import SwiftUI

@main
struct VaaniApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.isRecording ? "waveform.circle.fill" : "keyboard")
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Vaani", id: "settings") {
            SettingsView()
                .environmentObject(appState)
        }
        .defaultSize(width: 1120, height: 760)
    }
}
