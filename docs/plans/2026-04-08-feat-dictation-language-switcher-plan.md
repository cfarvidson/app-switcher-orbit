---
title: Dictation Language Switcher in Orbit Ring
type: feat
date: 2026-04-08
---

# Dictation Language Switcher in Orbit Ring

## Overview

Add two dictation-language tiles to the existing Orbit radial ring. Selecting a tile switches the macOS built-in Dictation language to that locale and immediately starts dictation in the previously focused text field. Feature is opt-in via a new **Dictation** settings tab and sits at the very start of the ring for muscle memory.

## Problem Statement / Motivation

The user dictates in two languages (e.g., English and Swedish) and wants a single action that both switches the active macOS dictation language and starts dictation in the currently focused field. Today this requires opening System Settings → Keyboard → Dictation → Languages, picking a language, closing System Settings, then triggering dictation — a workflow that's slow enough to discourage mid-sentence language switches.

The existing Orbit radial ring is already the user's fast-switcher muscle memory for apps. Reusing the same trigger and ring for language switching means no new hotkey to learn and immediate adoption of the feature.

## Proposed Solution

Three additions to the existing Orbit architecture:

1. **`DictationService`** — a new stateless enum encapsulating all undocumented-API work: reading enabled locales, writing the active language, terminating the `DictationIM` input method so launchd reloads it, reading the user's configured dictation shortcut, and synthesizing it via `CGEvent`.
2. **`OrbitItem` model + `LanguageTileView`** — the ring's content type generalizes from `[RunningApp]` to `[OrbitItem]`, a sum type over apps and languages. A new tile view mirrors `AppIconView` but renders a flag emoji with a locale-code badge.
3. **Settings "Dictation" tab** — a new fourth tab where the user enables the feature, picks two languages from their System-Settings-enabled dictation locales, and is warned if their Dictation shortcut is missing or set to the un-synthesizable "Press Fn twice".

The feature is disabled by default because it writes to undocumented preference keys. When disabled, Orbit behaves identically to today.

## Technical Approach

### Research-verified API surface

All plist domains, keys, and daemon targets below were verified against a live macOS 15.7.4 machine and cross-referenced against tom-barone/dotfiles, benthamite/dotfiles, and ntkme/Swift-Dictation. See the `best-practices-researcher` findings in the April 8 brainstorm session for sources and caveats.

| Concern                   | Location                                                                                                                                                                                         |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Active dictation language | `com.apple.speech.recognition.AppleSpeechRecognition.prefs` → `DictationIMNetworkBasedLocaleIdentifier` (String)                                                                                 |
| Preference order          | Same domain → `DictationIMPreferredLanguageIdentifiers` (Array<String>) — must be reordered so target is first                                                                                   |
| Enabled locales           | Same domain → `VisibleNetworkSRLocaleIdentifiers` (Dict<String, Int>, value `1` = enabled)                                                                                                       |
| User's dictation shortcut | Same domain → `CustomizedDictationHotKey` (Dict: `keyChar`, `virtualKey`, `modifiers` — NSEvent-style bitmask). Fallback: `com.apple.symbolichotkeys.plist` → `AppleSymbolicHotKeys` → key `164` |
| Daemon to restart         | `com.apple.inputmethod.ironwood` (DictationIM.app), via graceful `NSRunningApplication.terminate()`. **Not `corespeechd`.**                                                                      |
| Locale format             | Underscore (`en_US`, `sv_SE`, `zh-Hans_CN`) — not hyphen                                                                                                                                         |

Known dead end: the default "Press Fn twice" shortcut cannot be synthesized via `CGEvent` (Apple Feedback FB9093710, still open). The plan handles this explicitly.

### Files to create

```
Orbit/Models/DictationLanguage.swift     (new)
Orbit/Models/OrbitItem.swift              (new)
Orbit/Services/DictationService.swift    (new)
Orbit/Views/LanguageTileView.swift       (new)
```

### Files to modify

```
Orbit/Services/SettingsService.swift     (+ 3 @Published properties + save/load)
Orbit/ViewModels/OrbitViewModel.swift    (rename apps → items; widen to OrbitItem; branch in selectAndSwitch)
Orbit/Views/OrbitView.swift              (ForEach switches on OrbitItem; update label)
Orbit/Views/SettingsView.swift           (add 4th tab)
SPEC.md                                   (update after implementation)
```

### Data model

```swift
// Orbit/Models/DictationLanguage.swift
import Foundation

struct DictationLanguage: Identifiable, Equatable, Codable {
    let id: String          // e.g. "en_US" — underscore format, matches plist
    let displayName: String // e.g. "English (US)"
    let flagEmoji: String   // e.g. "🇺🇸"

    /// Build from an underscore-format locale id read out of
    /// DictationIMPreferredLanguageIdentifiers / VisibleNetworkSRLocaleIdentifiers.
    static func from(localeId: String) -> DictationLanguage {
        let displayName = Locale(identifier: localeId.replacingOccurrences(of: "_", with: "-"))
            .localizedString(forIdentifier: localeId) ?? localeId
        return DictationLanguage(
            id: localeId,
            displayName: displayName,
            flagEmoji: flagEmoji(for: localeId)
        )
    }

    /// Parse "en_US" → "US" → 🇺🇸 via regional indicator symbols.
    private static func flagEmoji(for localeId: String) -> String {
        // Grab the region after the underscore; fall back to "?" if missing.
        guard let region = localeId.split(separator: "_").last,
              region.count == 2 else {
            return "🏳️"
        }
        let base: UInt32 = 127397 // 🇦 (regional indicator A) base
        var scalar = ""
        for ch in region.uppercased().unicodeScalars {
            if let combined = UnicodeScalar(base + ch.value) {
                scalar.unicodeScalars.append(combined)
            }
        }
        return scalar.isEmpty ? "🏳️" : scalar
    }
}
```

```swift
// Orbit/Models/OrbitItem.swift
import Foundation

enum OrbitItem: Identifiable, Equatable {
    case app(RunningApp)
    case language(DictationLanguage)

    var id: String {
        switch self {
        case .app(let app): return "app:\(app.id)"
        case .language(let lang): return "lang:\(lang.id)"
        }
    }

    var displayName: String {
        switch self {
        case .app(let app): return app.name
        case .language(let lang): return lang.displayName
        }
    }
}
```

### DictationService

```swift
// Orbit/Services/DictationService.swift
import AppKit
import CoreGraphics
import Foundation
import os

enum DictationService {
    private static let log = Logger(subsystem: "com.orbit.appswitcher", category: "dictation")
    private static let prefsDomain = "com.apple.speech.recognition.AppleSpeechRecognition.prefs"
    private static let ironwoodBundleId = "com.apple.inputmethod.ironwood"

    // MARK: - Reading

    /// Locales the user has enabled in System Settings → Keyboard → Dictation → Languages.
    static func enabledLocales() -> [DictationLanguage] {
        let prefs = UserDefaults.standard.persistentDomain(forName: prefsDomain) ?? [:]
        let visible = prefs["VisibleNetworkSRLocaleIdentifiers"] as? [String: Int] ?? [:]
        let enabled = visible.filter { $0.value == 1 }.map { $0.key }
        // Preserve preferred-order when possible, else sorted.
        let order = (prefs["DictationIMPreferredLanguageIdentifiers"] as? [String]) ?? []
        let ordered = order.filter { enabled.contains($0) } + enabled.filter { !order.contains($0) }.sorted()
        return ordered.map(DictationLanguage.from(localeId:))
    }

    /// The active dictation language, if set.
    static func currentLanguage() -> String? {
        let prefs = UserDefaults.standard.persistentDomain(forName: prefsDomain) ?? [:]
        return prefs["DictationIMNetworkBasedLocaleIdentifier"] as? String
    }

    /// The user's configured dictation shortcut, or nil if unset / set to "Press Fn twice".
    /// Returns nil (rather than throwing) because the caller has a sensible fallback —
    /// still switching the language but skipping the start-dictation step.
    static func dictationShortcut() -> (virtualKey: CGKeyCode, flags: CGEventFlags)? {
        let prefs = UserDefaults.standard.persistentDomain(forName: prefsDomain) ?? [:]
        if let hk = prefs["CustomizedDictationHotKey"] as? [String: Any],
           let vk = hk["virtualKey"] as? Int,
           let raw = hk["modifiers"] as? Int,
           vk != 65535 {
            return (CGKeyCode(vk), CGEventFlags(rawValue: UInt64(raw)))
        }
        // Fallback: AppleSymbolicHotKeys[164]
        let symbolic = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys") ?? [:]
        if let hotkeys = symbolic["AppleSymbolicHotKeys"] as? [String: Any],
           let entry = hotkeys["164"] as? [String: Any],
           (entry["enabled"] as? Int ?? 0) == 1,
           let value = entry["value"] as? [String: Any],
           let params = value["parameters"] as? [Int],
           params.count == 3,
           params[1] != 65535 {
            return (CGKeyCode(params[1]), CGEventFlags(rawValue: UInt64(params[2])))
        }
        return nil
    }

    // MARK: - Writing

    /// Writes the active language and reorders the preferred-language array.
    /// Returns true if a DictationIM restart was triggered (target differed from current).
    @discardableResult
    static func setLanguage(_ localeId: String) -> Bool {
        if currentLanguage() == localeId {
            return false // fast path — no restart needed
        }

        var prefs = UserDefaults.standard.persistentDomain(forName: prefsDomain) ?? [:]
        prefs["DictationIMNetworkBasedLocaleIdentifier"] = localeId
        var preferred = (prefs["DictationIMPreferredLanguageIdentifiers"] as? [String]) ?? [localeId]
        preferred.removeAll { $0 == localeId }
        preferred.insert(localeId, at: 0)
        prefs["DictationIMPreferredLanguageIdentifiers"] = preferred
        UserDefaults.standard.setPersistentDomain(prefs, forName: prefsDomain)

        // Verify the write took effect (future macOS could rename keys).
        let verified = UserDefaults.standard
            .persistentDomain(forName: prefsDomain)?["DictationIMNetworkBasedLocaleIdentifier"] as? String
        if verified != localeId {
            log.error("setLanguage verification failed — wrote \(localeId, privacy: .public) but read \(verified ?? "nil", privacy: .public)")
        }

        // Graceful quit; launchd (ThrottleInterval=1) respawns on demand.
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: ironwoodBundleId) {
            app.terminate()
        }
        return true
    }

    /// Posts the user's dictation shortcut via CGEvent. No-op if no shortcut is configured.
    static func startDictation() {
        guard let shortcut = dictationShortcut() else {
            log.warning("No dictation shortcut configured — cannot synthesize start")
            return
        }
        postShortcut(virtualKey: shortcut.virtualKey, flags: shortcut.flags)
    }

    /// Full flow: switch language (if different) and start dictation.
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
```

Notes on the implementation:

- **Idempotent fast path.** If the requested language is already active, `setLanguage` returns `false` and `switchLanguageAndStart` fires the shortcut immediately with zero delay.
- **75ms terminate delay.** The research found that `NSRunningApplication.terminate()` is asynchronous and launchd respawns on-demand. Posting the shortcut within ~75ms gives the terminate time to propagate without noticeably delaying the user. If empirical testing shows this is too short, bump it in increments of 50ms (budget permits up to ~200ms before the click-to-mic latency becomes perceptible).
- **Verification read-back.** Writing is immediately followed by a read; a mismatch is logged. This is our early warning for future macOS versions breaking the key.
- **No `corespeechd` touch.** The old brainstorm was wrong; `corespeechd` stays up across switches.

### SettingsService additions

```swift
// added to SettingsService.swift

@Published var dictationEnabled: Bool
@Published var dictationLanguage1Id: String?  // underscore format, e.g. "en_US"
@Published var dictationLanguage2Id: String?

// in init():
dictationEnabled = defaults.object(forKey: "dictationEnabled") != nil
    ? defaults.bool(forKey: "dictationEnabled")
    : false
dictationLanguage1Id = defaults.string(forKey: "dictationLanguage1Id")
dictationLanguage2Id = defaults.string(forKey: "dictationLanguage2Id")

// in save():
defaults.set(dictationEnabled, forKey: "dictationEnabled")
defaults.set(dictationLanguage1Id, forKey: "dictationLanguage1Id")
defaults.set(dictationLanguage2Id, forKey: "dictationLanguage2Id")
```

Computed helper returning the resolved `DictationLanguage` objects (or `[]`) — used by `OrbitViewModel.buildItems()`:

```swift
var dictationLanguages: [DictationLanguage] {
    guard dictationEnabled else { return [] }
    return [dictationLanguage1Id, dictationLanguage2Id]
        .compactMap { $0 }
        .map(DictationLanguage.from(localeId:))
}
```

### OrbitViewModel changes

- Rename `@Published var apps: [RunningApp] = []` to `@Published var items: [OrbitItem] = []`.
- Introduce a private `buildItems()` method that prepends `.language` items (from `SettingsService.shared.dictationLanguages`), then pinned apps, then other apps — this preserves the "before pinned apps" decision.
- Update every `apps.count`, `apps[index]`, and `apps.isEmpty` to use `items`.
- Update `selectAndSwitch()`:
  ```swift
  func selectAndSwitch() {
      guard let index = selectedIndex, index < items.count else {
          dismiss()
          return
      }
      let item = items[index]
      dismiss()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
          switch item {
          case .app(let app):
              app.app.activate()
          case .language(let lang):
              DictationService.switchLanguageAndStart(lang.id)
          }
      }
  }
  ```
- Angle math, scroll-to-rotate, arrow navigation, sticky selection all work unchanged — they operate on `count` and `index`, not on item type.

### OrbitView changes

```swift
// Orbit/Views/OrbitView.swift (around line 43)
ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
    let position = viewModel.positionForIndex(index)
    let isSelected = viewModel.selectedIndex == index

    Group {
        switch item {
        case .app(let app):
            AppIconView(app: app, isSelected: isSelected, size: viewModel.iconSize)
        case .language(let language):
            LanguageTileView(language: language, isSelected: isSelected, size: viewModel.iconSize)
        }
    }
    .position(position)
    .onTapGesture {
        viewModel.selectedIndex = index
        viewModel.selectAndSwitch()
    }
}
```

The centered name label (OrbitView.swift:56) also updates to read from `items[index].displayName` instead of `apps[index].name`.

### LanguageTileView

```swift
// Orbit/Views/LanguageTileView.swift
import SwiftUI

struct LanguageTileView: View {
    let language: DictationLanguage
    let isSelected: Bool
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay(
                    Text(language.flagEmoji)
                        .font(.system(size: size * 0.7))
                )
                .frame(width: size, height: size)
                .shadow(
                    color: isSelected ? Color.accentColor.opacity(0.8) : .clear,
                    radius: isSelected ? 12 : 0
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
                )

            // Locale code badge (e.g. "EN", "SV")
            Text(localeCodeBadge)
                .font(.system(size: size * 0.22, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .padding(4)
        }
        .scaleEffect(isSelected ? 1.25 : 1.0)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }

    private var localeCodeBadge: String {
        // Language subtag: "en_US" → "EN", "zh-Hans_CN" → "ZH"
        let lang = language.id.split(separator: "_").first ?? ""
        return lang.split(separator: "-").first.map { $0.uppercased() } ?? ""
    }
}
```

### SettingsView — new Dictation tab

Fourth tab added after Apps. Contents:

```swift
// pseudo-sketch, inside SettingsView.swift
private var dictationTab: some View {
    Form {
        Section {
            Toggle("Show dictation languages in the ring", isOn: $settings.dictationEnabled)
                .onChange(of: settings.dictationEnabled) { settings.save() }
            Text("When on, two language tiles appear at the start of the Orbit ring. Selecting one switches the macOS Dictation language and immediately starts dictation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if settings.dictationEnabled {
            Section("Languages") {
                languagePicker(title: "Language 1", selection: $settings.dictationLanguage1Id)
                languagePicker(title: "Language 2", selection: $settings.dictationLanguage2Id)

                if enabledLocales.isEmpty {
                    Text("No dictation languages enabled in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Add more languages in System Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Dictation") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderless)
            }

            Section("Status") {
                HStack {
                    Text("Current dictation language")
                    Spacer()
                    Text(DictationService.currentLanguage() ?? "—")
                        .foregroundStyle(.secondary)
                }
                shortcutStatusRow
            }
        }
    }
    .formStyle(.grouped)
    .padding()
    .onAppear { enabledLocales = DictationService.enabledLocales() }
}

@ViewBuilder private var shortcutStatusRow: some View {
    if DictationService.dictationShortcut() == nil {
        VStack(alignment: .leading, spacing: 4) {
            Label("No dictation shortcut set", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("The default \u201cPress Fn twice\u201d cannot be triggered programmatically. Choose a keyboard shortcut in System Settings \u2192 Keyboard \u2192 Dictation.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Dictation") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderless)
        }
    } else {
        HStack {
            Text("Dictation shortcut")
            Spacer()
            Text("Configured \u2713")
                .foregroundStyle(.secondary)
        }
    }
}
```

The `enabledLocales` is a `@State private var enabledLocales: [DictationLanguage] = []` populated on appear. The pickers show the full `DictationLanguage` list with flag + display name.

## Implementation Phases

### Phase 1: Foundation (service + model, no UI wiring)

- Add `DictationLanguage.swift` and `OrbitItem.swift`.
- Add `DictationService.swift` with all six methods.
- Add the three `@Published` properties to `SettingsService` + save/load.
- **Manual validation:** open the running app, call `DictationService.enabledLocales()` from a temporary debug menu item, verify it returns the user's real languages. Call `switchLanguageAndStart("sv_SE")` from the debug menu and watch dictation actually start in Swedish. Remove the debug menu items after validation.

### Phase 2: Settings tab

- Add `dictationTab` to `SettingsView` as the fourth tab.
- Implement the language pickers, status row, shortcut warning, and deep links.
- **Manual validation:** toggle enable on/off, pick languages, verify persistence across app restart. Verify the shortcut warning appears when no custom shortcut is set (test by clearing it in System Settings).

### Phase 3: Ring integration

- Rename `OrbitViewModel.apps` → `items`, widen to `[OrbitItem]`, introduce `buildItems()`.
- Update `selectAndSwitch()` to branch on `OrbitItem`.
- Update `OrbitView.swift` `ForEach` and label.
- Add `LanguageTileView.swift`.
- **Manual validation:** run the app, configure two languages in Settings, open the ring, verify language tiles appear at positions 0 and 1, verify scroll / arrow / hover select them correctly, verify clicking a tile dismisses the overlay and starts dictation in the previously focused app.

### Phase 4: Polish & edge cases

- First-post-after-restart retry mitigation (optional second shortcut fire after 150ms if timing turns out flaky — gate behind a config flag if needed).
- Language pack check: read `Offline Dictation Status[locale].Installed` from `com.apple.assistant.support.plist` and surface a non-blocking info icon next to languages without a local pack.
- Update `SPEC.md` with new sections covering `DictationService`, `DictationLanguage`, `OrbitItem`, the ring widening, the Dictation tab, and the new `SettingsService` fields.

### Phase 5: Release

Per `CLAUDE.md`: bump `MARKETING_VERSION` in `project.yml` and the two pbxproj entries, add a `CHANGELOG.md` section, run `./build.sh`, zip, commit, push, and cut a `gh release`.

## Acceptance Criteria

### Functional

- [ ] Opening Orbit's ring shows two language tiles at positions 0 and 1 when the feature is enabled and both language slots are configured.
- [ ] Clicking a language tile switches the macOS dictation language to the selected locale and starts dictation in the previously focused text field within ~600ms. _(needs live manual test)_
- [ ] Clicking the already-active language starts dictation without a visible delay (sub-100ms target). _(needs live manual test)_
- [x] When the feature is disabled or no languages are configured, Orbit behaves identically to today (no language tiles, no code paths touched). _(`dictationLanguages` returns `[]` when disabled; `show()` concatenation produces an empty language prefix)_
- [x] Settings tab populates the language pickers from the user's enabled dictation locales (via `VisibleNetworkSRLocaleIdentifiers`). _(verified against live user state: returns `en_GB`, `sv_SE`)_
- [x] Settings tab shows an orange warning and a "Open System Settings" button when the user has no valid dictation shortcut (either unset or still `(65535, 65535, 0)`).
- [x] Scroll wheel rotation, Left/Right arrow navigation, and sticky-selection all work across language tiles the same way they do for apps. _(OrbitViewModel now operates over `items`; all index-based code paths unchanged)_

### Non-functional

- [ ] Click-to-mic-active latency ≤ 600ms on a modern Apple Silicon Mac (measured informally via screen recording). _(needs live manual test)_
- [x] Feature is disabled by default on first launch. _(`dictationEnabled` default is `false`)_
- [x] `DictationService` is the only file that touches undocumented plist keys or the Ironwood bundle id. Grep confirms zero code-path references to `inputmethod.ironwood`, `DictationIM`, or `AppleSpeechRecognition.prefs` outside `DictationService.swift` (the only other hit is a doc comment in `DictationLanguage.swift`).
- [x] A prefs write-then-read mismatch is logged via `os.Logger` (early-warning signal if Apple renames the key).

### Quality gates

- [x] `./build.sh` produces a working `Orbit.app` with no compiler warnings introduced by this change.
- [x] `npx prettier --write .` and any lint commands run clean before commit.
- [x] `SPEC.md` is updated to describe every new file and behavior.
- [x] Brainstorm doc (`docs/brainstorms/2026-04-08-dictation-language-switching-brainstorm.md`) is already corrected.

## Success Metrics

- Personal use metric: user switches dictation language mid-workflow at least once a day without opening System Settings.
- No crash reports related to `DictationService`.
- Feature survives the next macOS point release without changes (monitor via the write-verification log).

## Dependencies & Risks

| Risk                                                                      | Severity | Mitigation                                                                                                                                    |
| ------------------------------------------------------------------------- | -------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| Apple renames `DictationIMNetworkBasedLocaleIdentifier` in a future macOS | High     | Isolated in one file; write-verification logs mismatch; feature is opt-in so users can disable.                                               |
| First shortcut post after DictationIM restart is eaten                    | Medium   | Optional retry-post flag in Phase 4; benign because a duplicate is a no-op.                                                                   |
| User is on "Press Fn twice" and can't synthesize                          | Medium   | Detected in `dictationShortcut()`; Settings tab shows warning + deep link. Feature still switches the language, just doesn't start dictation. |
| Language pack not downloaded on Apple Silicon                             | Low      | System falls back to network dictation automatically; surface an info icon in Settings.                                                       |
| Locale format mismatch (underscore vs hyphen)                             | Low      | All code paths use underscore format per the verified plist schema. `DictationLanguage.from` converts for `Locale` display lookups only.      |
| Accessibility permission denied                                           | Low      | Orbit already requires this for core features; same prompt, no new UX.                                                                        |

## Alternative Approaches Considered

1. **Script System Settings via AppleScript.** Documented, but opens a window every switch and is slow (~2s). Not viable for "fast switcher" UX.
2. **AX-click the in-flight dictation HUD language picker.** Requires dictation to already be running, extremely fragile to OS updates.
3. **Roll our own dictation with `SFSpeechRecognizer`.** Full control of language selection, but requires building a mic UI, text injection, and permission plumbing. Over-scoped for a single-day feature; good escape hatch if Apple closes the current path.
4. **Use `activateSettings -u` to install a shortcut on the user's behalf.** Technically possible but invasive — silently claiming a global hotkey without explicit consent is user-hostile. Out of scope.

## Out of Scope

- Voice Control or third-party dictation tools (Wispr Flow, SuperWhisper, etc.).
- More than two languages / N-language configuration.
- Automatic language detection from surrounding text.
- A fallback implementation using scripted System Settings or `SFSpeechRecognizer`.
- Starting dictation without a language switch (already covered by macOS's native shortcut).
- Displaying the currently-active dictation language in the menu bar status item.

## References & Research

### Internal references

- Brainstorm: `docs/brainstorms/2026-04-08-dictation-language-switching-brainstorm.md`
- Existing ring architecture: `Orbit/ViewModels/OrbitViewModel.swift:8` (`apps` property), `Orbit/ViewModels/OrbitViewModel.swift:68` (`selectAndSwitch`)
- Existing item rendering pattern: `Orbit/Views/OrbitView.swift:43` (`ForEach` over apps), `Orbit/Views/AppIconView.swift:1` (tile selection visuals to mirror)
- Settings storage pattern: `Orbit/Services/SettingsService.swift:53` (`save()` method), `Orbit/Views/SettingsView.swift:9` (`TabView` layout)
- Spec: `SPEC.md` (needs update in Phase 4)
- Release process: `CLAUDE.md` § "Releasing a new version"

### External references

- **tom-barone/dotfiles** `mac/manage-dictation-language.sh` — minimal reference for the current plist schema: https://github.com/tom-barone/dotfiles/blob/master/mac/manage-dictation-language.sh
- **benthamite/dotfiles** `bin/dictation-language` — real-world script, source of the "first shortcut post gets eaten" gotcha: https://github.com/benthamite/dotfiles/blob/master/bin/dictation-language
- **ntkme/Swift-Dictation** — Objective-C reference app with correct Ironwood-terminate pattern (but stale key name): https://github.com/ntkme/Swift-Dictation/blob/master/Swift%20Dictation/MasterDictationManager.m
- **Keyboard Maestro community thread** on Sonoma dictation switching: https://forum.keyboardmaestro.com/t/seeking-help-for-keyboard-shortcut-to-switch-dictation-languages-in-macos-sonoma/34785
- **Apple Feedback FB9093710** — open bug confirming Fn key cannot be synthesized via CGEvent: https://github.com/feedback-assistant/reports/issues/524
- **usagimaru macOS keycode gist** — canonical CGEvent shortcut synthesis pattern: https://gist.github.com/usagimaru/2c918779d68aa0899f281357cfec62db
- **Kevin Cox** on `launchctl kickstart` changes in 14.4 (DictationIM is still safe to terminate as a user LaunchAgent): https://www.kevinmcox.com/2024/03/changes-to-launchctl-kickstart-in-macos-14-4/
- **Apple Speech.framework** (escape-hatch reference for the "roll our own" alternative): https://developer.apple.com/documentation/speech
