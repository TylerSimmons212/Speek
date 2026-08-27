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

        var rangeRef: CFTypeRef?
        let rangeErr = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        guard rangeErr == .success, let rangeRef else {
            throw InjectionError.unsupportedTarget
        }
        var selection = CFRange(location: 0, length: 0)
        let haveSelection = AXValueGetValue(rangeRef as! AXValue, .cfRange, &selection)

        // Many apps (Messages, Electron-based apps, some Cocoa text views)
        // accept the kAXSelectedText write and return .success but don't
        // actually insert anything — so every write is verified. Verification
        // used to read the ENTIRE field value twice (before + after); on
        // large documents those two O(document) IPC serializations made every
        // insertion visibly slow. Where the element reports a character count
        // we verify by counts instead — two O(1) reads. The full-value
        // comparison remains as the fallback for elements without counts.
        let beforeCount = Self.characterCount(axElement)
        let beforeValue = beforeCount == nil ? readValue(axElement) : nil

        let setErr = AXUIElementSetAttributeValue(
            axElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        guard setErr == .success else {
            throw InjectionError.unsupportedTarget
        }

        if let beforeCount {
            try await Self.verifyByCount(
                axElement,
                beforeCount: beforeCount,
                insertedUTF16: text.utf16.count,
                replacedUTF16: haveSelection ? selection.length : 0,
                insertionLocation: haveSelection ? selection.location : nil,
                insertedText: text
            )
        } else if let beforeValue {
            // Demand both: the value must have changed AND the new value must
            // contain what we wrote (or have grown by roughly its length —
            // apps that autocorrect on insert transform the text slightly).
            let afterValue = readValue(axElement) ?? beforeValue
            let didChange = afterValue != beforeValue
            let containsInserted = afterValue.contains(text)
            let grew = afterValue.count >= beforeValue.count + text.count - 1
            guard didChange && (containsInserted || grew) else {
                throw InjectionError.unsupportedTarget
            }
        }
        return .inserted
    }

    /// Count-based write verification: the field must have grown by the
    /// inserted length minus whatever selection it replaced (with a small
    /// tolerance for app-side transforms like smart quotes or autocorrect).
    /// When the count can't prove anything (same-length replacement), fall
    /// back to reading just the inserted span — O(text), never O(document).
    ///
    /// Bias: a false "failed" verdict is WORSE than a false "landed" one —
    /// failure sends CompositeInjector to the typing fallback, and if the AX
    /// write actually landed, the user gets the text TWICE. So: apps that
    /// apply AX writes asynchronously (Electron/web views) get a few beats
    /// for the count to move, and a write whose result we cannot read at all
    /// is trusted on its .success return.
    private static func verifyByCount(
        _ element: AXUIElement,
        beforeCount: Int,
        insertedUTF16: Int,
        replacedUTF16: Int,
        insertionLocation: Int?,
        insertedText: String
    ) async throws {
        let expectedGrowth = insertedUTF16 - replacedUTF16
        if expectedGrowth != 0 {
            for attempt in 0..<4 {
                guard let afterCount = characterCount(element) else {
                    return // write succeeded but result unreadable — trust it
                }
                if afterCount != beforeCount, afterCount >= beforeCount + expectedGrowth - 2 {
                    return
                }
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            throw InjectionError.unsupportedTarget
        }
        // Same-length replacement — counts can't detect a silent no-op.
        // Read back only the span we wrote; if the app can't do that either,
        // accept the .success return (the pre-existing blacklist covers known
        // liars).
        guard let location = insertionLocation,
              let span = stringForRange(element, location: location, length: insertedUTF16) else { return }
        guard span == insertedText else {
            throw InjectionError.unsupportedTarget
        }
    }

    private static func characterCount(_ element: AXUIElement) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &ref) == .success,
              let count = ref as? Int else { return nil }
        return count
    }

    private static func stringForRange(_ element: AXUIElement, location: Int, length: Int) -> String? {
        var range = CFRange(location: location, length: length)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, axRange, &ref
        ) == .success else { return nil }
        return ref as? String
    }

    private func readValue(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }
}
