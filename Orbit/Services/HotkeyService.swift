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
                guard self?.isCursorOverTabOrLink() != true else { return }
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

    // MARK: - Accessibility element detection

    /// Returns true if the cursor is over a tab bar element or a link,
    /// where middle-click typically has its own meaning (close tab, open in new tab).
    /// Uses the macOS Accessibility API to inspect what's under the cursor.
    /// Note: Electron apps expose generic AXGroup elements, so detection is limited there.
    private func isCursorOverTabOrLink() -> Bool {
        let mouseLocation = NSEvent.mouseLocation
        guard let primaryScreen = NSScreen.screens.first else { return false }

        // Convert from AppKit coordinates (bottom-left origin) to AX coordinates (top-left origin)
        let axX = Float(mouseLocation.x)
        let axY = Float(primaryScreen.frame.height - mouseLocation.y)

        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, axX, axY, &elementRef) == .success,
              let element = elementRef else {
            return false
        }

        // Suppress if cursor is on window chrome (title bar, tab bar, toolbar).
        // Firefox/Zen tabs report AXWindow directly with no child element.
        if axRole(of: element) == "AXWindow" {
            return true
        }

        // Walk up the parent chain to catch links, tab groups, and tab buttons
        var current: AXUIElement? = element
        for _ in 0..<6 {
            guard let el = current else { break }
            let elRole = axRole(of: el)

            // AXLink: middle-click opens in new tab
            // AXTabGroup: middle-click closes tabs (Chrome tab bars)
            // AXToolbar: covers Safari's tab bar and toolbar area
            if elRole == "AXLink" || elRole == "AXTabGroup" || elRole == "AXToolbar" {
                return true
            }
            // Safari tabs: AXRadioButton with subrole AXTabButton
            if axSubrole(of: el) == "AXTabButton" {
                return true
            }

            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, "AXParent" as CFString, &parentRef) == .success else {
                break
            }
            current = (parentRef as! AXUIElement)
        }

        return false
    }

    private func axRole(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func axSubrole(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSubrole" as CFString, &value) == .success else {
            return nil
        }
        return value as? String
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
