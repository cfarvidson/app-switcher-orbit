import Carbon
import SwiftUI

struct ShortcutRecorderView: View {
    @ObservedObject var settings: SettingsService
    @State private var isRecording = false
    @State private var localMonitor: Any?


    var body: some View {
        HStack {
            HStack(spacing: 6) {
                if isRecording {
                    Text("Press shortcut\u{2026}")
                        .foregroundStyle(.secondary)
                } else {
                    Text(settings.shortcutDisplayString)
                        .fontWeight(.medium)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: 140)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isRecording ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isRecording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
            )

            if isRecording {
                Button("Cancel") {
                    stopRecording()
                }
                .buttonStyle(.bordered)
            } else {
                Button("Record") {
                    startRecording()
                }
                .buttonStyle(.bordered)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let carbonMods = carbonModifiers(from: event.modifierFlags)

            // Require at least one modifier key
            guard carbonMods != 0 else {
                // ESC cancels recording
                if event.keyCode == 53 {
                    stopRecording()
                }
                return nil
            }

            let name = keyDisplayName(
                keyCode: UInt32(event.keyCode),
                characters: event.charactersIgnoringModifiers
            )

            settings.keyCode = UInt32(event.keyCode)
            settings.modifiers = carbonMods
            settings.keyDisplayName = name
            settings.save()
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    private func keyDisplayName(keyCode: UInt32, characters: String?) -> String {
        // Special keys
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Fwd Delete"
        case kVK_Escape: return "Escape"
        case kVK_UpArrow: return "\u{2191}"
        case kVK_DownArrow: return "\u{2193}"
        case kVK_LeftArrow: return "\u{2190}"
        case kVK_RightArrow: return "\u{2192}"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            if let chars = characters, !chars.isEmpty {
                return chars.uppercased()
            }
            return "Key \(keyCode)"
        }
    }
}
