import AppKit

struct Hotkey: Equatable, Hashable, Identifiable {
    static let defaultShortcut = Hotkey(keyCode: 29, modifiers: [.control]) // Control–0 (ANSI keyboard layout)
    static let known = [
        defaultShortcut,
        Hotkey(keyCode: 29, modifiers: [.control, .option]),
        Hotkey(keyCode: 49, modifiers: [.control, .option])
    ]
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    var identifier: String { "\(keyCode):\(modifiers.rawValue)" }
    var id: String { identifier }
    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }
    var displayName: String {
        let pieces: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let keyName = keyCode == 29 ? "0" : "Space"
        return pieces.filter { modifiers.contains($0.0) }.map { $0.1 }.joined() + " " + keyName
    }
}

/// Passive global monitor: it never steals keystrokes from the focused app.
final class HotkeyMonitor {
    private let shortcut: Hotkey
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var downMonitor: Any?
    private var upMonitor: Any?
    private var isHeld = false
    private var localMonitor: Any?
    private var flagsMonitor: Any?
    private var releaseTimer: Timer?

    init(shortcut: Hotkey, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.shortcut = shortcut; self.onPress = onPress; self.onRelease = onRelease
    }
    func start() {
        stop()
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] in self?.handleDown($0) }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] in self?.handleUp($0) }
        // Global monitors never receive events delivered to our own application.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            if event.type == .keyDown { self?.handleDown(event) }
            else if event.type == .keyUp { self?.handleUp(event) }
            else { self?.handleFlags(event) }
            return event
        }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] in self?.handleFlags($0) }
        // Recover a missed release across app/Space switches without trapping the
        // monitor in isHeld forever. Consult physical state, not synthetic events.
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self, self.isHeld else { return }
            if !CGEventSource.keyState(.combinedSessionState, key: self.shortcut.keyCode) { self.release() }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseTimer = timer
    }
    func stop() {
        if let downMonitor { NSEvent.removeMonitor(downMonitor) }
        if let upMonitor { NSEvent.removeMonitor(upMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        releaseTimer?.invalidate(); releaseTimer = nil
        localMonitor = nil; flagsMonitor = nil
        downMonitor = nil; upMonitor = nil; isHeld = false
    }
    deinit { stop() }
    private func matches(_ event: NSEvent) -> Bool {
        event.keyCode == shortcut.keyCode && event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(shortcut.modifiers)
    }
    func handleDown(_ event: NSEvent) { guard !event.isARepeat, matches(event), !isHeld else { return }; isHeld = true; onPress() }
    func handleUp(_ event: NSEvent) { guard event.keyCode == shortcut.keyCode else { return }; release() }
    func handleFlags(_ event: NSEvent) {
        if !event.modifierFlags.contains(shortcut.modifiers) { release() }
    }
    private func release() { guard isHeld else { return }; isHeld = false; onRelease() }
}
