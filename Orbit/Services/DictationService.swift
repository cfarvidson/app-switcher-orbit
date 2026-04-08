import AppKit
import ApplicationServices
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
    private static let ironwoodBundleId = "com.apple.inputmethod.ironwood"

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

    /// Starts dictation in the frontmost app by pressing its "Start Dictation…"
    /// menu item via the Accessibility API.
    ///
    /// Why AX instead of synthesizing a keyboard shortcut: macOS 14+
    /// specifically filters synthesized events from triggering the Dictation
    /// SymbolicHotKey as a microphone-privacy protection. That filter applies
    /// to both `.cghidEventTap` and `.cgSessionEventTap` posts and to
    /// AppleScript System Events key-codes alike — none of them trigger
    /// Dictation even though they work for every other global shortcut we
    /// tested. Walking the menu bar via AX and performing `AXPressAction` on
    /// the Start Dictation menu item bypasses the filter because it invokes
    /// the real menu action rather than simulating a keystroke.
    ///
    /// Important subtlety: NSMenuItem targets are resolved lazily. Pressing a
    /// menu item whose parent menu has never been opened reports success but
    /// fires no action. We work around this by pressing the Edit menu bar
    /// item first (which shows the dropdown and causes NSMenu to wire up its
    /// items), then pressing Start Dictation inside it. AX subsequently
    /// auto-closes the menu once the press fires, so the visible flash is
    /// brief.
    static func startDictation() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        var menuBarRef: CFTypeRef?
        let menuBarErr = AXUIElementCopyAttributeValue(
            appElement,
            kAXMenuBarAttribute as CFString,
            &menuBarRef
        )
        guard menuBarErr == .success, let menuBarRaw = menuBarRef else {
            log.warning("AX menu bar lookup failed for \(frontApp.localizedName ?? "?", privacy: .public) err=\(menuBarErr.rawValue)")
            return
        }
        let menuBar = menuBarRaw as! AXUIElement

        guard let editMenu = firstChild(of: menuBar, matching: isEditMenuTitle) else {
            log.warning("No Edit menu in \(frontApp.localizedName ?? "?", privacy: .public)")
            return
        }

        // Open the Edit menu first — menu item targets are resolved lazily.
        guard AXUIElementPerformAction(editMenu, kAXPressAction as CFString) == .success,
              let editDropdown = firstChild(of: editMenu, matchingRole: kAXMenuRole),
              let dictationItem = firstChild(of: editDropdown, matching: isDictationTitle)
        else {
            log.warning("Could not locate Start Dictation in Edit menu of \(frontApp.localizedName ?? "?", privacy: .public)")
            AXUIElementPerformAction(editMenu, kAXCancelAction as CFString)
            return
        }

        let pressResult = AXUIElementPerformAction(dictationItem, kAXPressAction as CFString)
        if pressResult != .success {
            log.error("AXPressAction on Start Dictation failed: err=\(pressResult.rawValue)")
        }
    }

    /// Full flow: switch language if it differs from the current one, then
    /// start dictation via the menu walk. A 350ms delay after a DictationIM
    /// restart gives the daemon time to relaunch before the menu action fires.
    static func switchLanguageAndStart(_ localeId: String) {
        let didRestart = setLanguage(localeId)
        let delay: TimeInterval = didRestart ? 0.35 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            startDictation()
        }
    }

    // MARK: - AX Helpers

    private static func axAttribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return result == .success ? value : nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        (axAttribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func firstChild(
        of element: AXUIElement,
        matching predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        children(of: element).first(where: predicate)
    }

    private static func firstChild(of element: AXUIElement, matchingRole role: String) -> AXUIElement? {
        firstChild(of: element) { child in
            (axAttribute(child, kAXRoleAttribute) as? String) == role
        }
    }

    /// Matches the Edit menu across localizations. Matching by title substring
    /// isn't fully locale-proof, but the menu item in question is part of the
    /// standard NSApplication menu set and uses the host's system language,
    /// which for our user is English. Extend the `editTitles` array for
    /// additional localizations as needed.
    private static func isEditMenuTitle(_ element: AXUIElement) -> Bool {
        guard let title = axAttribute(element, kAXTitleAttribute) as? String else { return false }
        let editTitles = ["Edit", "Redigera", "Rediger", "Redigeren", "Bearbeiten", "Modifier", "Modifica", "Editar", "Edytuj"]
        return editTitles.contains(title)
    }

    /// Matches "Start Dictation…" across common localizations. Case-insensitive
    /// substring match on a small set of stems covers the languages Orbit users
    /// are most likely to run with.
    private static func isDictationTitle(_ element: AXUIElement) -> Bool {
        guard let title = (axAttribute(element, kAXTitleAttribute) as? String)?.lowercased() else {
            return false
        }
        let stems = ["dictation", "diktering", "diktat", "dettatura", "dictée", "dictado", "diktering", "diktat"]
        return stems.contains { title.contains($0) }
    }
}
