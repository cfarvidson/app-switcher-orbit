import AppKit
import CoreGraphics
import Foundation
import os

/// Reads and writes macOS built-in Dictation state via undocumented plist keys,
/// verified on macOS 15.7.4 and cross-referenced against open-source tools.
///
/// All key names and daemon targets are documented in
/// `docs/plans/2026-04-08-feat-dictation-language-switcher-plan.md`. If any key
/// disappears in a future macOS release, failures are non-fatal and logged via
/// `os.Logger`; the feature is opt-in and can be disabled in Settings.
enum DictationService {
    private static let log = Logger(subsystem: "com.orbit.appswitcher", category: "dictation")
    private static let prefsDomain = "com.apple.speech.recognition.AppleSpeechRecognition.prefs"
    private static let symbolicHotkeysDomain = "com.apple.symbolichotkeys"
    private static let ironwoodBundleId = "com.apple.inputmethod.ironwood"
    private static let dictationSymbolicHotkeyId = "164"
    private static let unsetKeyCode = 65535

    // MARK: - Reading

    /// Locales the user has enabled in System Settings → Keyboard → Dictation.
    ///
    /// Reads `VisibleNetworkSRLocaleIdentifiers` (Dict<String, Int>) and keeps
    /// only entries whose value is 1. Preserves the user's preferred ordering
    /// via `DictationIMPreferredLanguageIdentifiers` when possible.
    static func enabledLocales() -> [DictationLanguage] {
        let prefs = UserDefaults.standard.persistentDomain(forName: prefsDomain) ?? [:]
        let visible = prefs["VisibleNetworkSRLocaleIdentifiers"] as? [String: Int] ?? [:]
        let enabled = Set(visible.filter { $0.value == 1 }.map { $0.key })
        guard !enabled.isEmpty else { return [] }
        let preferredOrder = prefs["DictationIMPreferredLanguageIdentifiers"] as? [String] ?? []
        var ordered: [String] = preferredOrder.filter { enabled.contains($0) }
        let remaining = enabled.subtracting(ordered).sorted()
        ordered.append(contentsOf: remaining)
        return ordered.map(DictationLanguage.from(localeId:))
    }

    /// The currently active dictation language, or nil if unset.
    static func currentLanguage() -> String? {
        let prefs = UserDefaults.standard.persistentDomain(forName: prefsDomain) ?? [:]
        return prefs["DictationIMNetworkBasedLocaleIdentifier"] as? String
    }

    /// The user's configured dictation shortcut.
    ///
    /// Returns nil when the shortcut is unset, explicitly disabled, or still on
    /// the default "Press Fn twice" (Apple Feedback FB9093710 confirms Fn cannot
    /// be synthesized via CGEvent).
    static func dictationShortcut() -> (virtualKey: CGKeyCode, flags: CGEventFlags)? {
        let prefs = UserDefaults.standard.persistentDomain(forName: prefsDomain) ?? [:]
        if let hk = prefs["CustomizedDictationHotKey"] as? [String: Any],
           let virtualKey = hk["virtualKey"] as? Int,
           let modifiers = hk["modifiers"] as? Int,
           virtualKey != unsetKeyCode
        {
            return (CGKeyCode(virtualKey), CGEventFlags(rawValue: UInt64(modifiers)))
        }
        // Fallback: read AppleSymbolicHotKeys[164] directly.
        let symbolic = UserDefaults.standard.persistentDomain(forName: symbolicHotkeysDomain) ?? [:]
        guard let hotkeys = symbolic["AppleSymbolicHotKeys"] as? [String: Any],
              let entry = hotkeys[dictationSymbolicHotkeyId] as? [String: Any],
              (entry["enabled"] as? Int ?? 0) == 1,
              let value = entry["value"] as? [String: Any],
              let params = value["parameters"] as? [Int],
              params.count == 3,
              params[1] != unsetKeyCode
        else {
            return nil
        }
        return (CGKeyCode(params[1]), CGEventFlags(rawValue: UInt64(params[2])))
    }

    // MARK: - Writing

    /// Writes the active language to `DictationIMNetworkBasedLocaleIdentifier`
    /// and reorders `DictationIMPreferredLanguageIdentifiers` so the target is
    /// first. Gracefully terminates `DictationIM`; `launchd` respawns it on
    /// demand when the next shortcut hits its MachService.
    ///
    /// Returns `true` when a restart was triggered, `false` when the target was
    /// already active (fast path).
    @discardableResult
    static func setLanguage(_ localeId: String) -> Bool {
        if currentLanguage() == localeId {
            return false
        }

        var prefs = UserDefaults.standard.persistentDomain(forName: prefsDomain) ?? [:]
        prefs["DictationIMNetworkBasedLocaleIdentifier"] = localeId
        var preferred = prefs["DictationIMPreferredLanguageIdentifiers"] as? [String] ?? [localeId]
        preferred.removeAll { $0 == localeId }
        preferred.insert(localeId, at: 0)
        prefs["DictationIMPreferredLanguageIdentifiers"] = preferred
        UserDefaults.standard.setPersistentDomain(prefs, forName: prefsDomain)

        // Verify the write — early warning for future macOS key renames.
        let verified = UserDefaults.standard
            .persistentDomain(forName: prefsDomain)?["DictationIMNetworkBasedLocaleIdentifier"] as? String
        if verified != localeId {
            log.error("setLanguage verification failed: wrote \(localeId, privacy: .public) but read \(verified ?? "nil", privacy: .public)")
        }

        for app in NSRunningApplication.runningApplications(withBundleIdentifier: ironwoodBundleId) {
            app.terminate()
        }
        return true
    }

    /// Synthesizes the user's configured dictation shortcut via `CGEvent`.
    /// No-op if no valid shortcut is configured.
    static func startDictation() {
        guard let shortcut = dictationShortcut() else {
            log.warning("Cannot start dictation — no valid shortcut configured (likely on 'Press Fn twice')")
            return
        }
        postShortcut(virtualKey: shortcut.virtualKey, flags: shortcut.flags)
    }

    /// Full flow: switch language if it differs from the current one, then
    /// start dictation. Uses a ~75ms delay only when a restart was triggered.
    static func switchLanguageAndStart(_ localeId: String) {
        let didRestart = setLanguage(localeId)
        let delay: TimeInterval = didRestart ? 0.075 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            startDictation()
        }
    }

    // MARK: - Helpers

    private static func postShortcut(virtualKey: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            log.error("Failed to create CGEventSource")
            return
        }
        let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }
}
