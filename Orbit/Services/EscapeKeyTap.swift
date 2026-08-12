import AppKit
import ApplicationServices

/// Swallows the Escape key system-wide while active and reports each press
/// to `onEscape`. Used during dictation so that cancelling a session does
/// not also deliver an Escape to whatever app the user is typing into.
///
/// A `CGEvent` tap is the only way to *consume* a key press from another
/// app's event stream. `NSEvent.addGlobalMonitorForEvents` can observe but
/// never swallow, which is why this type exists. Taps require Accessibility
/// permission - already required by Orbit for its hotkey and text injection.
///
/// `start()` returns false when the tap cannot be created, so the caller can
/// fall back to an observe-only monitor. In that state Escape still cancels
/// dictation, it just also reaches the frontmost app.
final class EscapeKeyTap {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onEscape: () -> Void

    private static let escapeKeyCode: Int64 = 53

    init(onEscape: @escaping () -> Void) {
        self.onEscape = onEscape
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        // Both keyDown and keyUp: swallowing only the down would leave apps
        // that act on key-up seeing an Escape release with no press.
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        // The callback is a C function pointer and cannot capture, so `self`
        // travels through `userInfo` as an opaque pointer.
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<EscapeKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
            return tap.handle(type: type, event: event)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("[Orbit.speech] escape tap could not be created (Accessibility?), falling back to observe-only")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        tap = port
        runLoopSource = source
        NSLog("[Orbit.speech] escape tap installed")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that takes too long to respond, or when the
        // user input state is reset. Re-enable instead of silently going
        // deaf for the rest of the session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            NSLog("[Orbit.speech] escape tap was disabled by the system, re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        // A modified Escape - Cmd-Opt-Esc above all, which opens Force Quit -
        // must reach the frontmost app untouched. Force Quit is the user's
        // escape hatch for exactly the case where an app has hung, and this
        // tap is system-wide, so swallowing it here would be the wrong
        // default. Only plain, unmodified Escape cancels dictation.
        let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        if !event.flags.intersection(modifierMask).isEmpty {
            return Unmanaged.passUnretained(event)
        }

        // Act on the press only; the release is swallowed silently. Hop to
        // main asynchronously so the event callback returns immediately -
        // a slow callback is exactly what makes macOS disable the tap.
        if type == .keyDown {
            DispatchQueue.main.async { [weak self] in self?.onEscape() }
        }
        return nil  // swallowed, never reaches the frontmost app
    }
}
