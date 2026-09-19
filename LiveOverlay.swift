import AppKit
import SwiftUI

/// A non-activating, bottom-centred heads-up display. It stays above the focused app
/// without stealing keyboard focus while push-to-talk is held.
final class LiveOverlayController {
    private var panel: NSPanel?

    func show(appState: AppState) {
        let panel: NSPanel
        if let existing = self.panel { panel = existing }
        else {
            panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 720, height: 64), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isMovableByWindowBackground = false
            panel.hidesOnDeactivate = false
            self.panel = panel
        }
        panel.contentView = NSHostingView(rootView: LiveOverlayView().environmentObject(appState))
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(.init(x: visible.midX - panel.frame.width / 2, y: visible.minY + 26))
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

private struct LiveOverlayView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HStack(spacing: 13) {
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { index in
                    Circle().fill(app.isRecording ? Color.white : Color.white.opacity(0.5)).frame(width: app.isRecording ? CGFloat(5 + (index % 2) * 3) : 5, height: app.isRecording ? CGFloat(5 + (index % 2) * 3) : 5)
                }
            }.frame(width: 46)
            Text(app.liveTranscript.isEmpty ? "Listening…" : app.liveTranscript)
                .font(.system(size: 17, weight: .semibold)).lineLimit(1).truncationMode(.tail)
            Spacer()
            Text(app.usesSarvamForCurrentMode && app.useLivePreview ? "LIVE" : "RECORDING")
                .font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.72))
        }
        .padding(.horizontal, 22).frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [Color(red: 0.16, green: 0.18, blue: 0.21).opacity(0.96), Color(red: 0.37, green: 0.12, blue: 0.03).opacity(0.96)], startPoint: .leading, endPoint: .trailing), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.20), lineWidth: 1))
    }
}
