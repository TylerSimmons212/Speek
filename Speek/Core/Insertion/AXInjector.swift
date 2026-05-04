import ApplicationServices
import AppKit

final class AXInjector: TextInjector {
    func insert(_ text: String) async throws {
        // Find the system-wide focused element.
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused else {
            throw InjectionError.unsupportedTarget
        }
        // swiftlint:disable:next force_cast
        let axElement = element as! AXUIElement

        // Try to insert at the current selected text range.
        var rangeRef: CFTypeRef?
        let rangeErr = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        if rangeErr == .success, let rangeRef = rangeRef {
            let setErr = AXUIElementSetAttributeValue(
                axElement,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
            )
            if setErr == .success { return }
        }

        // Fallback: try setting the whole AXValue attribute (text fields without selection).
        let setValueErr = AXUIElementSetAttributeValue(
            axElement,
            kAXValueAttribute as CFString,
            text as CFTypeRef
        )
        if setValueErr == .success { return }

        throw InjectionError.unsupportedTarget
    }
}
