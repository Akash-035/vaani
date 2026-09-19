import ApplicationServices
import Foundation

/// An Accessibility composition session bounded to the text inserted by GujType.
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
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let focused = focusedValue as! AXUIElement
        var selectedRangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue) == .success,
              let selectedRangeValue, CFGetTypeID(selectedRangeValue) == AXValueGetTypeID() else { return nil }
        let selectedAXValue = selectedRangeValue as! AXValue
        var selectedRange = CFRange()
        guard AXValueGetValue(selectedAXValue, .cfRange, &selectedRange) else { return nil }
        return LiveTextComposition(element: focused, insertionStart: selectedRange.location)
    }

    /// Select and replace exactly the session-owned range, leaving earlier field contents intact.
    func replace(with text: String) -> Bool {
        var range = CFRange(location: insertionStart, length: composedUTF16Length)
        guard let rangeValue = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success,
              AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success else { return false }
        composedUTF16Length = text.utf16.count
        return true
    }
}
