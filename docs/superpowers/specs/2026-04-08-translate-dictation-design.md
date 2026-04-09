# Translate-to-English Dictation Tile + Microphone Device Picker

**Date:** 2026-04-08
**Status:** Approved (brainstorming complete)
**Author:** brainstorming session with Carl-Fredrik Arvidson

## Goal

Two related Dictation-tab improvements bundled into one release because they touch the same files:

1. **Translate tile** — a new Orbit ring tile that lets the user speak in a non-English language and have the transcript pasted into the frontmost app **in English**. The tile is visually distinct from regular dictation language tiles by showing two flags side-by-side: source language → target English variant.
2. **Microphone input device picker** — a new Settings control that lets the user pick which microphone Whisper listens to. Today `AVAudioEngine.inputNode` silently uses the system default input, which is the wrong device whenever an external mic is plugged in but the user has not switched system default (common with USB mics, AirPods, and audio interfaces).

## Why

**Translate tile:** Existing language tiles (`🇸🇪`, `🇫🇷`, …) call WhisperKit with `task: .transcribe`, so a Swedish utterance is pasted as Swedish text. WhisperKit also supports `task: .translate`, which takes audio in any of Whisper's 99 languages and outputs **English** text. The user wants this as a first-class tile in the ring so they can dictate in their native language but produce English output, with no extra steps.

**Microphone picker:** Today `AVAudioEngine.inputNode` uses the system default audio input. When a user plugs in a USB mic, AirPods, or an audio interface but has not switched the macOS system default, Whisper listens to the wrong device — typically the built-in mic with worse quality or in the wrong room. A picker in the Dictation tab lets the user pin Whisper to a specific device independent of the system default.

## Scope and constraints

### Translate tile

- **Target language is locked to English.** Whisper's `.translate` task only outputs English; other targets would require a separate translation model. This is acceptable for v1 and matches the user's requirement.
- **Single source language at a time** (configurable in Settings, default `sv_SE`). Not per-locale auto-fanout — keeps the ring uncluttered.
- **One translate tile in the ring** (not one per enabled language).
- **Opt-in via a Settings toggle** so existing users do not get a surprise tile after upgrade.
- **No changes to system Dictation prefs** when the translate tile is selected. The macOS physical dictation shortcut cannot translate, so leaving it untouched is correct (otherwise we would mislead the user's physical shortcut into thinking it was set up to "translate Swedish to English", which is a thing it cannot do).

### Microphone picker

- **`nil` means "follow system default"** — default for all existing users so nothing changes for anyone who has not opted in.
- **Applies to both regular dictation and translate** — one device picker covers both code paths because they share `SpeechRecognitionService.beginCapture`.
- **Device disappearance is not an error** — if the stored device is no longer connected when a session starts, fall back to the system default and log a line. Do not show an alert; the user may have legitimately unplugged their mic.
- **No live level meter, no permission status row** — explicitly out of scope for v1 (the brainstorming session considered them and deferred).

### Shared constraints

- **No new test target** — Orbit has no test target today, verification is manual smoke testing.

## Architecture decision: where the task mode lives

Considered three approaches for representing transcribe vs translate in `SpeechRecognitionService`:

1. **Parametrize `start()`** with a mode argument. Minimal code, but mode is hidden in a parameter — call site does not signal intent.
2. **Two separate public methods** (`startDictation`, `startTranslation`) delegating to a private `startInternal(task:)`. Slightly more boilerplate, but call sites are explicit and grep-friendly.
3. **Separate `TranslationService` wrapper.** Overengineering — only one line of behavior actually differs.

**Chosen: option 2.** The trace from `OrbitViewModel.selectAndSwitch` → `DictationService.startTranslation` → `SpeechRecognitionService.startTranslation` is self-documenting, which is worth the extra method.

## Data model

### New `OrbitItem` case

```swift
enum OrbitItem: Identifiable, Equatable {
    case app(RunningApp)
    case language(DictationLanguage)
    case translate(TranslatePair)   // new

    var id: String {
        switch self {
        case .app(let app): return "app:\(app.id)"
        case .language(let language): return "lang:\(language.id)"
        case .translate(let pair): return pair.id
        }
    }

    var displayName: String {
        switch self {
        case .app(let app): return app.name
        case .language(let language): return language.displayName
        case .translate(let pair): return "\(pair.source.displayName) → \(pair.target.displayName)"
        }
    }
}
```

### New `TranslatePair` model

```swift
struct TranslatePair: Identifiable, Equatable {
    let source: DictationLanguage   // e.g. sv_SE
    let target: DictationLanguage   // derived from enabled en_*; never user-chosen
    var id: String { "translate:\(source.id)" }
}
```

The `id` is keyed only on `source.id` because there is exactly one translate tile at a time, and the anchor angle must remain stable when the user switches their enabled `en_*` variant in System Settings (otherwise changing `en_US` → `en_GB` would visually move the tile in the ring).

### New `SettingsService` fields

| Field                     | Type      | Default   | Persistence key             |
| ------------------------- | --------- | --------- | --------------------------- |
| `translateTileEnabled`    | `Bool`    | `false`   | `"translateTileEnabled"`    |
| `translateSourceLocaleId` | `String`  | `"sv_SE"` | `"translateSourceLocaleId"` |
| `translateAngle`          | `Double?` | `nil`     | `"translateAngle"`          |
| `dictationInputDeviceUID` | `String?` | `nil`     | `"dictationInputDeviceUID"` |

`dictationInputDeviceUID` stores the CoreAudio `kAudioDevicePropertyDeviceUID` string (e.g. `"BuiltInMicrophoneDevice"`, `"AppleUSBAudioEngine:Audio Engine:..."`). `nil` means "follow system default input". The CoreAudio UID is stable across reconnects for most devices — this is the same identifier Apple uses internally for persistent device mappings.

### New computed property

```swift
var translatePair: TranslatePair? {
    guard translateTileEnabled else { return nil }
    let enabled = DictationService.enabledLocales()
    guard let source = enabled.first(where: { $0.id == translateSourceLocaleId }) else {
        return nil  // configured source no longer enabled in System Settings
    }
    let target = preferredEnglishTarget(from: enabled)
    return TranslatePair(source: source, target: target)
}

private func preferredEnglishTarget(from enabled: [DictationLanguage]) -> DictationLanguage {
    // enabledLocales() already orders by DictationIMPreferredLanguageIdentifiers.
    if let firstEnglish = enabled.first(where: { $0.id.hasPrefix("en") }) {
        return firstEnglish
    }
    return DictationLanguage.from(localeId: "en_US")  // hardcoded fallback
}
```

### Anchor angle handling

`SettingsService.ensureAnchorAngles(for:)` and `pruneAnchorAngles` are extended to also handle `translateAngle`:

- When `translatePair` first becomes non-nil and `translateAngle == nil`, assign the next available angle via the same `nextAvailableAngle()` mechanism that `languageAngles` uses.
- When `translateTileEnabled` flips to `false` or `translatePair` returns `nil` because the source locale was removed, **preserve** `translateAngle` (so re-enabling restores the slot).
- The total set considered for `nextAvailableAngle` collision detection (`Array(pinnedAngles.values) + Array(languageAngles.values)`) gains `translateAngle` when set.

## Service layer

### `SpeechRecognitionService` refactor

Public surface today:

```swift
func start(localeId: String, onError: @escaping (String) -> Void = { _ in })
```

Public surface after:

```swift
func startDictation(localeId: String, onError: @escaping (String) -> Void = { _ in })
func startTranslation(
    sourceLocaleId: String,
    targetLocaleId: String,           // for indicator display only; Whisper itself ignores it
    onError: @escaping (String) -> Void = { _ in }
)

private func startInternal(
    localeId: String,
    task: DecodingTask,
    targetLocaleIdForDisplay: String?,
    onError: @escaping (String) -> Void
)
```

Internal state additions:

```swift
private var currentTask: DecodingTask = .transcribe
private var currentTranslationTargetId: String?    // nil unless translating
```

Both are reset to defaults (`.transcribe` / `nil`) in `stop()`.

Set inside `startInternal` immediately after the start guards pass. Used in two places:

1. `flushAndTranscribe()` — replace hardcoded `task: .transcribe` in `DecodingOptions(...)` with `task: currentTask`.
2. `stop(reason:flushBuffer:)` final-flush block — same replacement.

`SpeechRecognitionService.start(localeId:)` is removed (not deprecated — Orbit is a single-binary app, no external API to keep stable). All call sites become `startDictation(localeId:)`.

### `DictationService` additions

New static method takes the full `TranslatePair` so the caller does not have to thread source and target separately, and so the service has both available for the indicator without coupling to `SettingsService`:

```swift
static func startTranslation(pair: TranslatePair) {
    // Deliberately does NOT call setLanguage(): system Dictation cannot
    // translate, so writing the source locale to AppleSpeechRecognition.prefs
    // would misconfigure the user's physical dictation shortcut.
    SpeechRecognitionService.shared.startTranslation(
        sourceLocaleId: pair.source.id,
        targetLocaleId: pair.target.id
    ) { errorMessage in
        NSLog("[Orbit.dictation] translation start failed: \(errorMessage)")
    }
}
```

`switchLanguageAndStart(_:)` is unchanged in behavior; only the inner call becomes `SpeechRecognitionService.shared.startDictation(localeId:)`.

### `AudioInputDeviceService` (new)

A stateless enum that wraps CoreAudio device enumeration. Lives at `Orbit/Services/AudioInputDeviceService.swift`.

```swift
enum AudioInputDeviceService {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID   // CoreAudio AudioDeviceID; the runtime handle
        let uid: String         // CoreAudio kAudioDevicePropertyDeviceUID; stable across reconnects
        let name: String        // Human-readable name, e.g. "Shure MV7", "MacBook Pro Microphone"
    }

    /// Enumerate every CoreAudio device that has at least one input stream,
    /// sorted alphabetically by name. Output-only devices (speakers, HDMI
    /// displays) are filtered out. Fast — the whole call is synchronous and
    /// takes <1ms on a typical Mac.
    static func listInputDevices() -> [Device]

    /// Resolve a persistent UID back to its current AudioDeviceID. Returns
    /// nil if no connected device has that UID (e.g. the user unplugged
    /// their USB mic since last session).
    static func audioDeviceID(forUID uid: String) -> AudioDeviceID?
}
```

Implementation walks `kAudioHardwarePropertyDevices` on the system audio object, filters to devices with at least one `kAudioDevicePropertyStreams` entry on `kAudioObjectPropertyScopeInput`, and reads `kAudioDevicePropertyDeviceUID` (CFString) and `kAudioDevicePropertyDeviceNameCFString` (CFString) for each survivor. No permissions needed — enumeration does not count as microphone access.

### `SpeechRecognitionService.beginCapture` — configure input device before start

`beginCapture` today installs the tap on `audioEngine.inputNode` and starts the engine without ever touching the device. The new version, if `SettingsService.shared.dictationInputDeviceUID` is non-nil, resolves it to an `AudioDeviceID` and pokes the underlying audio unit via `kAudioOutputUnitProperty_CurrentDevice` **before** installing the tap (because changing the device changes the input format, which the tap installation depends on):

```swift
// Inside beginCapture, at the very top before touching inputNode:
if let uid = SettingsService.shared.dictationInputDeviceUID,
   let deviceID = AudioInputDeviceService.audioDeviceID(forUID: uid) {
    var mutableID = deviceID
    let audioUnit = audioEngine.inputNode.audioUnit
    let status = AudioUnitSetProperty(
        audioUnit!,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &mutableID,
        UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    if status != noErr {
        NSLog("[Orbit.speech] failed to set input device \(uid): OSStatus=\(status) — falling back to system default")
    } else {
        NSLog("[Orbit.speech] input device set to \(uid)")
    }
} else if SettingsService.shared.dictationInputDeviceUID != nil {
    NSLog("[Orbit.speech] stored input device \(SettingsService.shared.dictationInputDeviceUID ?? "") is not connected — falling back to system default")
}
```

The two log lines distinguish "we set the device successfully" from "we tried but the device is gone". Either way, `beginCapture` then proceeds with its existing `inputNode.outputFormat(forBus: 0)` read, which will reflect whichever device ended up selected.

### `OrbitViewModel.show()` integration

After the existing language-anchor loop, append the translate tile if present:

```swift
if let pair = settings.translatePair, let angle = settings.translateAngle {
    anchored.append((.translate(pair), angle))
}
```

`SettingsService.ensureAnchorAngles(for:)` is called before this block and is responsible for assigning `translateAngle` if it is missing.

### `OrbitViewModel.selectAndSwitch()` integration

New case in the switch:

```swift
case .translate(let pair):
    DictationService.startTranslation(pair: pair)
```

### `RingLayout`

No changes. `RingLayout` operates on `OrbitItem` opaquely via the anchored `(item, angle)` tuples.

### `RecordingIndicatorPanel` extension

`show(localeId:state:onClick:)` gains an optional `targetLocaleId: String? = nil` parameter. When non-nil:

- The flag region renders both flags with an arrow between (matching `TranslateTileView`'s visual).
- The state label reads "🇸🇪 → 🇺🇸 listening…" in place of "🇸🇪 listening…".

`SpeechRecognitionService.showIndicator` passes `targetLocaleId: currentTranslationTargetId` whenever it is non-nil. The target locale id is captured at start time from the `targetLocaleId` parameter to `startTranslation`, stored in `currentTranslationTargetId`, and reset to `nil` in `stop()`. The transcribe path leaves `currentTranslationTargetId == nil`, so the indicator behaves exactly as today for regular dictation.

## UI components

### `TranslateTileView` (new, parallel to `LanguageTileView`)

```
┌────────────────┐
│                │
│  🇸🇪   →   🇺🇸  │   ← HStack, centered
│                │
└────────────────┘
```

Visual rules (matching `LanguageTileView` for ring consistency):

- `RoundedRectangle(cornerRadius: 12)` with `.ultraThinMaterial` fill.
- Same selection glow (`shadow` with `Color.accentColor.opacity(0.8)` radius 12).
- Same selection stroke (`RoundedRectangle.stroke(Color.accentColor, lineWidth: 2.5)`).
- Same `scaleEffect(isSelected ? 1.25 : 1.0)` and `.easeInOut(duration: 0.12)` animation.
- Same anchored size boost: `effectiveSize = isAnchored ? size * 1.2 : size`.

Internal layout:

- `HStack(spacing: effectiveSize * 0.06)` centered in the tile
- Source flag: `Text(pair.source.flagEmoji).font(.system(size: effectiveSize * 0.42))`
- Arrow: `Image(systemName: "arrow.right").font(.system(size: effectiveSize * 0.22, weight: .semibold)).foregroundStyle(.secondary)`
- Target flag: `Text(pair.target.flagEmoji).font(.system(size: effectiveSize * 0.42))`

**No locale code badge** — two flags carry the meaning, a badge would add visual noise.

### `OrbitView` rendering switch

Where `OrbitView` today switches over `.app` and `.language`, add:

```swift
case .translate(let pair):
    TranslateTileView(pair: pair, isSelected: ..., size: viewModel.iconSize, isAnchored: true)
```

### `SettingsView` additions

In the existing Dictation section, a new "Translation" subgroup:

```
┌─ Translation ────────────────────────────────────┐
│ ☐ Show translate-to-English tile in Orbit ring   │
│                                                   │
│ Source language: [ Swedish (sv_SE)         ▾ ]   │
│                                                   │
│ Speak in the selected language. Orbit             │
│ transcribes and translates to English using       │
│ Whisper.                                          │
└───────────────────────────────────────────────────┘
```

- The picker is `disabled(!settings.translateTileEnabled)`.
- Picker options come from `DictationService.enabledLocales().filter { !$0.id.hasPrefix("en") }`.
- Empty-list state: when the filtered list is empty, replace the picker with an inline warning: _"Enable a non-English dictation language in System Settings → Keyboard → Dictation first."_ and a button "Open Dictation Settings…" that opens `x-apple.systempreferences:com.apple.preference.keyboard?Dictation`.
- Toggling the toggle on triggers `SettingsService.ensureAnchorAngles(for:)` so the new tile gets an angle on next ring open.

In the same Dictation tab, **above** the Translation subsection, a new "Microphone" subsection:

```
┌─ Microphone ─────────────────────────────────────┐
│ Input device: [ System Default              ▾ ]  │
│                                                   │
│ [ Refresh list ]                                  │
│                                                   │
│ Orbit uses this microphone for all dictation      │
│ and translation. "System Default" follows your    │
│ macOS audio input setting.                        │
└───────────────────────────────────────────────────┘
```

- Picker is bound to `settings.dictationInputDeviceUID` (`String?`).
- First option is always "System Default" with `tag: String?.none`.
- Remaining options come from `AudioInputDeviceService.listInputDevices()`, each tagged with `Optional(device.uid)` so the selection stores the stable UID, not the transient AudioDeviceID.
- Populated on `.onAppear` of the tab via a new `@State var availableInputDevices: [AudioInputDeviceService.Device] = []` + a `refreshInputDevices()` helper.
- "Refresh list" button re-runs the enumeration, mirroring how "Refresh list" works for dictation languages.
- If the currently-stored `dictationInputDeviceUID` does not match any enumerated device (the user unplugged the device), the picker still displays the stored UID as a "⚠︎ Not connected (UID)" option — selected but visually flagged — so the user is not surprised by a silent reset to System Default. Selecting System Default in that state writes `nil` and clears the warning.
- The Microphone section is **always visible** regardless of `dictationEnabled` or `translateTileEnabled`, because the user may want to pre-configure their mic before enabling either feature.

## Edge cases

| Scenario                                                                                                          | Behavior                                                                                                                                                                                                                                                                                                                                                     |
| ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Source locale removed from System Settings while tile was anchored                                                | `translatePair` returns `nil` → tile disappears from the ring on next open. `translateAngle` is preserved so the slot is restored if the locale is re-enabled.                                                                                                                                                                                               |
| User toggles `translateTileEnabled` off mid-session                                                               | Irrelevant — `currentTask` was captured in `startInternal`, the active session completes normally.                                                                                                                                                                                                                                                           |
| No `en_*` enabled in System Settings                                                                              | Target falls back to a hardcoded `DictationLanguage.from(localeId: "en_US")` (🇺🇸). Whisper does not consult system prefs anyway, so this is purely cosmetic.                                                                                                                                                                                                 |
| Whisper model not downloaded                                                                                      | Existing alert path fires (`showSetupReminderNotification`), same as language tiles.                                                                                                                                                                                                                                                                         |
| Mic permission denied                                                                                             | Existing alert path fires (`showMicPermissionAlert`), same as language tiles.                                                                                                                                                                                                                                                                                |
| User clicks the translate tile while a session is already running                                                 | Existing `start()` re-entrancy guard stops the previous session and starts the new one.                                                                                                                                                                                                                                                                      |
| User picks an `en_*` source somehow (e.g., via a stale `translateSourceLocaleId` from before this filter existed) | `translatePair` returns the pair regardless. The tile renders 🇺🇸 → 🇺🇸 which is degenerate but harmless; Whisper's translate task on English audio just outputs the same English text. We do **not** add a defensive guard — the picker filter prevents this case in normal use, and a defensive nil-return would silently hide the tile with no explanation. |
| Boilerplate filter (`"thanks for watching"` etc.)                                                                 | Unchanged. Translate output is always English, so the existing English-skewed blocklist remains correct.                                                                                                                                                                                                                                                     |
| Stored `dictationInputDeviceUID` refers to a disconnected device when a session starts                            | `AudioInputDeviceService.audioDeviceID(forUID:)` returns nil → `beginCapture` logs "not connected — falling back to system default" and proceeds without setting a specific device. The session runs on the system default. No alert — silent fallback, because unplugging a mic is not an error.                                                            |
| User changes `dictationInputDeviceUID` while a session is running                                                 | Irrelevant — the device is read once at `beginCapture` time. The running session finishes on whatever device it started with.                                                                                                                                                                                                                                |
| User selects a connected device in Settings but starts a session before the picker UI refreshes                   | Not a problem — the picker writes through to `SettingsService` immediately on change, and `beginCapture` reads fresh on every session start.                                                                                                                                                                                                                 |

## Testing strategy

Orbit has no test target today. Verification is via manual smoke test after implementation.

### Translate tile

1. Enable the new toggle, set source to `sv_SE`, open Orbit, anchor the tile at any angle.
2. Click the tile, say _"Hej, hur mår du idag?"_ in Swedish.
3. **Expected:** English text (e.g., _"Hi, how are you today?"_) is pasted into the frontmost app. Swedish text does **not** appear.
4. **Expected:** the recording indicator shows `🇸🇪 → 🇺🇸 listening`.
5. Press ESC mid-session → session aborts, no text is pasted.
6. Re-trigger Orbit mid-session (via hotkey or mouse) → final flush translates and pastes the last utterance, then session ends.
7. Disable `sv_SE` in System Settings → Keyboard → Dictation → re-open Orbit → translate tile is gone.
8. Re-enable `sv_SE` → re-open Orbit → translate tile is back at its previous angle.
9. Toggle the Settings switch off → re-open Orbit → tile is gone but `translateAngle` is preserved (verify by toggling on again — same angle).
10. Verify `RecordingIndicatorPanel` cleans up properly between regular dictation and translate sessions.

### Microphone device picker

11. Open Settings → Dictation → Microphone subsection. Picker is populated, "System Default" is selected by default.
12. Click "Refresh list" — picker repopulates without errors.
13. With System Default selected, dictate from a regular language tile. Verify it works. (Regression check.)
14. Plug in an external mic (USB or Bluetooth). Click "Refresh list" — the new device appears in the picker.
15. Select the external mic, dictate. **Expected:** Whisper picks up audio from the external mic, not the built-in. Verify by speaking close to the external mic and far from the built-in — the transcript should be clear.
16. Without changing the selection, unplug the external mic. Dictate again. **Expected:** transcription still works (silent fallback to System Default), and the Orbit log contains "not connected — falling back to system default".
17. Re-open Settings → Dictation. The Microphone picker now shows the disconnected device with a "⚠︎ Not connected" prefix. Selecting "System Default" clears the warning.
18. Pick a connected device, then quit and relaunch Orbit. The picker remembers the selection, and dictation uses that device.

## SPEC.md updates

After implementation, `SPEC.md` is updated per `CLAUDE.md`:

- **Models** section: add `OrbitItem.translate` case and `TranslatePair` struct.
- **Services** section:
  - Document the `startDictation` / `startTranslation` split on `SpeechRecognitionService` and the `currentTask` state.
  - Document `DictationService.startTranslation` and the deliberate decision **not** to call `setLanguage` from it.
  - Document the new `AudioInputDeviceService` enum, its CoreAudio enumeration approach, and the new device-selection step in `SpeechRecognitionService.beginCapture`.
- **Views** section: add `TranslateTileView` description (visual and layout rules).
- **Settings** section: add `translateTileEnabled`, `translateSourceLocaleId`, `translateAngle`, `dictationInputDeviceUID`, the Translation Settings UI subsection, and the Microphone Settings UI subsection.
- **Ring layout** section: note that translate tiles use the same anchor mechanism as language tiles, with `translateAngle` preserved across enable/disable cycles.

## Out of scope (explicitly deferred)

- Other target languages (would require a separate translation model — NLLB, an LLM call, or similar).
- Multiple translate tiles (one per source). Could be added later by promoting `translateSourceLocaleId: String` and `translateAngle: Double?` into `translateSources: [String]` and `translateAngles: [String: Double]`, plus a multi-row Settings UI.
- Auto-detecting the source language. Whisper supports it via `language: nil`, but the user explicitly wanted a 2-flag tile, which requires a fixed source.
- Apple Shortcuts.app integration. Could be added later as a separate trigger surface that calls `DictationService.startTranslation` directly.
- Hotkey trigger that bypasses the ring entirely. Same — additive, doesn't conflict with this design.
- Live mic input level meter in Settings. Useful for "is my mic working?" feedback but adds an `AVAudioEngine` instance just for the meter; revisit if users actually request it.
- Mic permission status row in Settings. The existing "Microphone Privacy…" button covers the open-system-settings case, and the alert path on first failed start covers the denied case.
- Per-tile mic override (e.g. one mic for translate, another for dictation). Single device for all sessions keeps the model simple.
