import ApplicationServices
import Foundation

/// A bounded Accessibility composition session. It never sends destructive backspaces:
/// only the exact range inserted by this session is selected and replaced.
final class LiveTextComposition {
    private let element: AXUIElement
    private let insertionStart: Int
    private var composedUTF16Length = 0

    private init(element: AXUIElement, insertionStart: Int) {
        self.element = element
        self.insertionStart = insertionStart
    }

    static func begin() -> LiveTextComposition? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        var selectedRangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue) == .success,
              let selectedRangeValue, CFGetTypeID(selectedRangeValue) == AXValueGetTypeID() else { return nil }
        var selected = CFRange()
        guard AXValueGetValue(selectedRangeValue as! AXValue, .cfRange, &selected) else { return nil }
        return LiveTextComposition(element: element as! AXUIElement, insertionStart: selected.location)
    }

    /// Replace only the live range. The field's existing text remains outside this range.
    func replace(with text: String) -> Bool {
        let range = CFRange(location: insertionStart, length: composedUTF16Length)
        guard setSelectedRange(range) else { return false }
        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        guard result == .success else { return false }
        composedUTF16Length = text.utf16.count
        return true
    }

    private func setSelectedRange(_ range: CFRange) -> Bool {
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }
}
