import Carbon
import AppKit

final class HotkeyService {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var retainedSelf = false
    private let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    // MARK: - Keyboard hotkey

    @discardableResult
    func registerKeyboard(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregisterKeyboard()

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(
            UInt32(UInt8(ascii: "O")) << 24 |
            UInt32(UInt8(ascii: "R")) << 16 |
            UInt32(UInt8(ascii: "B")) << 8 |
            UInt32(UInt8(ascii: "T"))
        )
        hotKeyID.id = 1

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passRetained(self).toOpaque()
        retainedSelf = true

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    service.callback()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )

        guard handlerStatus == noErr else {
            Unmanaged<HotkeyService>.fromOpaque(selfPtr).release()
            retainedSelf = false
            NSLog("Orbit: Failed to install event handler (status: \(handlerStatus))")
            return false
        }

        let hotkeyStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard hotkeyStatus == noErr else {
            NSLog("Orbit: Failed to register hotkey (status: \(hotkeyStatus))")
            return false
        }

        return true
    }

    // MARK: - Mouse button

    @discardableResult
    func registerMouseButton(_ button: Int) -> Bool {
        unregisterMouseButton()

        let matching: NSEvent.EventTypeMask = button == 1 ? .rightMouseDown : .otherMouseDown

        // Global monitor: fires when other apps are focused
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: matching) { [weak self] event in
            if event.buttonNumber == button {
                DispatchQueue.main.async {
                    self?.callback()
                }
            }
        }

        // Local monitor: fires when our overlay panel is key
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: matching) { [weak self] event in
            if event.buttonNumber == button {
                DispatchQueue.main.async {
                    self?.callback()
                }
                return nil
            }
            return event
        }

        return mouseMonitor != nil
    }

    // MARK: - Registration from settings

    func registerFromSettings(_ settings: SettingsService) {
        unregister()
        switch settings.triggerType {
        case .keyboard:
            registerKeyboard(keyCode: settings.keyCode, modifiers: settings.modifiers)
        case .mouseButton:
            registerMouseButton(settings.mouseButton)
        case .both:
            registerKeyboard(keyCode: settings.keyCode, modifiers: settings.modifiers)
            registerMouseButton(settings.mouseButton)
        }
    }

    // MARK: - Cleanup

    private func unregisterKeyboard() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
            if retainedSelf {
                Unmanaged.passUnretained(self).release()
                retainedSelf = false
            }
        }
    }

    private func unregisterMouseButton() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
    }

    func unregister() {
        unregisterKeyboard()
        unregisterMouseButton()
    }

    deinit {
        unregister()
    }
}
