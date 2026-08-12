import AppKit
import Foundation
import os

/// Manages the macOS Dictation language preference and triggers Orbit's
/// in-process speech recognition (`SpeechRecognitionService`).
///
/// History: an earlier version of this file synthesized the user's
/// configured dictation shortcut via `CGPostKeyboardEvent` to start macOS's
/// built-in DictationIM. That approach was abandoned after extensive testing
/// because DictationIM consistently died ~1.4s after start with `(null)`
/// errors, the locale cache required process kills that created
/// kill/respawn windows where posts were dropped, and the whole undocumented
/// surface was fragile. We now run OpenAI Whisper locally via WhisperKit
/// (CoreML on Apple Silicon) entirely in-process — see
/// `SpeechRecognitionService`.
///
/// We still write the macOS Dictation language prefs in `setLanguage` so
/// that the user's *physical* dictation shortcut (configured in System
/// Settings) honors the language Orbit just set — even though Orbit's own
/// recognition runs independently.
///
/// Plist surface (verified on macOS 15.7.4):
/// - Domain: `com.apple.speech.recognition.AppleSpeechRecognition.prefs`
/// - Active language: `DictationIMNetworkBasedLocaleIdentifier` (String, e.g. `"en_GB"`)
/// - Preference order: `DictationIMPreferredLanguageIdentifiers` (Array<String>)
/// - Enabled locales: `VisibleNetworkSRLocaleIdentifiers` (Dict<String, Int>)
enum DictationService {
    private static let log = Logger(subsystem: "com.orbit.appswitcher", category: "dictation")
    private static let prefsDomain = "com.apple.speech.recognition.AppleSpeechRecognition.prefs"

    // MARK: - Reading

    /// Locales the user has enabled in System Settings → Keyboard → Dictation.
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

    // MARK: - Writing

    /// Updates the macOS Dictation language preference to keep the system in
    /// sync with Orbit's choice. This is purely cosmetic for our own
    /// recognition (which runs WhisperKit directly with the locale we pass
    /// it), but ensures the user's physical dictation shortcut honors the
    /// same language they just selected in the ring.
    static func setLanguage(_ localeId: String) {
        guard currentLanguage() != localeId else { return }

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
    }

    /// Switches the system Dictation language and starts in-process speech
    /// recognition in the chosen locale. The two are independent — the
    /// language switch is for the system, recognition runs entirely in
    /// Orbit via WhisperKit.
    static func switchLanguageAndStart(_ localeId: String) {
        setLanguage(localeId)
        SpeechRecognitionService.shared.startDictation(localeId: localeId) { errorMessage in
            NSLog("[Orbit.dictation] speech start failed: \(errorMessage)")
        }
    }
}
