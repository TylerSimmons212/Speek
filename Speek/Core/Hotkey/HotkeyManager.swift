import AppKit
import Combine
import CoreGraphics

/// Listens for the configured push-to-talk key globally via a CGEventTap.
/// Emits .pressed when the user begins holding the key, .released when they let go.
///
/// A release carries a `clean` flag: `false` means some other key or mouse
/// button was pressed while the trigger modifier was held — i.e. the user was
/// typing a chord (Fn+arrow, Right-Option+letter for a special character,
/// Fn+click), not asking for dictation. Consumers should discard the recording
/// for dirty releases rather than transcribing it.
@MainActor
final class HotkeyManager {
    enum Event: Equatable {
        case pressed
        case released(clean: Bool)
    }
    let events = PassthroughSubject<Event, Never>()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false
    /// True once any non-trigger key or mouse button goes down while the
    /// trigger modifier is held. Cleared on each new press.
    private var otherInputDuringPress = false
    /// Recreates the tap if macOS silently disabled it and no event arrives to
    /// trigger the in-callback re-enable path.
    private var healthCheckTask: Task<Void, Never>?
    private let healthCheckInterval: TimeInterval = 30

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
        // flagsChanged drives the trigger itself; keyDown and mouse-downs are
        // observed only to mark a press "dirty" (chord detection). The tap is
        // listen-only — nothing is consumed, every event passes through.
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
            // The tap's run-loop source is added to the main run loop, so this
            // callback always executes on the main thread — safe to assume.
            MainActor.assumeIsolated {
                // macOS disables our tap if our callback is slow or under various
                // system conditions. Re-enable so the hotkey keeps working past
                // the first failure.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    NSLog("HotkeyManager: tap disabled (\(type.rawValue)) — re-enabling.")
                    if let tap = manager.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    manager.resyncStateAfterReenable()
                    return
                }
                switch type {
                case .flagsChanged:
                    manager.handle(event: event)
                case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
                    // Any other input while the trigger is held marks the press
                    // as a chord — the release will be reported as not clean.
                    if manager.isPressed { manager.otherInputDuringPress = true }
                default:
                    break
                }
            }
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
        startHealthCheck()
    }

    func stop() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isPressed = false
        otherInputDuringPress = false
    }

    /// The in-callback re-enable only runs if a `tapDisabledBy*` event is
    /// actually delivered — under some conditions (system sleep, login window,
    /// secure input) the tap dies silently and no callback ever fires again.
    /// This watchdog polls every `healthCheckInterval` seconds and first tries
    /// a cheap re-enable, then a full teardown + recreate if that didn't stick.
    private func startHealthCheck() {
        healthCheckTask?.cancel()
        let interval = healthCheckInterval
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                self?.checkTapHealth()
            }
        }
    }

    private func checkTapHealth() {
        guard let tap = eventTap else { return }
        guard !CGEvent.tapIsEnabled(tap: tap) else { return }
        NSLog("HotkeyManager: health check found tap disabled — re-enabling.")
        CGEvent.tapEnable(tap: tap, enable: true)
        if CGEvent.tapIsEnabled(tap: tap) {
            resyncStateAfterReenable()
            return
        }
        // Re-enable didn't stick — the mach port is likely dead. Recreate from
        // scratch. stop() cancels the watchdog task this very call is running
        // inside (its loop exits on the next isCancelled check) and start()
        // spawns a fresh one, so exactly one watchdog survives.
        NSLog("HotkeyManager: re-enable failed — recreating event tap.")
        stop()
        start()
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
            otherInputDuringPress = false
            events.send(.pressed)
        } else if !flagSet && isPressed {
            isPressed = false
            // We missed the real release edge while the tap was dead, so we
            // can't know how stale this recording is or where focus went in
            // the meantime. Report dirty so the session discards it instead of
            // typing seconds-old audio into whatever is focused now.
            events.send(.released(clean: false))
            otherInputDuringPress = false
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
            otherInputDuringPress = false
            events.send(.pressed)
        } else if !pressed && isPressed {
            isPressed = false
            events.send(.released(clean: !otherInputDuringPress))
            otherInputDuringPress = false
        }
    }
}
