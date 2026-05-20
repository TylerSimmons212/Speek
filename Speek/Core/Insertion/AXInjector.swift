import ApplicationServices
import AppKit

final class AXInjector: TextInjector {
    func insert(_ text: String) async throws -> InjectionResult {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused else {
            throw InjectionError.unsupportedTarget
        }
        // swiftlint:disable:next force_cast
        let axElement = element as! AXUIElement

        // Many apps (Messages, Electron-based apps, some Cocoa text views)
        // accept the kAXSelectedText write and return .success but don't
        // actually insert anything. Read the value before and after and only
        // claim success if the field actually changed.
        let beforeValue = readValue(axElement)
        let beforeLength = beforeValue?.count

        var rangeRef: CFTypeRef?
        let rangeErr = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        guard rangeErr == .success, rangeRef != nil else {
            throw InjectionError.unsupportedTarget
        }

        let setErr = AXUIElementSetAttributeValue(
            axElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        guard setErr == .success else {
            throw InjectionError.unsupportedTarget
        }

        // Verify the write actually landed. Apps like Messages accept the
        // kAXSelectedText write and return .success, but the visible composer
        // is drawn from a separate text store — the value we read back may
        // either not change OR change without reflecting our text. Demand
        // both: the value must have changed AND the new value must contain
        // exactly what we wrote.
        if let beforeValue {
            let afterValue = readValue(axElement) ?? beforeValue
            let didChange = afterValue != beforeValue
            let containsInserted = afterValue.contains(text)
            let grew = beforeLength.map { afterValue.count >= $0 + text.count - 1 } ?? false
            guard didChange && (containsInserted || grew) else {
                throw InjectionError.unsupportedTarget
            }
        }
        return .inserted
    }

    private func readValue(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }
}
