import Carbon
import Combine
import Foundation

final class SettingsService: ObservableObject {
    static let shared = SettingsService()

    enum TriggerType: String, CaseIterable {
        case keyboard
        case mouseButton
    }

    @Published var triggerType: TriggerType
    @Published var keyCode: UInt32
    @Published var modifiers: UInt32
    @Published var keyDisplayName: String
    @Published var mouseButton: Int
    @Published var excludedBundleIds: Set<String>

    private let defaults = UserDefaults.standard

    private init() {
        let storedType = defaults.string(forKey: "triggerType") ?? "keyboard"
        triggerType = TriggerType(rawValue: storedType) ?? .keyboard
        keyCode = defaults.object(forKey: "keyCode") != nil
            ? UInt32(defaults.integer(forKey: "keyCode"))
            : UInt32(kVK_Space)
        modifiers = defaults.object(forKey: "modifiers") != nil
            ? UInt32(defaults.integer(forKey: "modifiers"))
            : UInt32(optionKey)
        keyDisplayName = defaults.string(forKey: "keyDisplayName") ?? "Space"
        mouseButton = defaults.object(forKey: "mouseButton") != nil
            ? defaults.integer(forKey: "mouseButton")
            : 2
        excludedBundleIds = Set(defaults.stringArray(forKey: "excludedBundleIds") ?? [])
    }

    func save() {
        defaults.set(triggerType.rawValue, forKey: "triggerType")
        defaults.set(Int(keyCode), forKey: "keyCode")
        defaults.set(Int(modifiers), forKey: "modifiers")
        defaults.set(keyDisplayName, forKey: "keyDisplayName")
        defaults.set(mouseButton, forKey: "mouseButton")
        defaults.set(Array(excludedBundleIds), forKey: "excludedBundleIds")
    }

    var shortcutDisplayString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("\u{2303}") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("\u{2325}") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("\u{21E7}") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("\u{2318}") }
        parts.append(keyDisplayName)
        return parts.joined(separator: " ")
    }

    var mouseButtonDisplayName: String {
        switch mouseButton {
        case 2: return "Middle Button"
        case 3: return "Button 4"
        case 4: return "Button 5"
        default: return "Button \(mouseButton + 1)"
        }
    }
}
