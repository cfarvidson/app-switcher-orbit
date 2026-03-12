import Carbon
import AppKit

final class HotkeyService {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    func register() -> Bool {
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

        // Retained to prevent dangling pointer in the Carbon callback
        let selfPtr = Unmanaged.passRetained(self).toOpaque()

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
            NSLog("Orbit: Failed to install event handler (status: \(handlerStatus))")
            return false
        }

        let hotkeyStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard hotkeyStatus == noErr else {
            NSLog("Orbit: Failed to register hotkey Option+Space (status: \(hotkeyStatus))")
            return false
        }

        return true
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
            // Balance the passRetained from register()
            Unmanaged.passUnretained(self).release()
        }
    }

    deinit {
        unregister()
    }
}
