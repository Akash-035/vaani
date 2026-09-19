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

    init(shortcut: Hotkey, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.shortcut = shortcut; self.onPress = onPress; self.onRelease = onRelease
    }
    func start() {
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] in self?.handleDown($0) }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] in self?.handleUp($0) }
    }
    func stop() {
        if let downMonitor { NSEvent.removeMonitor(downMonitor) }
        if let upMonitor { NSEvent.removeMonitor(upMonitor) }
        downMonitor = nil; upMonitor = nil; isHeld = false
    }
    deinit { stop() }
    private func matches(_ event: NSEvent) -> Bool {
        event.keyCode == shortcut.keyCode && event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(shortcut.modifiers)
    }
    private func handleDown(_ event: NSEvent) { guard matches(event), !isHeld else { return }; isHeld = true; onPress() }
    private func handleUp(_ event: NSEvent) { guard isHeld, event.keyCode == shortcut.keyCode else { return }; isHeld = false; onRelease() }
}
