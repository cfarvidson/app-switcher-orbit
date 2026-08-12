import Carbon
import Combine
import Foundation

final class SettingsService: ObservableObject {
    static let shared = SettingsService()

    enum TriggerType: String, CaseIterable {
        case keyboard
        case mouseButton
        case both
    }

    enum InputMode: String, CaseIterable {
        case mouse
        case trackpad
    }

    @Published var triggerType: TriggerType
    @Published var inputMode: InputMode
    @Published var keyCode: UInt32
    @Published var modifiers: UInt32
    @Published var keyDisplayName: String
    @Published var mouseButton: Int
    @Published var edgeActivation: Bool
    @Published var pinnedBundleIds: [String]
    @Published var excludedBundleIds: Set<String>
    @Published var dictationEnabled: Bool
    @Published var dictationSilenceTriggerSeconds: Double
    @Published var pinnedPreferredAngles: [String: Double]
    @Published var dictationPreferredAngle: Double?
    @Published var dictationInputDeviceUID: String?

    private let defaults = UserDefaults.standard

    private init() {
        let storedType = defaults.string(forKey: "triggerType") ?? "keyboard"
        triggerType = TriggerType(rawValue: storedType) ?? .keyboard
        let storedInputMode = defaults.string(forKey: "inputMode") ?? "mouse"
        inputMode = InputMode(rawValue: storedInputMode) ?? .mouse
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
        edgeActivation = defaults.object(forKey: "edgeActivation") != nil
            ? defaults.bool(forKey: "edgeActivation")
            : false
        pinnedBundleIds = defaults.stringArray(forKey: "pinnedBundleIds") ?? []
        excludedBundleIds = Set(defaults.stringArray(forKey: "excludedBundleIds") ?? [])
        dictationEnabled = defaults.object(forKey: "dictationEnabled") != nil
            ? defaults.bool(forKey: "dictationEnabled")
            : false
        dictationSilenceTriggerSeconds = defaults.object(forKey: "dictationSilenceTriggerSeconds") != nil
            ? defaults.double(forKey: "dictationSilenceTriggerSeconds")
            : 0.8
        pinnedPreferredAngles = SettingsService.loadAngleDict(defaults: defaults, key: "pinnedAngles")
        dictationPreferredAngle = defaults.object(forKey: "dictationAngle") as? Double
        dictationInputDeviceUID = defaults.string(forKey: "dictationInputDeviceUID")
    }

    /// Converts a UserDefaults-stored dictionary back to `[String: Double]`.
    /// The direct cast `as? [String: Double]` doesn't round-trip reliably
    /// because UserDefaults bridges numbers through NSNumber; we walk the
    /// untyped dictionary and read each value via the Double cast path.
    private static func loadAngleDict(defaults: UserDefaults, key: String) -> [String: Double] {
        guard let raw = defaults.dictionary(forKey: key) else { return [:] }
        var result: [String: Double] = [:]
        for (k, v) in raw {
            if let d = v as? Double {
                result[k] = d
            } else if let n = v as? NSNumber {
                result[k] = n.doubleValue
            }
        }
        return result
    }

    func save() {
        defaults.set(triggerType.rawValue, forKey: "triggerType")
        defaults.set(inputMode.rawValue, forKey: "inputMode")
        defaults.set(Int(keyCode), forKey: "keyCode")
        defaults.set(Int(modifiers), forKey: "modifiers")
        defaults.set(keyDisplayName, forKey: "keyDisplayName")
        defaults.set(mouseButton, forKey: "mouseButton")
        defaults.set(edgeActivation, forKey: "edgeActivation")
        defaults.set(pinnedBundleIds, forKey: "pinnedBundleIds")
        defaults.set(Array(excludedBundleIds), forKey: "excludedBundleIds")
        defaults.set(dictationEnabled, forKey: "dictationEnabled")
        defaults.set(dictationSilenceTriggerSeconds, forKey: "dictationSilenceTriggerSeconds")
        defaults.set(pinnedPreferredAngles, forKey: "pinnedAngles")
        if let angle = dictationPreferredAngle {
            defaults.set(angle, forKey: "dictationAngle")
        } else {
            defaults.removeObject(forKey: "dictationAngle")
        }
        if let uid = dictationInputDeviceUID {
            defaults.set(uid, forKey: "dictationInputDeviceUID")
        } else {
            defaults.removeObject(forKey: "dictationInputDeviceUID")
        }
    }

    // MARK: - Layout angles

    /// All currently known anchored angles in one flat list (pinned apps +
    /// the dictation tile). Used by the default-placement algorithm when
    /// adding a new anchor.
    var allPreferredAngles: [Double] {
        var all = Array(pinnedPreferredAngles.values)
        if let angle = dictationPreferredAngle {
            all.append(angle)
        }
        return all
    }

    /// Ensures every currently-pinned bundle id, and the dictation tile when
    /// enabled, has a stored preferred direction. Newly seen items get the
    /// center of the largest currently-empty arc, then auto-save. A preference
    /// is a direction the ring solver aims for, not a fixed position: the item
    /// lands on whichever free slot sits closest to it.
    func ensurePreferredAngles() {
        var changed = false

        for bundleId in pinnedBundleIds where pinnedPreferredAngles[bundleId] == nil {
            let angle = RingLayout.nextAnchorAngle(existingAngles: allPreferredAngles)
            pinnedPreferredAngles[bundleId] = angle
            changed = true
        }

        if dictationEnabled, dictationPreferredAngle == nil {
            dictationPreferredAngle = RingLayout.nextAnchorAngle(existingAngles: allPreferredAngles)
            changed = true
        }

        // Prune angles for bundles that are no longer pinned so the
        // dictionary doesn't grow unbounded over time.
        let pinnedSet = Set(pinnedBundleIds)
        for key in pinnedPreferredAngles.keys where !pinnedSet.contains(key) {
            pinnedPreferredAngles.removeValue(forKey: key)
            changed = true
        }

        if changed { save() }
    }

    /// Wipes all stored angles; next `ensurePreferredAngles` call reassigns
    /// defaults for the current pinned set and the dictation tile.
    func resetLayoutAngles() {
        pinnedPreferredAngles = [:]
        dictationPreferredAngle = nil
        save()
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
