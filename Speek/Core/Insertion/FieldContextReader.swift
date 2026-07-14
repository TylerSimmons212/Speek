import ApplicationServices
import AppKit

/// Snapshot of the focused text field taken at recording start. Carries
/// everything the pipeline needs to format the dictation *in context* and
/// everything the injector needs to safely repair the seam afterward.
struct FieldSnapshot: @unchecked Sendable {  // AXUIElement is a thread-safe CF remote reference
    /// The focused element at capture time — used to verify nothing changed
    /// before attempting an in-place fragment replacement.
    let element: AXUIElement
    /// Full text before the cursor as read at capture (used as a change guard).
    let prefix: String
    /// Cursor position at capture, in UTF-16 units (AX range coordinates).
    let prefixUTF16Length: Int
    /// Bounded read-only context before the current sentence (tone/reference).
    let preceding: String
    /// The unfinished sentence fragment immediately before the cursor —
    /// the only span the seam-repair path is ever allowed to rewrite.
    let fragment: String

    var polishContext: PolishContext? {
        guard !preceding.isEmpty || !fragment.isEmpty else { return nil }
        return PolishContext(preceding: preceding, fragment: fragment)
    }
}

/// Detects whether keyboard focus is inside one of Speek's own windows.
/// Every accessibility call that targets the focused element MUST check this
/// first: AX queries against our own process are answered by our own main
/// thread, so a synchronous self-query or self-write deadlocks the app
/// (observed live: insertCore frozen in AXUIElementSetAttributeValue during
/// the onboarding tryout, which dictates into Speek's own TextEditor).
enum FocusOwnership {
    @MainActor
    static var ownWindowFocused: Bool {
        NSApp.isActive && NSApp.keyWindow != nil
    }
}

enum FieldContextReader {
    /// The seam-repair span is capped: a "fragment" longer than this is almost
    /// certainly not an unfinished sentence (weird field content), and we
    /// don't want the LLM rewriting large spans of existing text.
    static let maxFragmentLength = 240
    /// Read-only context cap — enough for tone, small enough for latency.
    static let maxPrecedingLength = 300

    /// Reads the focused field. Returns nil for AX-opaque apps, empty fields,
    /// secure fields, or when there's a non-empty selection (replacing a
    /// user's selection is the app's paste semantics, not ours to reformat).
    @MainActor
    static func capture() -> FieldSnapshot? {
        // Self-AX deadlocks — never capture context from our own windows.
        guard !FocusOwnership.ownWindowFocused else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused else { return nil }
        // swiftlint:disable:next force_cast
        let element = f as! AXUIElement

        // Never read secure fields.
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        if (subroleRef as? String) == (kAXSecureTextFieldSubrole as String) { return nil }

        var valueRef: CFTypeRef?
        var rangeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        guard let value = valueRef as? String, !value.isEmpty, let rangeRef else { return nil }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.length == 0 else { return nil }

        let utf16 = Array(value.utf16)
        let cursor = max(0, min(utf16.count, range.location))
        guard cursor > 0 else { return nil }
        let prefix = String(decoding: utf16[0..<cursor], as: UTF16.self)

        let (preceding, fragment) = split(prefix: prefix)
        return FieldSnapshot(
            element: element,
            prefix: prefix,
            prefixUTF16Length: cursor,
            preceding: preceding,
            fragment: fragment
        )
    }

    /// Splits the pre-cursor text into (read-only preceding, rewriteable
    /// fragment). The fragment is everything after the last sentence
    /// terminator; if it exceeds `maxFragmentLength` it's demoted to
    /// preceding-context so the seam-repair path stays bounded.
    static func split(prefix: String) -> (preceding: String, fragment: String) {
        let terminators: Set<Character> = [".", "!", "?", "…", "\n"]
        let lastTerminator = prefix.lastIndex(where: { terminators.contains($0) })

        let fragmentStart = lastTerminator.map(prefix.index(after:)) ?? prefix.startIndex
        var fragment = String(prefix[fragmentStart...])
        // Leading whitespace belongs to the gap, not the fragment.
        fragment = String(fragment.drop(while: { $0.isWhitespace }))

        var precedingEnd = fragmentStart
        if fragment.count > maxFragmentLength {
            fragment = ""
            precedingEnd = prefix.endIndex
        }
        let precedingFull = String(prefix[..<precedingEnd])
        let preceding = String(precedingFull.suffix(maxPrecedingLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (preceding, fragment)
    }
}
