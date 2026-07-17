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

    /// The user's trigger. Modifier bindings are matched on flagsChanged
    /// events (flag family + hardware key code so left/right distinguish);
    /// function-key bindings (F13–F20) are matched on keyDown/keyUp.
    private(set) var binding: HotkeyBinding = .fn

    // MARK: - Read-aloud trigger (optional second binding)

    /// Fires once per clean tap of the read-aloud key. Unlike dictation's
    /// press/release pair, read-aloud is a toggle — the consumer decides
    /// whether a tap means "start reading" or "stop".
    let readAloudEvents = PassthroughSubject<Void, Never>()
    /// Nil = read-aloud hotkey off. Never equal to `binding` — dictation wins.
    private(set) var readAloudBinding: HotkeyBinding?
    private var raPressed = false
    private var raDirty = false
    private var raPressStart: Date?
    /// A modifier held longer than this wasn't a tap — some other gesture.
    private let raTapMaxDuration: TimeInterval = 0.6

    func configure(binding: HotkeyBinding) {
        self.binding = binding
        // Re-evaluate the conflict guard against the new dictation key.
        configureReadAloud(binding: readAloudBinding)
    }

    func configureReadAloud(binding: HotkeyBinding?) {
        readAloudBinding = (binding == self.binding) ? nil : binding
        raPressed = false
        raDirty = false
        raPressStart = nil
    }

    /// True while the event tap exists (started and not stopped).
    var isRunning: Bool { eventTap != nil }

    func start() {
        // Idempotent: callers may retry start() after permission grants
        // (onboarding does). A live tap must not be doubled.
        guard eventTap == nil else { return }
        // flagsChanged drives the trigger itself; keyDown and mouse-downs are
        // observed only to mark a press "dirty" (chord detection). The tap is
        // listen-only — nothing is consumed, every event passes through.
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
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
                    manager.handleReadAloudFlags(event: event)
                case .keyDown:
                    manager.handleKey(event: event, down: true)
                    manager.handleReadAloudKey(event: event, down: true)
                case .keyUp:
                    manager.handleKey(event: event, down: false)
                    manager.handleReadAloudKey(event: event, down: false)
                case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                    // Any other input while a trigger is held marks the press
                    // as a chord — the release will be reported as not clean.
                    if manager.isPressed { manager.otherInputDuringPress = true }
                    if manager.raPressed { manager.raDirty = true }
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
        raPressed = false
        raDirty = false
        raPressStart = nil
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
    /// the live flag state, and synthesize a release if needed. (Function-key
    /// bindings have no queryable "is held" state — a missed release there is
    /// recovered by the next keyDown edge resetting `isPressed`.)
    fileprivate func resyncStateAfterReenable() {
        // A half-tracked read-aloud tap from before the outage is stale.
        raPressed = false
        raDirty = false
        raPressStart = nil
        guard let flag = binding.flag else { return }
        let liveFlags = CGEventSource.flagsState(.combinedSessionState)
        if !liveFlags.contains(flag) && isPressed {
            isPressed = false
            // We missed the real release edge while the tap was dead, so we
            // can't know how stale this recording is or where focus went in
            // the meantime. Report dirty so the session discards it instead of
            // typing seconds-old audio into whatever is focused now.
            events.send(.released(clean: false))
            otherInputDuringPress = false
        }
    }

    /// flagsChanged — drives modifier bindings.
    private func handle(event: CGEvent) {
        guard let triggerFlag = binding.flag else {
            // Function-key binding: a modifier press mid-dictation is chord
            // usage, mark dirty.
            if isPressed { otherInputDuringPress = true }
            return
        }
        let flagSet = event.flags.contains(triggerFlag)
        // The flag bit alone fires for either side (left/right); the hardware
        // key code on the flagsChanged event disambiguates.
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let pressed: Bool
        if flagSet && keyCode == binding.keyCode {
            pressed = true
        } else if isPressed && (!flagSet || keyCode == binding.keyCode) {
            pressed = false
        } else {
            return
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

    /// keyDown/keyUp — drives function-key bindings, and chord detection for
    /// modifier bindings.
    fileprivate func handleKey(event: CGEvent, down: Bool) {
        guard case .functionKey(let triggerCode) = binding else {
            // Modifier binding: any key pressed while the trigger is held is
            // a chord — the release will be reported dirty.
            if down && isPressed { otherInputDuringPress = true }
            return
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == triggerCode {
            if down {
                // Held keys autorepeat; only the first edge is a press.
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                guard !isRepeat, !isPressed else { return }
                isPressed = true
                otherInputDuringPress = false
                events.send(.pressed)
            } else if isPressed {
                isPressed = false
                events.send(.released(clean: !otherInputDuringPress))
                otherInputDuringPress = false
            }
        } else if down && isPressed {
            otherInputDuringPress = true
        }
    }

    // MARK: - Read-aloud handlers

    /// flagsChanged — drives read-aloud MODIFIER bindings with tap semantics:
    /// a clean press+release under `raTapMaxDuration` fires the trigger.
    /// Anything else (chords, long holds) is the user doing something else.
    fileprivate func handleReadAloudFlags(event: CGEvent) {
        guard let ra = readAloudBinding else { return }
        guard let flag = ra.flag else {
            // Function-key read-aloud binding: modifier activity during the
            // (instantaneous) keyDown trigger is irrelevant.
            return
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flagSet = event.flags.contains(flag)

        if flagSet && keyCode == ra.keyCode && !raPressed {
            raPressed = true
            // Born dirty if any OTHER modifier family is already held — the
            // user is mid-chord (⌘ + right-⌥ + …), not tapping our trigger.
            let allModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
            raDirty = !event.flags.intersection(allModifiers.subtracting(flag)).isEmpty
            raPressStart = Date()
        } else if raPressed && (!flagSet || keyCode == ra.keyCode) {
            raPressed = false
            let duration = raPressStart.map { Date().timeIntervalSince($0) } ?? .infinity
            raPressStart = nil
            if !raDirty && duration < raTapMaxDuration {
                readAloudEvents.send(())
            }
        } else if raPressed {
            // Some OTHER modifier changed while ours is held — a chord.
            raDirty = true
        }
    }

    /// keyDown/keyUp — drives read-aloud FUNCTION-KEY bindings (fire on the
    /// press edge), and chord detection for modifier bindings.
    fileprivate func handleReadAloudKey(event: CGEvent, down: Bool) {
        guard let ra = readAloudBinding else { return }
        if case .functionKey(let triggerCode) = ra {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard keyCode == triggerCode, down else { return }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat { readAloudEvents.send(()) }
            return
        }
        // Modifier binding: a character key during the hold makes it a chord.
        if down && raPressed { raDirty = true }
    }
}
