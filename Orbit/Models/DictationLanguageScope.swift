import FluidAudio
import Foundation

/// Translates the user's selected dictation languages into the single
/// `Language?` hint FluidAudio's decoder accepts.
///
/// The underlying filter is script-level, not language-level: it partitions
/// languages into Latin / Cyrillic / Greek and skips decoder tokens whose
/// script does not match. There is no way to express "English and Swedish but
/// not German", so this maps a set onto the one value that best represents it.
///
/// The subtlety that drives the rules below: `TdtDecoderV3` additionally runs
/// an English blocklist whenever the hint is a Latin language other than
/// English, actively replacing English tokens. That is right for someone who
/// never speaks English and wrong for someone who code-switches, so English
/// wins the tie whenever it is selected.
enum DictationLanguageScope {

    /// Every language code Parakeet supports.
    static var supportedCodes: Set<String> {
        Set(Language.allCases.map(\.rawValue))
    }

    /// The hint for a selection, or nil when no filtering should apply.
    static func hint(for codes: Set<String>) -> Language? {
        let languages = codes.compactMap { Language(rawValue: $0) }
        guard !languages.isEmpty else { return nil }

        // A mixed-script selection has no representable hint. Picking one
        // script would silently discard half the user's answer, so filtering
        // is switched off instead. The Settings UI says so explicitly.
        let scripts = Set(languages.map(\.script))
        guard scripts.count == 1, let script = scripts.first else { return nil }

        switch script {
        case .latin:
            // English suppresses nothing; any other Latin language triggers
            // the decoder's English blocklist.
            if languages.contains(.english) { return .english }
            return languages.min { $0.rawValue < $1.rawValue }
        case .cyrillic, .greek:
            // The blocklist is Latin-only, so the choice within the script
            // does not affect behavior. Lowest rawValue for determinism.
            return languages.min { $0.rawValue < $1.rawValue }
        }
    }
}
