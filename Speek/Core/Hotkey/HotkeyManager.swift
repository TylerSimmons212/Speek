import AppKit
import Combine

/// Listens for the configured push-to-talk key globally via a CGEventTap.
/// Emits .pressed when the user begins holding the key, .released when they let go.
final class HotkeyManager {
    enum Event { case pressed, released }
    let events = PassthroughSubject<Event, Never>()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    /// Default: macOS Fn key. flagsChanged events report this in CGEventFlags.
    private let triggerFlag: CGEventFlags = .maskSecondaryFn

    func start() {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, _, event, refcon in
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
            manager.handle(event: event)
            return Unmanaged.passUnretained(event)
        }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: opaque
        )
        guard let eventTap else { return }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isPressed = false
    }

    private func handle(event: CGEvent) {
        let flags = event.flags
        let pressed = flags.contains(triggerFlag)
        if pressed && !isPressed {
            isPressed = true
            events.send(.pressed)
        } else if !pressed && isPressed {
            isPressed = false
            events.send(.released)
        }
    }
}
