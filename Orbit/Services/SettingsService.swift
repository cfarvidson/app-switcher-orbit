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
    @Published var dictationLanguage1Id: String?
    @Published var dictationLanguage2Id: String?
    @Published var dictationModelName: String
    @Published var pinnedAngles: [String: Double]
    @Published var languageAngles: [String: Double]
    @Published var translateTileEnabled: Bool
    @Published var translateSourceLocaleId: String
    @Published var translateAngle: Double?
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
        dictationLanguage1Id = defaults.string(forKey: "dictationLanguage1Id")
        dictationLanguage2Id = defaults.string(forKey: "dictationLanguage2Id")
        dictationModelName = SettingsService.sanitizeModelName(
            defaults.string(forKey: "dictationModelName")
        )
        pinnedAngles = SettingsService.loadAngleDict(defaults: defaults, key: "pinnedAngles")
        languageAngles = SettingsService.loadAngleDict(defaults: defaults, key: "languageAngles")
        translateTileEnabled = defaults.object(forKey: "translateTileEnabled") != nil
            ? defaults.bool(forKey: "translateTileEnabled")
            : false
        translateSourceLocaleId = defaults.string(forKey: "translateSourceLocaleId") ?? "sv_SE"
        translateAngle = defaults.object(forKey: "translateAngle") as? Double
        dictationInputDeviceUID = defaults.string(forKey: "dictationInputDeviceUID")
    }

    /// Maps any saved model name to a known-valid one. Migrates users who
    /// had the old buggy `openai_whisper-large-v3-turbo` (which never
    /// existed in WhisperKit's HuggingFace repo) to the recommended
    /// `openai_whisper-small`. Unknown names also fall back to small so
    /// the picker never shows an empty selection.
    private static func sanitizeModelName(_ raw: String?) -> String {
        let validModels: Set<String> = [
            "openai_whisper-tiny",
            "openai_whisper-base",
            "openai_whisper-small",
            "openai_whisper-medium",
            "openai_whisper-large-v3-v20240930",
            "openai_whisper-large-v3",
        ]
        guard let name = raw, validModels.contains(name) else {
            return "openai_whisper-small"
        }
        return name
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
        defaults.set(dictationLanguage1Id, forKey: "dictationLanguage1Id")
        defaults.set(dictationLanguage2Id, forKey: "dictationLanguage2Id")
        defaults.set(dictationModelName, forKey: "dictationModelName")
        defaults.set(pinnedAngles, forKey: "pinnedAngles")
        defaults.set(languageAngles, forKey: "languageAngles")
        defaults.set(translateTileEnabled, forKey: "translateTileEnabled")
        defaults.set(translateSourceLocaleId, forKey: "translateSourceLocaleId")
        if let angle = translateAngle {
            defaults.set(angle, forKey: "translateAngle")
        } else {
            defaults.removeObject(forKey: "translateAngle")
        }
        if let uid = dictationInputDeviceUID {
            defaults.set(uid, forKey: "dictationInputDeviceUID")
        } else {
            defaults.removeObject(forKey: "dictationInputDeviceUID")
        }
    }

    // MARK: - Layout angles

    /// All currently known anchored angles in one flat list (pinned + languages + translate).
    /// Used by the default-placement algorithm when adding a new anchor.
    var allAnchorAngles: [Double] {
        var all = Array(pinnedAngles.values) + Array(languageAngles.values)
        if let angle = translateAngle {
            all.append(angle)
        }
        return all
    }

    /// Ensures every currently-pinned bundle id and every configured language
    /// has a stored angle. Newly seen items are placed at the center of the
    /// largest currently-empty arc (Hitman weapon-wheel style), then
    /// auto-saved. Called on every ring show so the storage is always in
    /// sync with the user's pin/language selections.
    func ensureAnchorAngles(for languages: [DictationLanguage]) {
        var changed = false

        for bundleId in pinnedBundleIds where pinnedAngles[bundleId] == nil {
            let angle = RingLayout.nextAnchorAngle(existingAngles: allAnchorAngles)
            pinnedAngles[bundleId] = angle
            changed = true
        }

        for language in languages where languageAngles[language.id] == nil {
            let angle = RingLayout.nextAnchorAngle(existingAngles: allAnchorAngles)
            languageAngles[language.id] = angle
            changed = true
        }

        // Translate tile gets an angle the first time it becomes enabled,
        // using the same next-empty-arc algorithm as language tiles.
        if translatePair != nil, translateAngle == nil {
            translateAngle = RingLayout.nextAnchorAngle(existingAngles: allAnchorAngles)
            changed = true
        }

        // Prune angles for bundles/locales that are no longer anchored so
        // the dictionaries don't grow unbounded over time.
        let pinnedSet = Set(pinnedBundleIds)
        for key in pinnedAngles.keys where !pinnedSet.contains(key) {
            pinnedAngles.removeValue(forKey: key)
            changed = true
        }
        let languageSet = Set(languages.map { $0.id })
        for key in languageAngles.keys where !languageSet.contains(key) {
            languageAngles.removeValue(forKey: key)
            changed = true
        }

        if changed { save() }
    }

    /// Wipes all stored angles; next `ensureAnchorAngles` call reassigns
    /// defaults for the current pinned+language set.
    func resetLayoutAngles() {
        pinnedAngles = [:]
        languageAngles = [:]
        save()
    }

    /// Resolved dictation language tiles for the ring. Empty when disabled or
    /// no languages are configured.
    var dictationLanguages: [DictationLanguage] {
        guard dictationEnabled else { return [] }
        return [dictationLanguage1Id, dictationLanguage2Id]
            .compactMap { $0 }
            .map(DictationLanguage.from(localeId:))
    }

    /// The currently configured translate pair, or nil when the toggle is
    /// off, no source has been chosen, or the chosen source is no longer
    /// enabled in System Settings → Keyboard → Dictation. Target is the
    /// user's preferred enabled `en_*` variant, falling back to a hardcoded
    /// `en_US` so the tile still has a flag to render even if no English
    /// locale is enabled (Whisper does not consult system prefs).
    var translatePair: TranslatePair? {
        guard translateTileEnabled else { return nil }
        let enabled = DictationService.enabledLocales()
        guard let source = enabled.first(where: { $0.id == translateSourceLocaleId }) else {
            return nil
        }
        let target = enabled.first(where: { $0.id.hasPrefix("en") })
            ?? DictationLanguage.from(localeId: "en_US")
        return TranslatePair(source: source, target: target)
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
