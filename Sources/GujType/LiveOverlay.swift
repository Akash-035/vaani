import AppKit
import SwiftUI

/// Non-activating dictation surface that grows upward, leaving the focused field visible.
final class LiveOverlayController {
    private var panel: NSPanel?
    private weak var screen: NSScreen?
    private let compactHeight: CGFloat = 104
    private let expandedHeight: CGFloat = 336
    private let width: CGFloat = 760

    func show(appState: AppState) {
        let panel: NSPanel
        if let existing = self.panel { panel = existing }
        else {
            panel = NSPanel(contentRect: .init(x: 0, y: 0, width: width, height: compactHeight), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            self.panel = panel
        }
        screen = NSScreen.main ?? NSScreen.screens.first
        panel.contentView = NSHostingView(rootView: LiveOverlayView { [weak self] expanded in
            self?.resize(expanded: expanded)
        }.environmentObject(appState))
        resize(expanded: false)
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func resize(expanded: Bool) {
        guard let panel, let screen else { return }
        let height = expanded ? expandedHeight : compactHeight
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.midX - width / 2, y: visible.minY + 24, width: width, height: height)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }
}

private struct LiveOverlayView: View {
    @EnvironmentObject private var app: AppState
    let setExpanded: (Bool) -> Void
    @State private var expanded = false
    @State private var ringProgress: CGFloat = 0
    @State private var cursorVisible = false
    @State private var transcriptVersion = 0
    @State private var displayedTranscript = ""

    private var isLiveText: Bool { !app.liveTranscript.isEmpty }
    private var isListening: Bool { app.isRecording && !isLiveText }
    private var title: String {
        if app.isProcessing { return "Transcribing" }
        if isListening { return "Listening" }
        return "Live dictation"
    }
    private var transcript: String {
        if isLiveText { return app.liveTranscript }
        if app.isProcessing { return "Your recording is being transcribed. This will only take a moment." }
        return "Speak naturally. Your words will appear here as they are recognised."
    }
    private var canExpand: Bool { isLiveText || app.isProcessing }

    var body: some View {
        VStack(spacing: 0) {
            if expanded {
                transcriptArea
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)), removal: .opacity))
            }
            commandBar
        }
        .frame(width: 760, height: expanded ? 336 : 104, alignment: .bottom)
        .background(Color(red: 0.965, green: 0.958, blue: 0.94), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay { animatedRing }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.20), radius: 26, y: 12)
        .onAppear {
            displayedTranscript = transcript
            withAnimation(.easeOut(duration: 0.72)) { ringProgress = 1 }
            withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) { cursorVisible = true }
        }
        .onChange(of: app.liveTranscript) { next in
            guard !next.isEmpty else { return }
            displayedTranscript = next
            transcriptVersion &+= 1
        }
        .onChange(of: app.isProcessing) { _ in
            if !app.isProcessing && !isLiveText { setPanelExpanded(false) }
        }
    }

    private var commandBar: some View {
        HStack(spacing: 14) {
            DictationOrb(isListening: isListening, isProcessing: app.isProcessing, isLive: isLiveText)
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.25)
                    .foregroundStyle(Color.blue.opacity(0.88))
                Text(compactTranscript)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.10, green: 0.14, blue: 0.20))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(transcriptVersion)
                    .transition(.opacity.combined(with: .blurReplace))
            }
            Spacer(minLength: 8)
            if canExpand {
                Button { setPanelExpanded(!expanded) } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(Color.blue.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.blue)
                .help(expanded ? "Collapse transcript" : "Show full transcript")
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 104)
        .contentShape(Rectangle())
        .onTapGesture { if canExpand { setPanelExpanded(!expanded) } }
    }

    private var compactTranscript: String {
        if isLiveText { return displayedTranscript }
        if app.isProcessing { return "Finalising the words you just spoke…" }
        return "Speak naturally · release your shortcut when you’re done"
    }

    private var transcriptArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(app.isProcessing ? "Completed recording" : "Live transcript", systemImage: app.isProcessing ? "text.badge.checkmark" : "text.cursor")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.20, green: 0.28, blue: 0.42))
                Spacer()
                Text(app.isProcessing ? "PROCESSING" : "UPDATING")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(Color.blue.opacity(0.72))
            }
            ScrollView {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(transcript)
                        .font(.system(size: 19, weight: .regular, design: .rounded))
                        .foregroundStyle(Color(red: 0.08, green: 0.12, blue: 0.18))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .id(transcriptVersion)
                        .transition(.opacity.combined(with: .blurReplace))
                    if app.isRecording && isLiveText {
                        Capsule()
                            .fill(Color.blue)
                            .frame(width: 2, height: 21)
                            .opacity(cursorVisible ? 1 : 0.18)
                            .animation(.easeInOut(duration: 0.72), value: cursorVisible)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.automatic)
        }
        .padding(.horizontal, 25)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.42))
        .overlay(alignment: .bottom) { Divider().overlay(Color.blue.opacity(0.12)) }
    }

    private var animatedRing: some View {
        ZStack {
            let ring = RoundedRectangle(cornerRadius: 26, style: .continuous)
            ring.stroke(Color.blue.opacity(0.12), lineWidth: 1)
            // Two arcs start at the lower-middle point and travel in opposite
            // directions, making the border feel like it opens around the voice.
            ring
                .trim(from: max(0.001, 0.5 - 0.5 * ringProgress), to: 0.5)
                .stroke(LinearGradient(colors: [.clear, Color.blue.opacity(0.94)], startPoint: .leading, endPoint: .trailing), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            ring
                .trim(from: 0.5, to: min(0.999, 0.5 + 0.5 * ringProgress))
                .stroke(LinearGradient(colors: [Color.blue.opacity(0.94), .clear], startPoint: .leading, endPoint: .trailing), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
        .allowsHitTesting(false)
    }

    private func setPanelExpanded(_ value: Bool) {
        guard expanded != value else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { expanded = value }
        setExpanded(value)
    }
}

private struct DictationOrb: View {
    let isListening: Bool
    let isProcessing: Bool
    let isLive: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.blue.opacity(pulse && !isProcessing ? 0.14 : 0.06))
                .frame(width: 50, height: 50)
                .scaleEffect(pulse && !isProcessing ? 1.10 : 0.86)
            Circle()
                .fill(LinearGradient(colors: [Color(red: 0.12, green: 0.49, blue: 0.95), Color(red: 0.35, green: 0.72, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 38, height: 38)
            Image(systemName: isProcessing ? "ellipsis" : (isListening ? "mic.fill" : "waveform"))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

private extension AnyTransition {
    static var blurReplace: AnyTransition {
        .modifier(active: SoftBlur(opacity: 0, radius: 5), identity: SoftBlur(opacity: 1, radius: 0))
    }
}

private struct SoftBlur: ViewModifier {
    let opacity: Double
    let radius: CGFloat
    func body(content: Content) -> some View { content.opacity(opacity).blur(radius: radius) }
}
