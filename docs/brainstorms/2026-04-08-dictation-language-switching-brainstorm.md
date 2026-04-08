# Dictation Language Switching — Brainstorm

**Date:** 2026-04-08
**Status:** Design agreed, ready for `/workflows:plan`

## What We're Building

Two dictation-language tiles (one per chosen language) that sit in the existing Orbit ring alongside running apps. Selecting a tile:

1. Switches the macOS built-in dictation language to that locale.
2. Starts dictation in the previously focused text field.

The user configures exactly two languages in a new **Dictation** settings tab, picked from the set of dictation languages they have already enabled in System Settings → Keyboard → Dictation.

The feature is opt-in — off by default. When off, Orbit behaves exactly as it does today.

## Why This Approach

The user bounces between two languages (a toggle workflow) and wants a single action that both switches the language and starts dictating. Reusing the existing radial ring means:

- Zero new trigger to learn — the existing hotkey/mouse button already opens the ring.
- Language tiles get the same affordances as apps: hover, scroll, arrow keys, glow, sticky selection in trackpad mode.
- Muscle memory is preserved by always placing language tiles at the very start of the ring (before pinned apps), at a fixed position regardless of which apps are running.

Flag emoji on rounded tiles keeps visuals consistent with app icons, avoids bundling image assets, and renders identically on any macOS.

## Key Decisions

### Scope

- **Exactly two languages.** Matches the toggle workflow. No future-proofing for N languages.
- **Opt-in.** Feature is disabled by default because it writes to a private defaults key. Users must turn it on in Settings.
- **Mixed into the app ring.** Same trigger, same ring, languages and apps live side by side.
- **Before pinned apps.** Fixed muscle-memory position.

### Dictation system

- **Built-in macOS Dictation only.** Voice Control and third-party tools are out of scope.
- **Approach A: write the AppleSpeechRecognition prefs and gracefully terminate DictationIM.** Chosen over scripting System Settings (too slow, pops a window) and AX-clicking the in-flight HUD (too fragile).
- **Synthesized dictation shortcut via `CGEvent`** for the "start dictating" half, reading the user's configured shortcut from the same AppleSpeechRecognition prefs file (`CustomizedDictationHotKey`).

### Language list source

- Read the user's **enabled dictation locales** from `~/Library/Preferences/com.apple.speech.recognition.AppleSpeechRecognition.prefs.plist` (`VisibleNetworkSRLocaleIdentifiers` dict; values `1` = enabled, `0` = disabled).
- Settings tab shows only those. Adding more happens in System Settings, reachable via a deep link.
- Flag emoji derived from the locale's region code parsed from the underscore format (`sv_SE` → `SE` → `🇸🇪`), no assets.

### Corrected API details (verified on macOS 15.7.4 against multiple open-source references)

The original brainstorm had the wrong plist domain, key names, and daemon target. These have been corrected below based on research against live system state and cross-referenced open-source tools (tom-barone/dotfiles, benthamite/dotfiles, ntkme/Swift-Dictation).

- **Plist domain:** `com.apple.speech.recognition.AppleSpeechRecognition.prefs`
- **Active language key:** `DictationIMNetworkBasedLocaleIdentifier` (String, e.g. `"en_US"`)
- **Preference order key:** `DictationIMPreferredLanguageIdentifiers` (Array<String>) — must also be reordered to put target first
- **Enabled locales key:** `VisibleNetworkSRLocaleIdentifiers` (Dictionary<String, Int>)
- **User's dictation shortcut key:** `CustomizedDictationHotKey` (Dictionary: `keyChar`, `virtualKey`, `modifiers` where `modifiers` is an NSEvent-compatible bitmask)
- **Daemon to terminate:** `com.apple.inputmethod.ironwood` via `NSRunningApplication.terminate()` — **not** `corespeechd`
- **Locale format:** underscore (`en_US`, `sv_SE`, `zh-Hans_CN`) — not hyphen

### Fast path for same-language clicks

If the clicked language is already active, skip the defaults write and daemon restart entirely. Go straight to the synthesized shortcut. Makes repeat-language clicks feel instant.

## Architecture Sketch

### New types

```swift
struct DictationLanguage: Identifiable, Equatable, Codable {
    let id: String          // locale id, e.g. "en-US"
    let displayName: String // "English (US)"
    let flagEmoji: String   // "🇺🇸"
}

enum OrbitItem: Identifiable {
    case app(RunningApp)
    case language(DictationLanguage)
    var id: String { ... }
}
```

### New service — `DictationService` (stateless enum)

```swift
enum DictationService {
    static func enabledLocales() -> [DictationLanguage]
    static func currentLanguage() -> String?
    static func dictationShortcut() -> (virtualKey: CGKeyCode, flags: CGEventFlags)?
    static func setLanguage(_ localeId: String)       // writes prefs, terminates DictationIM
    static func startDictation()                       // synthesizes CGEvent shortcut
    static func switchLanguageAndStart(_ localeId: String)
}
```

Responsibilities:

- Read/write the AppleSpeechRecognition prefs via `UserDefaults.persistentDomain(forName:)`.
- Update `DictationIMNetworkBasedLocaleIdentifier` and reorder `DictationIMPreferredLanguageIdentifiers` to put the target first.
- Gracefully terminate `com.apple.inputmethod.ironwood` via `NSRunningApplication.terminate()`. `launchd` relaunches it on demand when the synthesized shortcut hits its MachService.
- Read the configured dictation shortcut from `CustomizedDictationHotKey` in the same prefs file. Fall back to `AppleSymbolicHotKeys[164]` in `com.apple.symbolichotkeys.plist`.
- Detect the Fn-twice case (`virtualKey == 65535`) and refuse to synthesize — this cannot be done programmatically (Apple FB9093710).
- Synthesize the shortcut with `CGEvent.post(tap: .cghidEventTap)` after a small ~75ms delay to let the terminate propagate.
- All failure modes are logged and non-fatal.

This is the one file most likely to break on a future macOS, so it is isolated behind one call site and easy to swap.

### UI — `LanguageTileView`

- Same dimensions, rounded rect, selection glow, and scale as `AppIconView`.
- Flag emoji rendered as `Text` at `iconSize * 0.7`.
- Small locale-code badge (`EN`, `SV`) in the corner as a secondary signifier so flags aren't the only cue.

### Ring integration

- `OrbitViewModel.apps: [RunningApp]` → `items: [OrbitItem]`.
- `buildItems()` prepends language tiles (if enabled and configured), then pinned apps, then other running apps.
- `OrbitView`'s `ForEach` switches on `OrbitItem` to render either `AppIconView` or `LanguageTileView`.
- Angle math, scroll-to-rotate, arrow keys, and sticky selection work unchanged.
- On confirm:
  - `.app` → existing `selectAndSwitch()`.
  - `.language` → dismiss, then after the same 50ms delay call `DictationService.switchLanguageAndStart`.

### Settings — new `Dictation` tab

New fourth tab in `SettingsView` containing:

- **Enable toggle** (off by default): "Show dictation languages in the ring"
- **Language 1** picker — populated from `DictationService.enabledLocales()`
- **Language 2** picker — same source
- **Current dictation language** row — read-only, reflects `Dictation Language` key
- **Dictation shortcut status** — shows the user's shortcut, or a warning if unset
- **"Add more languages in System Settings →"** — deep link via `x-apple.systempreferences:com.apple.preference.keyboard?Dictation`

New `SettingsService` properties:

| Property             | Type      | Default |
| -------------------- | --------- | ------- |
| `dictationEnabled`   | `Bool`    | `false` |
| `dictationLanguage1` | `String?` | `nil`   |
| `dictationLanguage2` | `String?` | `nil`   |

## Edge Cases

1. **No dictation shortcut configured ("Press Fn twice")** — this is a blocker, not a soft failure. Apple Feedback FB9093710 confirms the Fn key cannot be reliably synthesized via CGEvent. Settings shows a prominent warning and a "Set a Dictation shortcut…" deep link to `x-apple.systempreferences:com.apple.preference.keyboard?Dictation`. When the user picks a language tile in this state, Orbit still switches the language but shows a one-time notification explaining why dictation did not start.
2. **Picked language already active** — skip the prefs write and the terminate. Fire the shortcut immediately. Target latency: sub-100ms.
3. **Previous app focus** — Orbit's overlay is non-activating, so the prior app stays key and dictation starts in the expected text field. Same mechanism as app activation.
4. **First shortcut after restart is eaten** — a known quirk documented in benthamite/dotfiles. Mitigation: if the previous call terminated DictationIM, fire a second post after ~150ms if no feedback indicates success (fire-and-forget is acceptable since a no-op duplicate is benign).
5. **Language pack not downloaded (Apple Silicon)** — `Offline Dictation Status[locale].Installed` in `com.apple.assistant.support.plist` tells us whether on-device dictation is available. If the picked language has no installed pack, we still switch (network dictation kicks in), but we flag it in Settings with an info icon so the user knows.
6. **User disables all dictation languages in System Settings** — Settings tab shows "No dictation languages enabled" with deep link; ring shows no language tiles.
7. **Future macOS breaks the private keys** — `setLanguage` reads the value back after writing and logs a mismatch. v1 does not ship a fallback; the failure is non-fatal and the feature is opt-in, so users can disable it.
8. **User hasn't granted Accessibility permission** — dictation shortcut synthesis requires it, but Orbit already requires it for its core features. Same permission prompt, no new ask.

## Open Questions

- None blocking. The plan phase should pin down the `corespeechd` restart delay empirically (currently budgeted at 600ms with a 1.5s poll ceiling).

## Out of Scope

- Voice Control or third-party dictation tools.
- More than two languages / configurable N.
- Automatic language detection from text context.
- A fallback path using scripted System Settings (deferred until the private key actually breaks).
- Starting dictation without a language switch (already handled by macOS's native shortcut).
