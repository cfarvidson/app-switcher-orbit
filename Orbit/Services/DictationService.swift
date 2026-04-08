import AppKit
import Carbon
import CoreGraphics
import Foundation
import os

/// Reads and writes macOS built-in Dictation state via undocumented plist keys
/// (verified on macOS 15.7.4 against tom-barone/dotfiles, benthamite/dotfiles,
/// and ntkme/Swift-Dictation), and starts dictation by synthesizing the user's
/// configured dictation shortcut via the deprecated `CGPostKeyboardEvent`.
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

    /// The user's configured dictation shortcut: virtual key code + modifier
    /// virtual key codes that need to be held while pressing it. Returns nil
    /// when no usable shortcut is configured (i.e. the user is on the default
    /// "Press Fn twice", which cannot be synthesized — see Apple Feedback
    /// FB9093710).
    ///
    /// Reads `CustomizedDictationHotKey` first, then falls back to
    /// `AppleSymbolicHotKeys[164]`, both of which encode the same shortcut in
    /// different places.
    static func dictationShortcut() -> (virtualKey: UInt16, modifierKeys: [UInt16])? {
        let prefs = UserDefaults.standard.persistentDomain(forName: prefsDomain) ?? [:]
        if let hk = prefs["CustomizedDictationHotKey"] as? [String: Any],
           let virtualKey = hk["virtualKey"] as? Int,
           let modifiers = hk["modifiers"] as? Int,
           virtualKey != unsetKeyCode
        {
            return (UInt16(virtualKey), modifierVirtualKeys(fromBitmask: modifiers))
        }
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
        return (UInt16(params[1]), modifierVirtualKeys(fromBitmask: params[2]))
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

    /// Synthesizes the user's configured dictation shortcut via the deprecated
    /// `CGPostKeyboardEvent`.
    ///
    /// Why the deprecated function and not modern `CGEvent.post`: macOS 14+
    /// specifically filters synthesized events from triggering the Dictation
    /// SymbolicHotKey as a microphone-privacy protection. The filter applies to
    /// every modern injection path I tested — `.cghidEventTap`,
    /// `.cgSessionEventTap`, and AppleScript `System Events` key codes alike.
    /// `CGPostKeyboardEvent` predates the modern event-source state machine and
    /// goes through an older injection path that the filter doesn't gate;
    /// DictationIM logs `start listening by user action` when invoked this way.
    /// Verified empirically on macOS 15.7.4. Apple may close this gap in the
    /// future, in which case `dictationShortcut()` will still return the right
    /// shortcut and the warning logging here will surface the regression.
    static func startDictation() {
        guard let shortcut = dictationShortcut() else {
            NSLog("[Orbit.dictation] startDictation aborted — no usable shortcut")
            log.warning("Cannot start dictation — no usable shortcut configured (likely on 'Press Fn twice')")
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        NSLog("[Orbit.dictation] startDictation posting vk=\(shortcut.virtualKey) mods=\(shortcut.modifierKeys) frontmost=\(front)")
        // Press modifiers, press key, release key, release modifiers in reverse.
        for modifier in shortcut.modifierKeys {
            CGPostKeyboardEvent(0, modifier, true)
        }
        CGPostKeyboardEvent(0, shortcut.virtualKey, true)
        CGPostKeyboardEvent(0, shortcut.virtualKey, false)
        for modifier in shortcut.modifierKeys.reversed() {
            CGPostKeyboardEvent(0, modifier, false)
        }
    }

    /// Full flow: switch language if it differs from the current one, then
    /// start dictation. Uses a 350ms delay only when a DictationIM restart was
    /// triggered (cold-relaunch latency); 50ms on the fast path so the previous
    /// app has had time to fully regain focus before the synthesized shortcut
    /// fires.
    static func switchLanguageAndStart(_ localeId: String) {
        let didRestart = setLanguage(localeId)
        let delay: TimeInterval = didRestart ? 0.35 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            startDictation()
        }
    }

    // MARK: - Helpers

    /// Maps an NSEvent-style modifier bitmask to the virtual key codes of the
    /// modifier keys we need to hold while posting the main key. Order matches
    /// the bit order so the released sequence is the reverse of the pressed
    /// sequence.
    private static func modifierVirtualKeys(fromBitmask raw: Int) -> [UInt16] {
        var keys: [UInt16] = []
        if raw & 0x040000 != 0 { keys.append(UInt16(kVK_Control)) }
        if raw & 0x080000 != 0 { keys.append(UInt16(kVK_Option)) }
        if raw & 0x020000 != 0 { keys.append(UInt16(kVK_Shift)) }
        if raw & 0x100000 != 0 { keys.append(UInt16(kVK_Command)) }
        return keys
    }
}

/// Deprecated Quartz API still exported by CoreGraphics. Predates the modern
/// `CGEvent.post` filter that blocks synthesized events from triggering the
/// Dictation SymbolicHotKey. Not declared in Swift's `CoreGraphics` module so
/// we declare it ourselves with `@_silgen_name`.
@_silgen_name("CGPostKeyboardEvent")
private func CGPostKeyboardEvent(_ keyChar: UInt16, _ virtualKey: UInt16, _ keyDown: Bool) -> Int32
