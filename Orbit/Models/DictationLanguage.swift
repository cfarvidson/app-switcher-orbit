import Foundation

/// A dictation locale as exposed by macOS built-in Dictation.
///
/// The `id` uses the underscore format written by `DictationIM` into
/// `com.apple.speech.recognition.AppleSpeechRecognition.prefs` (e.g. `"en_US"`,
/// `"sv_SE"`, `"zh-Hans_CN"`). When bridging to Foundation's `Locale`, convert
/// the underscore to a hyphen first.
struct DictationLanguage: Identifiable, Equatable, Codable {
    let id: String
    let displayName: String
    let flagEmoji: String

    /// Build a `DictationLanguage` from an underscore-format locale id.
    static func from(localeId: String) -> DictationLanguage {
        let hyphenated = localeId.replacingOccurrences(of: "_", with: "-")
        let displayName = Locale.current.localizedString(forIdentifier: hyphenated)
            ?? Locale.current.localizedString(forIdentifier: localeId)
            ?? localeId
        return DictationLanguage(
            id: localeId,
            displayName: displayName,
            flagEmoji: flagEmoji(for: localeId)
        )
    }

    /// Parse the region subtag (e.g. `"SE"` from `"sv_SE"`) and map it to a
    /// regional-indicator flag emoji. Falls back to a white flag for locales
    /// without a parseable two-letter region.
    private static func flagEmoji(for localeId: String) -> String {
        guard let region = localeId.split(separator: "_").last,
              region.count == 2
        else {
            return "🏳️"
        }
        let base: UInt32 = 127397 // Regional Indicator Symbol Letter A − ASCII 'A'
        var result = ""
        for scalar in region.uppercased().unicodeScalars {
            if let flagScalar = UnicodeScalar(base + scalar.value) {
                result.unicodeScalars.append(flagScalar)
            }
        }
        return result.isEmpty ? "🏳️" : result
    }
}
