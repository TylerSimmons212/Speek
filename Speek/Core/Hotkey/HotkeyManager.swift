import AppKit
import Combine
import CoreGraphics

/// Listens for the configured push-to-talk key globally via a CGEventTap.
/// Emits .pressed when the user begins holding the key, .released when they let go.
final class HotkeyManager {
    enum Event { case pressed, released }
    let events = PassthroughSubject<Event, Never>()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    /// Modifier flag that triggers push-to-talk. Defaults to Fn but is overridden
    /// from SettingsStore. For Right-Option / Right-Command, we additionally check
    /// the event's key code so left/right are distinguishable (the flag bit alone
    /// fires for either side).
    var triggerFlag: CGEventFlags = .maskSecondaryFn
    var requiredKeyCode: CGKeyCode? = nil

    func configure(for choice: SettingsStore.HotkeyChoice) {
        switch choice {
        case .fn:
            triggerFlag = .maskSecondaryFn
            requiredKeyCode = nil
        case .rightOption:
            triggerFlag = .maskAlternate
            requiredKeyCode = 0x3D  // kVK_RightOption
        case .rightCommand:
            triggerFlag = .maskCommand
            requiredKeyCode = 0x36  // kVK_RightCommand
        }
    }

    func start() {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
            // macOS disables our tap if our callback is slow or under various system
            // conditions. Re-enable so the hotkey keeps working past the first failure.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                NSLog("HotkeyManager: tap disabled (\(type.rawValue)) — re-enabling.")
                if let tap = manager.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                manager.resyncStateAfterReenable()
                return Unmanaged.passUnretained(event)
            }
            manager.handle(event: event)
            return Unmanaged.passUnretained(event)
        }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        // Use .cghidEventTap (earliest tap, closest to hardware) instead of
        // .cgSessionEventTap. The Fn/Globe key is intercepted by macOS's system
        // handler when focus is on a text input — at session level the event is
        // already consumed. The HID-level tap sees the raw event before that.
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: opaque
        )
        guard let eventTap else {
            NSLog("HotkeyManager: CGEvent.tapCreate returned nil — grant Input Monitoring to Speek in System Settings → Privacy & Security → Input Monitoring, then relaunch.")
            return
        }
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

    /// After the system re-enables our tap, the current modifier state may no
    /// longer match `isPressed` (the user could be holding the hotkey already,
    /// but we missed the flagsChanged edge while disabled). Sync by inspecting
    /// the live flag state, and synthesize a press/release if needed.
    fileprivate func resyncStateAfterReenable() {
        let liveFlags = CGEventSource.flagsState(.combinedSessionState)
        let flagSet = liveFlags.contains(triggerFlag)
        if flagSet && !isPressed && requiredKeyCode == nil {
            isPressed = true
            events.send(.pressed)
        } else if !flagSet && isPressed {
            isPressed = false
            events.send(.released)
        }
    }

    private func handle(event: CGEvent) {
        let flags = event.flags
        let flagSet = flags.contains(triggerFlag)
        // For left/right modifiers, the flag bit alone fires for either side.
        // Disambiguate by also matching the key code on flagsChanged events.
        let pressed: Bool
        if let required = requiredKeyCode {
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if flagSet && keyCode == required {
                pressed = true
            } else if isPressed && (!flagSet || keyCode == required) {
                pressed = false
            } else {
                return
            }
        } else {
            pressed = flagSet
        }
        if pressed && !isPressed {
            isPressed = true
            events.send(.pressed)
        } else if !pressed && isPressed {
            isPressed = false
            events.send(.released)
        }
    }
}
