# Orbit — Specification

A macOS radial app switcher inspired by Hitman's weapon wheel. Press a global shortcut to summon a ring of running app icons around your mouse cursor, hover to select, click to switch.

## Platform & Requirements

- macOS 14+ (Sonoma)
- Swift 5.9
- SwiftUI + AppKit hybrid (no storyboards, no XIBs)
- Xcode project with one Swift Package dependency: [WhisperKit](https://github.com/argmaxinc/WhisperKit) (≥ 0.9.0) for on-device speech recognition

## App Type

- **LSUIElement app** (menu bar only, no Dock icon) — set `LSUIElement = true` in Info.plist
- **Not sandboxed** — sandbox disabled in entitlements (`com.apple.security.app-sandbox = false`)
- Requires **Accessibility permissions** for global keyboard/mouse event monitoring
- Bundle ID: `com.orbit.appswitcher`

## Architecture Overview

```
Orbit/
├── OrbitApp.swift              # @main entry point
├── AppDelegate.swift           # Menu bar, hotkey wiring, overlay lifecycle
├── Info.plist
├── Models/
│   ├── RunningApp.swift        # Wraps NSRunningApplication
│   ├── DictationLanguage.swift # Locale id + display name + flag emoji
│   ├── OrbitItem.swift         # Sum type: .app(RunningApp) | .language(DictationLanguage) | .translate(TranslatePair)
│   └── TranslatePair.swift     # Source + target DictationLanguage for translate tile
├── Services/
│   ├── AppService.swift             # Fetches running GUI apps
│   ├── AudioInputDeviceService.swift # CoreAudio input device enumeration
│   ├── HotkeyService.swift          # Carbon global hotkey + mouse button monitors
│   ├── OverlayPanel.swift           # Floating transparent NSPanel
│   ├── SettingsService.swift        # UserDefaults persistence (singleton)
│   ├── DictationService.swift       # macOS dictation language plist writes + entry point that hands off to SpeechRecognitionService
│   ├── SpeechRecognitionService.swift # In-process WhisperKit pipeline (audio capture, VAD, transcription, text injection)
│   └── UpdateService.swift          # GitHub release update checker
├── ViewModels/
│   └── OrbitViewModel.swift    # Selection logic, angle math, event monitors
├── Views/
│   ├── OrbitView.swift         # SwiftUI radial layout with hover tracking
│   ├── AppIconView.swift       # Single app icon with selection glow
│   ├── LanguageTileView.swift  # Dictation language tile (flag emoji + locale badge)
│   ├── TranslateTileView.swift # Translate tile (source flag → arrow → target flag)
│   ├── SettingsView.swift      # Tabbed settings window
│   └── ShortcutRecorderView.swift  # Keyboard shortcut capture
└── Resources/
    ├── Assets.xcassets/        # App icon, accent color
    └── Orbit.entitlements
```

## Entry Point

- `OrbitApp` is a SwiftUI `@main App` with `@NSApplicationDelegateAdaptor(AppDelegate.self)`
- The `body` contains only an empty `Settings` scene (settings are opened manually via a custom `NSWindow`)

## AppDelegate

Responsibilities:

1. **Accessibility prompt** — on launch, call `AXIsProcessTrustedWithOptions` with the prompt option to request Accessibility permissions. Also detects the **stale-TCC-entry** case (after every rebuild for ad-hoc-signed apps): if `AXIsProcessTrusted()` returns false even though the entry exists in System Settings, shows a custom warning alert with an "Open Privacy Settings…" button explaining the user needs to toggle Orbit off and back on. Without this check the rebuild silently breaks the global hotkey suppression and the dictation paste path because `CGEvent.post` is filtered while the Carbon hotkey keeps working
2. **Menu bar status item** — `NSStatusBar.system.statusItem` with the SF Symbol `circle.dotted`
   - Menu items: Settings (Cmd+,), About Orbit, Quit Orbit (Cmd+Q)
   - Disabled info items show current activation method and input mode
   - "Update Available" item inserted at top when a newer GitHub release is found
3. **Hotkey setup** — create `HotkeyService` with a callback that calls `toggleOrbit()`
4. **Overlay panel** — create a single `OverlayPanel` hosting the `OrbitView`
5. **Settings observation** — use Combine to observe changes to trigger settings (debounced 100ms) and re-register the hotkey
6. **Settings window** — opened as a plain `NSWindow` (420x600) with `NSHostingView<SettingsView>`, not SwiftUI's Settings scene
7. **Toggle logic** — if visible, dismiss; if hidden, get `NSEvent.mouseLocation`, call `viewModel.show()`, then `overlayPanel.showOverlay(at:size:)`
8. **Update check** — on launch, calls `UpdateService.checkForUpdate` to check for newer GitHub releases

## RunningApp Model

```swift
struct RunningApp: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage
    let app: NSRunningApplication
}
```

Equality is based on `id` (process ID) only.

## DictationLanguage Model

```swift
struct DictationLanguage: Identifiable, Equatable, Codable {
    let id: String          // underscore locale format, e.g. "en_US", "sv_SE"
    let displayName: String
    let flagEmoji: String
}
```

- `id` uses the underscore format macOS writes into `DictationIMNetworkBasedLocaleIdentifier` (not the hyphen BCP-47 form).
- `from(localeId:)` parses the region subtag and derives the flag emoji via regional-indicator Unicode (`"sv_SE"` → `🇸🇪`). Falls back to 🏳️ if no 2-letter region is parseable.
- `displayName` is looked up via `Locale.current.localizedString(forIdentifier:)` after converting the id to hyphen form.

## OrbitItem Model

```swift
enum OrbitItem: Identifiable, Equatable {
    case app(RunningApp)
    case language(DictationLanguage)
    case translate(TranslatePair)
    var id: String { /* "app:<pid>", "lang:<locale>", or "translate:<sourceLocale>" */ }
    var displayName: String { /* RunningApp.name, DictationLanguage.displayName, or "Swedish → English (US)" */ }
}
```

The ring consumes `[OrbitItem]` so apps, dictation language tiles, and translate tiles can coexist. All ring mechanics (angle math, scroll-to-rotate, arrow navigation, sticky selection) operate on indices over `items`, independent of item type.

## TranslatePair Model

```swift
struct TranslatePair: Identifiable, Equatable {
    let source: DictationLanguage   // e.g. sv_SE — the language the user speaks into
    let target: DictationLanguage   // the en_* variant displayed in the tile and indicator
    var id: String { "translate:\(source.id)" }
}
```

`target` is cosmetic: WhisperKit's `.translate` task always outputs English regardless of which `en_*` variant is stored here. The `id` is keyed only on `source.id` so the tile's anchor angle stays stable when the user changes their preferred English variant in System Settings (e.g. `en_US` → `en_GB`) — otherwise the angle-keyed slot would drift.

## AppService

A stateless enum with one static method:

- `runningApps(excluding: Set<String>, pinnedFirst: [String]) -> [RunningApp]`
- Queries `NSWorkspace.shared.runningApplications`
- Filters to `activationPolicy == .regular` (GUI apps only)
- Excludes apps whose bundle ID is in the exclusion set
- Pinned apps (by bundle ID) are sorted to the front in their pinned order; remaining apps follow
- Falls back to a blank 64x64 NSImage if `app.icon` is nil

## HotkeyService

Supports three trigger modes:

### Keyboard Hotkey (Carbon API)

- Uses `RegisterEventHotKey` / `UnregisterEventHotKey` from the Carbon framework
- Hotkey signature: ASCII bytes `"ORBT"` packed into a `UInt32`
- Installs an event handler via `InstallEventHandler` on `GetApplicationEventTarget()`
- The handler callback dispatches to main queue, then calls the provided closure
- Memory management: `Unmanaged.passRetained(self)` when registering, released on unregister

### Mouse Button

- Registers both a **global** (`addGlobalMonitorForEvents`) and **local** (`addLocalMonitorForEvents`) monitor
- Global catches clicks when other apps are focused; local catches clicks when the overlay panel is key
- Matches on `event.buttonNumber` — middle button = 2, button 4 = 3, button 5 = 4
- For middle button, monitors `.otherMouseDown`; right mouse would use `.rightMouseDown`
- **Smart suppression**: the global monitor uses the macOS Accessibility API (`AXUIElementCopyElementAtPosition`) to check what's under the cursor before triggering. The trigger is suppressed when the cursor is over: (1) a **link** — `AXLink` role found in the parent chain (up to 5 levels), preventing middle-click-open-in-new-tab conflicts; (2) a **tab group** — `AXTabGroup` role in the parent chain, covering Chrome tab bars; (3) a **toolbar** — `AXToolbar` role, covering Safari's tab bar and toolbar area; (4) a **tab button** — `AXTabButton` subrole, covering individual Safari tabs. Note: Firefox/Zen-based browsers expose generic `AXWindow` elements for their chrome, so tab-bar suppression is not possible there — this is an accepted trade-off to avoid blocking the trigger in the content area. The local monitor (when Orbit's overlay is key) always fires immediately without the AX check.

### Both Mode

When `triggerType == .both`, registers both the keyboard hotkey AND mouse button monitors simultaneously. Either trigger opens Orbit. Uses targeted `unregisterKeyboard()` / `unregisterMouseButton()` helpers to avoid tearing down one trigger when re-registering the other.

### registerFromSettings

Reads `SettingsService.triggerType` and registers keyboard, mouse button, or both. Calls `unregister()` first to ensure a clean slate.

### Cleanup

`unregister()` tears down all active triggers (hotkey ref, event handler, mouse monitors). Called from `deinit` and before every new registration. Targeted helpers `unregisterKeyboard()` and `unregisterMouseButton()` handle partial cleanup.

## OverlayPanel

Subclass of `NSPanel`:

- Style: `[.borderless, .nonactivatingPanel]`
- Transparent: `isOpaque = false`, `backgroundColor = .clear`
- Level: `.floating`
- Collection behavior: `[.canJoinAllSpaces, .fullScreenAuxiliary]`
- No shadow, not movable, does not hide on deactivate, accepts mouse moved events
- `canBecomeKey = true`, `canBecomeMain = false`

### showOverlay(at:size:)

- Centers a frame of `size × size` around the given screen point
- Clamps frame to the visible screen bounds (menu bar and dock excluded)
- Calls `orderFrontRegardless()` and `makeKey()`

### hideOverlay()

- `orderOut(nil)`

## UpdateService

A stateless enum that checks for newer releases on GitHub.

### checkForUpdate(completion:)

- Sends a GET request to `https://api.github.com/repos/cfarvidson/app-switcher-orbit/releases/latest`
- Parses `tag_name` (stripping leading `v`) and `html_url` from the JSON response
- Compares the remote version to `CFBundleShortVersionString` using semantic version comparison (major.minor.patch)
- If a newer version exists, returns a `Release` struct with the version string and release URL
- Timeout: 10 seconds; silently returns `nil` on any error

### Integration (AppDelegate)

- Called silently from `applicationDidFinishLaunching` (no feedback if up to date)
- "Check for Updates..." menu item triggers a manual check — shows an alert if already up to date
- If a newer release is found, inserts an "Update Available (vX.Y.Z)" menu item at the top of the status menu
- Clicking the update item opens the GitHub release page in the default browser

## SettingsService

Singleton (`shared`) `ObservableObject` backed by `UserDefaults`.

### Stored Properties

| Property                | Type                                   | Default                  | UserDefaults Key          |
| ----------------------- | -------------------------------------- | ------------------------ | ------------------------- |
| triggerType             | `.keyboard` / `.mouseButton` / `.both` | `.keyboard`              | `triggerType`             |
| inputMode               | `.mouse` / `.trackpad`                 | `.mouse`                 | `inputMode`               |
| keyCode                 | `UInt32`                               | `kVK_Space` (49)         | `keyCode`                 |
| modifiers               | `UInt32`                               | `optionKey` (2048)       | `modifiers`               |
| keyDisplayName          | `String`                               | `"Space"`                | `keyDisplayName`          |
| mouseButton             | `Int`                                  | `2` (middle)             | `mouseButton`             |
| edgeActivation          | `Bool`                                 | `false`                  | `edgeActivation`          |
| pinnedBundleIds         | `[String]`                             | `[]`                     | `pinnedBundleIds`         |
| excludedBundleIds       | `Set<String>`                          | `[]`                     | `excludedBundleIds`       |
| dictationEnabled        | `Bool`                                 | `false`                  | `dictationEnabled`        |
| dictationLanguage1Id    | `String?`                              | `nil`                    | `dictationLanguage1Id`    |
| dictationLanguage2Id    | `String?`                              | `nil`                    | `dictationLanguage2Id`    |
| dictationModelName      | `String`                               | `"openai_whisper-small"` | `dictationModelName`      |
| translateTileEnabled    | `Bool`                                 | `false`                  | `translateTileEnabled`    |
| translateSourceLocaleId | `String`                               | `"sv_SE"`                | `translateSourceLocaleId` |
| translateAngle          | `Double?`                              | `nil`                    | `translateAngle`          |
| dictationInputDeviceUID | `String?`                              | `nil`                    | `dictationInputDeviceUID` |

All properties are `@Published`. The `save()` method writes all properties to UserDefaults.

`translateTileEnabled` defaults to `false` so existing users do not get a surprise tile after upgrading. `translateAngle` is assigned by `ensureAnchorAngles` when `translatePair` first becomes non-nil and is preserved when the tile is toggled off — re-enabling restores the same ring slot. `dictationInputDeviceUID` stores the CoreAudio `kAudioDevicePropertyDeviceUID` string (e.g. `"BuiltInMicrophoneDevice"`); `nil` means follow the system default input device.

### Computed Properties

- `shortcutDisplayString` — builds a string like "⌥ Space" from modifier flags and key name, using Unicode symbols (⌃ ⌥ ⇧ ⌘)
- `mouseButtonDisplayName` — human-readable name for the selected mouse button
- `dictationLanguages: [DictationLanguage]` — resolved language tiles for the ring. Empty when `dictationEnabled` is false or no language ids are stored. Builds one `DictationLanguage` per non-nil id via `DictationLanguage.from(localeId:)`.
- `translatePair: TranslatePair?` — returns a `TranslatePair` when `translateTileEnabled` is true, `translateSourceLocaleId` is present in `DictationService.enabledLocales()`, and at least one locale is enabled. The target is the first `en_*` entry in the enabled-locales list, falling back to a hardcoded `en_US` if no English locale is enabled. Returns `nil` if the configured source locale has been removed from System Settings.

## DictationService

Stateless enum that reads/writes the active macOS built-in Dictation language and hands off recognition to `SpeechRecognitionService`. The two responsibilities are independent:

- **Language plist writes** — keep macOS's own Dictation HUD in sync with Orbit's selected language so the user's _physical_ dictation shortcut honors the same language. Cosmetic; Orbit does not depend on it for its own recognition.
- **Recognition entry point** — `switchLanguageAndStart(_:)` calls `SpeechRecognitionService.shared.start(localeId:)` which runs WhisperKit entirely in-process.

### Historical note

Earlier versions tried two different paths to start macOS's built-in DictationIM: synthesizing the user's configured shortcut via `CGPostKeyboardEvent`, and walking the frontmost app's `Edit → Start Dictation…` menu via the Accessibility API. Both were abandoned. DictationIM consistently died ~1.4 s after start with `(null)` errors, the locale cache required process kills that opened kill/respawn windows where posts were dropped, and the whole undocumented surface was fragile. Orbit now runs OpenAI Whisper locally via WhisperKit and never invokes DictationIM.

### Plist surface (language switch only)

- **Domain:** `com.apple.speech.recognition.AppleSpeechRecognition.prefs`
- **Active language key:** `DictationIMNetworkBasedLocaleIdentifier` (String, underscore locale format, e.g. `"en_US"`)
- **Preference order key:** `DictationIMPreferredLanguageIdentifiers` (Array<String>) — reordered so the target locale is first
- **Enabled locales key:** `VisibleNetworkSRLocaleIdentifiers` (Dict<String, Int>; `1` = enabled)

### API

- `enabledLocales() -> [DictationLanguage]` — reads `VisibleNetworkSRLocaleIdentifiers`, returns enabled entries, preserving `DictationIMPreferredLanguageIdentifiers` order.
- `currentLanguage() -> String?` — reads `DictationIMNetworkBasedLocaleIdentifier`.
- `setLanguage(_ localeId:)` — idempotent (no-op when the target already matches). Writes the active locale and reorders the preferred-language array. Performs a read-back verification after the write; mismatches are logged via `os.Logger`. Does **not** restart DictationIM — Orbit no longer depends on it.
- `switchLanguageAndStart(_ localeId:)` — calls `setLanguage` then `SpeechRecognitionService.shared.startDictation(localeId:)`. (Internally renamed from `start(localeId:)` — behavior is unchanged.)
- `startTranslation(pair:)` — starts a WhisperKit translate session via `SpeechRecognitionService.shared.startTranslation(sourceLocaleId:targetLocaleId:)`. Deliberately does **not** call `setLanguage`: macOS system Dictation cannot translate, so writing the source locale into `AppleSpeechRecognition.prefs` would misconfigure the user's physical dictation shortcut.

## SpeechRecognitionService

`ObservableObject` singleton (`SpeechRecognitionService.shared`) that runs the entire dictation pipeline in-process. Replaces a previous `SFSpeechRecognizer` implementation, which had shallow language understanding outside English (bad punctuation, no auto-capitalization, no sentence-boundary modeling). WhisperKit handles all 99 Whisper languages with proper punctuation and casing.

The public API exposes two entry points that delegate to a shared private implementation:

- `startDictation(localeId:onError:)` — transcribes the audio in the given locale with `task: .transcribe`.
- `startTranslation(sourceLocaleId:targetLocaleId:onError:)` — transcribes with `task: .translate`, which always outputs English regardless of source. `targetLocaleId` is used only for the indicator display; Whisper ignores it.

Both delegate to `startInternal(localeId:task:targetLocaleIdForDisplay:onError:)`, which captures the chosen `DecodingTask` in private state (`currentTask: DecodingTask`, `currentTranslationTargetId: String?`). `flushAndTranscribe` and the final flush in `stop` both read `currentTask` rather than hardcoding `.transcribe`. Both fields are reset to their defaults (`.transcribe` / `nil`) at the **end** of `stop()`, after the final-flush dispatch, to avoid a race between the reset and the async transcription task completing.

### Pipeline

1. `AVAudioEngine` taps the input node and runs samples through an `AVAudioConverter` to 16 kHz mono Float32 (the format Whisper expects).
2. Each tap callback computes RMS amplitude over the converted samples for a cheap voice-activity detector. Above the threshold = speech, below = silence.
3. After `silenceTriggerSeconds` of continuous silence following speech (and at least `minSpeechSeconds` of speech in the buffer), or after a hard `maxBufferSeconds` cap, the buffered audio is handed to `WhisperKit.transcribe(audioArray:decodeOptions:)`.
4. The resulting transcript is filtered (Whisper boilerplate like `[Music]`, `Thanks for watching!` is dropped) and injected into the frontmost app via the **clipboard-paste path** described below. Consecutive utterances within a session are joined with a single space.
5. ESC cancels the session (discards the buffer). Clicking the floating indicator, re-triggering Orbit, or hitting the 60 s hard cap commits the session — `stop(reason:flushBuffer:)` runs a final transcription on whatever's still in the buffer before tearing down, so the natural "speak then press hotkey to stop" flow doesn't lose the last utterance.

### Text injection (clipboard paste)

`injectText` does **not** type characters via `CGEvent.keyboardSetUnicodeString`. Two reasons:

1. Electron / Chromium apps (Cursor, VS Code, Slack, Discord, Notion, etc.) ignore CGEvent keystrokes that have `virtualKey: 0`. Chromium's input layer validates the key code against the platform keymap and drops events with no real key, regardless of the unicode payload.
2. Many native apps also dislike unicode-only events for non-ASCII characters; the å in "hallå" can roundtrip through layout-dependent paths.

Instead the implementation:

1. Saves the current `NSPasteboard.general` string contents.
2. Writes the transcript to the pasteboard, **marking it as transient** so clipboard history managers (Maccy, Paste, Pastebot, Raycast clipboard, Alfred Snippets, etc.) skip it. The marker types come from the [nspasteboard.org](http://nspasteboard.org/) community convention — Orbit declares all three (`org.nspasteboard.TransientType`, `org.nspasteboard.ConcealedType`, `org.nspasteboard.AutoGeneratedType`) up front in the same `declareTypes(_:owner:)` call as `.string`, then writes empty data for each marker before writing the string. Some managers only inspect the declared types at declaration time, not on subsequent `setData` calls, so the order matters.
3. Synthesizes a real `Cmd+V` keystroke via `CGEvent` (virtualKey 9 with `.maskCommand`) posted on `.cghidEventTap` so it flows through the standard keyboard pipeline exactly as if pressed physically.
4. After 300 ms (a conservative ceiling for paste latency on slow Electron apps), restores the previous pasteboard contents — also marked transient so the restore doesn't create a duplicate entry in clipboard history (the user's original entry already existed before Orbit touched anything).

The pre-flight log line — `inject pre-flight: frontApp=… bundleId=… axTrusted=…` — captures the frontmost app and `AXIsProcessTrusted()` so failures can be diagnosed from logs alone.

### VAD parameters

| Parameter               | Value   | Purpose                                                             |
| ----------------------- | ------- | ------------------------------------------------------------------- |
| `speechRmsThreshold`    | `0.012` | Empirically tuned: quiet speech passes, baseline room noise doesn't |
| `silenceTriggerSeconds` | `0.8`   | How long to wait after speech before flushing                       |
| `minSpeechSeconds`      | `0.3`   | Don't bother transcribing very short blips                          |
| `maxBufferSeconds`      | `25.0`  | Hard cap so a sustained "uhhh" can't accumulate forever             |

We deliberately do **not** transcribe on a fixed timer because Whisper re-decodes the whole buffer each pass with more context, which causes the live transcript to drift (e.g. "stad oskiven omting" → "starta och skriva någonting"). VAD-based one-shot flushes avoid that.

### Decoding options

`DecodingOptions(verbose: false, task: currentTask, language: <BCP-47 head>, temperature: 0, temperatureFallbackCount: 5, skipSpecialTokens: true, withoutTimestamps: true, noSpeechThreshold: 0.5)`. `currentTask` is `.transcribe` for normal dictation and `.translate` for translate sessions. The locale id passed to `startDictation`/`startTranslation` is converted to a hyphen-form BCP-47 root (e.g. `"en_US"` → `"en"`) for Whisper.

### Model lifecycle

- **Catalog:** see `WhisperModelOption.all` in `SettingsView.swift` — Tiny / Base / Small (default & recommended) / Medium / Large v3 Turbo / Large v3.
- **Cache location:** `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<modelName>/`. `isModelDownloaded(_:)` walks that folder looking for `.mlmodelc` or `.mlpackage` entries.
- **Download:** `downloadAndLoadModel(_:)` calls `WhisperKit.download(variant:from:progressCallback:)` against `argmaxinc/whisperkit-coreml` on Hugging Face, then loads the model into RAM via `WhisperKit(WhisperKitConfig(modelFolder:))`. Idempotent — re-entrant calls during an in-flight download are no-ops. Downloads only ever happen from explicit user actions in Settings → Dictation; the language tile never triggers a download.
- **Prewarm:** `AppDelegate.applicationDidFinishLaunching` calls `prewarm()` if dictation is enabled. Prewarm loads an already-downloaded model into RAM at startup but never initiates a download.
- **Status:** `@Published var modelStatus: ModelStatus` (`.notDownloaded` / `.downloading(progress, modelName)` / `.loading(modelName)` / `.ready(modelName)` / `.error(message)`) — drives the Settings UI.

### Permissions

`ensurePermissions` uses `AVCaptureDevice.authorizationStatus(for: .audio)` and `AVCaptureDevice.requestAccess(for: .audio)`. Only the microphone permission is required — `Speech.framework` is not used, so `NSSpeechRecognitionUsageDescription` is intentionally absent from `Info.plist`.

### Error surfacing

`startInternal(localeId:task:targetLocaleIdForDisplay:onError:)` runs three pre-flight checks before capture begins. Each failure both reports the error via the `onError` callback and shows a user-visible NSAlert so the failure isn't silent:

| Failure                       | Alert                                                                                |
| ----------------------------- | ------------------------------------------------------------------------------------ |
| Selected model not downloaded | "Dictation needs setup" → opens Orbit Settings via `.orbitOpenSettings` notification |
| Microphone permission denied  | "Microphone access denied" → opens System Settings → Privacy & Security → Microphone |
| Audio engine fails to start   | NSLogged; `onError` reports the underlying error                                     |

### Re-entrancy and lockout

`startInternal` is guarded by a 0.75 s `startLockout` and a `starting` re-entrancy flag so back-to-back triggers (e.g. a double-click) don't pile up sessions. If a session is already running, `stop(reason:)` is called first; the toggle handler in `AppDelegate.toggleOrbit` also calls `stop` when the user re-presses the global trigger while dictation is active.

### Floating indicator

`RecordingIndicatorPanel` is a borderless non-activating `NSPanel` shown near the cursor while a session is preparing or recording. Two states: `.loading(message)` while the model is being loaded, and `.listening` while audio capture is active. Click anywhere on the panel to stop the session.

`show(localeId:state:onClick:)` accepts an optional `targetLocaleId: String?` parameter. When non-nil (translate sessions only), the indicator's flag region renders source flag → arrow → target flag instead of the single source flag, and the label reads e.g. "🇸🇪 → 🇺🇸 listening…". The `currentTranslationTargetId` captured at session start is passed here; `nil` for regular dictation sessions so the indicator is unchanged from its historical behavior.

### Notification

`Notification.Name.orbitOpenSettings` is posted when the user clicks "Open Settings…" on the missing-model alert. `AppDelegate` listens for it and opens its Settings window.

### Input device selection

At the very top of `beginCapture`, before reading `inputNode.outputFormat`, the service checks `SettingsService.shared.dictationInputDeviceUID`. If non-nil, it resolves the UID to a live `AudioDeviceID` via `AudioInputDeviceService.audioDeviceID(forUID:)` and sets `kAudioOutputUnitProperty_CurrentDevice` on `audioEngine.inputNode.audioUnit` via `AudioUnitSetProperty`. Changing the device before installing the tap is required because the tap format is derived from the active device. If the stored UID does not resolve (device disconnected), the service logs a fallback line and proceeds with the system default — no alert, as unplugging a mic is a normal operating condition.

## AudioInputDeviceService

A stateless enum (`Orbit/Services/AudioInputDeviceService.swift`) that wraps CoreAudio device enumeration.

```swift
enum AudioInputDeviceService {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID   // runtime handle; changes across reconnects
        let uid: String         // kAudioDevicePropertyDeviceUID; stable across reconnects
        let name: String        // human-readable, e.g. "Shure MV7"
    }

    static func listInputDevices() -> [Device]
    static func audioDeviceID(forUID uid: String) -> AudioDeviceID?
}
```

`listInputDevices` walks `kAudioHardwarePropertyDevices` on the system audio object, filters to devices that have at least one stream on `kAudioObjectPropertyScopeInput` (output-only devices like speakers are excluded), and reads `kAudioDevicePropertyDeviceUID` and `kAudioDevicePropertyDeviceNameCFString` for each survivor. Results are sorted alphabetically by name. The call is synchronous and takes under 1 ms on a typical Mac; no permissions are required because enumeration is distinct from microphone access.

`audioDeviceID(forUID:)` performs the reverse lookup: given a stored UID, it returns the current `AudioDeviceID` for that device, or `nil` if no connected device has that UID.

## OrbitViewModel

`ObservableObject` managing the radial UI state.

### Geometry (Snapshotted in `show()`)

Geometry is snapshotted once per show to avoid reading SettingsService on every frame. Values depend on `InputMode`:

| Property        | Mouse Mode | Trackpad Mode |
| --------------- | ---------- | ------------- |
| radius          | 140pt      | 180pt         |
| iconSize        | 56pt       | 68pt          |
| orbitSize       | 400pt      | 500pt         |
| deadZone        | 35pt       | 45pt          |
| stickySelection | false      | true          |

### Key Properties

- `isVisible: Bool` — controls overlay visibility
- `items: [OrbitItem]` — current ring contents: dictation-language tiles (when `dictationEnabled` and configured) followed by pinned apps followed by other running apps
- `selectedIndex: Int?` — which item is highlighted
- `onDismiss: (() -> Void)?` — callback to hide the overlay panel

### Ring Contents (show)

On each `show()`, the ring is rebuilt from anchored items (language tiles, then the translate tile if present) followed by running apps. Anchored items are placed at their stored angles; apps fill the remaining angular space.

Language tiles come first (when `dictationEnabled` and at least one language is configured). After the language anchor loop, if `settings.translatePair` is non-nil and `settings.translateAngle` is set, a `.translate(pair)` entry is appended at that angle. Running apps follow, with pinned apps at the front of the app section. `SettingsService.ensureAnchorAngles(for:)` is called at the start of `show()` and assigns `translateAngle` if it is nil and a translate pair now exists.

### Angle & Position Math

- Items are distributed evenly around a circle: `angle = (2π / count) × index - π/2`
- The `-π/2` offset places the first item at the 12 o'clock position
- `positionForIndex` converts the angle to (x, y) using `center + radius × (cos, -sin)` (Y is inverted for SwiftUI coordinates)

### Selection Logic (updateSelection)

- Ignore if mouse is within `deadZone` of center
- Calculate mouse angle: `atan2(-dy, dx)`, normalized to [0, 2π)
- Find the item whose angle is closest to the mouse angle (handling the 0/2π wrap)
- Set `selectedIndex` to that item
- If edge activation is enabled and mouse distance exceeds `radius + iconSize × 0.6`, automatically trigger `selectAndSwitch()` — no click needed

### Sticky Selection (handleHoverEnded)

- In mouse mode: `selectedIndex` is cleared when the cursor leaves the panel
- In trackpad mode: selection persists (sticky) — the view delegates this decision to `handleHoverEnded()` which checks the `stickySelection` flag

### Scroll-to-Rotate (Both Modes)

- Two-finger swipe or scroll wheel rotates the highlight around the ring
- Uses `scrollingDeltaY` (not deprecated `deltaY`)
- Accumulates scroll deltas; triggers selection change when accumulator exceeds threshold (3.0)
- **Momentum filtering**: ignores inertial events (`event.momentumPhase != 0`) to prevent coasting
- **Gesture boundary reset**: accumulator resets on `event.phase == .began`, `.ended`, `.cancelled`
- **Time-gated debounce**: 60ms minimum interval between selection changes (~16/sec max)
- **Carry remainder**: subtracts threshold from accumulator instead of zeroing for responsive feel

### Arrow Key + Enter Navigation (Both Modes)

- **Left arrow** (keyCode 123): move selection counterclockwise
- **Right arrow** (keyCode 124): move selection clockwise
- **Enter/Return** (keyCode 36): confirm selection (`selectAndSwitch()`)
- Wraps around using modular arithmetic

### Event Monitors

When visible, installs:

- **Local keyDown** monitor for ESC (keyCode 53) → dismiss, Left/Right arrows → cycle selection, Enter → confirm
- **Global keyDown** monitor for ESC → dismiss
- **Global leftMouseDown** monitor → dismiss (click outside)
- **Local scrollWheel** monitor → scroll-to-rotate selection

All monitors are removed on dismiss.

### selectAndSwitch

- Dismisses the overlay
- After a 50ms delay, branches on the selected `OrbitItem`:
  - `.app(let app)` — calls `app.app.activate()` on the `NSRunningApplication`
  - `.language(let language)` — calls `DictationService.switchLanguageAndStart(language.id)`
  - `.translate(let pair)` — calls `DictationService.startTranslation(pair: pair)`
- The delay ensures the overlay is fully hidden before activation or dictation/translation start

## OrbitView (SwiftUI)

Layered inside a `ZStack`, only rendered when `viewModel.isVisible`:

1. **Background** — `Circle` with `.ultraThinMaterial` fill, size = `orbitSize - 40`, opacity 0.9, tap to dismiss
2. **Ring guide** — `Circle` stroke, white at 10% opacity, 1pt line, diameter = `radius × 2`
3. **Center dot** — 6pt white circle at 40% opacity
4. **Selection line** — dashed `Path` from center to selected app's position, accent color at 40% opacity, dash pattern `[4, 4]`
5. **Ring items** — `ForEach` over enumerated `viewModel.items`, switching on `OrbitItem` to render an `AppIconView` (for `.app`), a `LanguageTileView` (for `.language`), or a `TranslateTileView` (for `.translate`). Each is positioned via `.position()`; tap triggers `selectAndSwitch()`.
6. **Item label** — shown when an item is selected, centered below the middle in a capsule with `.ultraThinMaterial`. Reads `viewModel.items[index].displayName` so it works for both apps and languages.

### Interactions

- `onContinuousHover` tracks mouse position and calls `viewModel.updateSelection(mouseInView:)`
- On hover ended, delegates to `viewModel.handleHoverEnded()` (clears selection in mouse mode, preserves in trackpad mode)
- Animations: `.easeOut(0.2)` on visibility, `.interpolatingSpring(stiffness: 300, damping: 25)` on selection changes (interruptible for rapid scroll/arrow input)

## AppIconView

Displays a single app icon:

- `Image(nsImage:)` resized to `size × size` with `.aspectRatio(.fit)`
- Clipped to `RoundedRectangle(cornerRadius: 12)`
- When selected:
  - Blue glow shadow (accent color, 80% opacity, radius 12)
  - Accent color border stroke (2.5pt)
  - Scale up to 1.25×
- Animation: `.easeInOut(0.12)` on `isSelected`

## LanguageTileView

Displays a dictation-language tile. Visually mirrors `AppIconView` so both item types share the same affordances (rounded rect, selection glow, stroke, scale).

- `RoundedRectangle(cornerRadius: 12)` filled with `.ultraThinMaterial`
- Flag emoji centered as a `Text` at `size * 0.7`
- Small bottom-right badge with the uppercased language subtag (e.g. `"EN"`, `"SV"`) in a black capsule — secondary signifier so flags aren't the only cue
- Same selection treatment as `AppIconView`: accent glow + stroke + `scaleEffect(1.25)`
- Animation: `.easeInOut(0.12)` on `isSelected`

## TranslateTileView

Displays a translate tile alongside language tiles in the ring. Visual treatment matches `LanguageTileView` so both tile types share the same affordances.

- `RoundedRectangle(cornerRadius: 12)` filled with `.ultraThinMaterial`
- `HStack` centered in the tile: source flag emoji → `Image(systemName: "arrow.right")` → target flag emoji
- Font sizes use multipliers of the effective tile size: source/target flags at `0.42×`, arrow icon at `0.22×` with `.semibold` weight, `HStack` spacing at `0.06×`
- No locale badge — two flags carry the meaning without one
- Same selection treatment as `AppIconView` and `LanguageTileView`: accent color glow shadow + stroke + `scaleEffect(1.25)`; anchored tiles get a `1.2×` size boost (`effectiveSize = isAnchored ? size * 1.2 : size`)
- Animation: `.easeInOut(0.12)` on `isSelected`

## SettingsView

A `TabView` with four tabs:

### Shortcut Tab

- **Input Mode** segmented picker at top: Mouse vs Trackpad (with description text)
- **Activation Method** segmented picker: Keyboard / Mouse Button / Both
- If keyboard or both: shows `ShortcutRecorderView`
- If mouse button or both: shows a picker with Middle Button, Button 4 (Back), Button 5 (Forward)
- **Edge Activation** toggle (auto-switch when cursor reaches ring edge)
- Uses `.formStyle(.grouped)`

### Pinned Tab

- Pinned apps are shown at the top in their pinned order, with a drag-to-reorder handle and an unpin button
- Below, a list of running apps not yet pinned, each with a pin button
- Pinned apps always appear first in the orbit ring at fixed positions for muscle memory
- Refresh button updates the running apps list

### Apps Tab

- Header text explaining the purpose
- `List` of all running GUI apps (`activationPolicy == .regular`), sorted alphabetically
- Each row: 28×28 icon, app name, toggle switch
- Toggle controls whether the app's bundle ID is in `excludedBundleIds`
- Footer: Refresh button + count of hidden apps
- Apps list is refreshed on appear and via the Refresh button

### Dictation Tab

- **Master enable toggle**: "Show dictation languages in the ring" — bound to `SettingsService.dictationEnabled`. Off by default. Caption explains that selecting a tile starts on-device dictation in that language using a local Whisper model and that audio never leaves the Mac.
- **Languages section** (visible only when enabled):
  - Two language pickers ("Language 1" and "Language 2") populated from `DictationService.enabledLocales()`. Each includes a "None" option. Items render as "🇺🇸 English (US)".
  - "Add more languages in System Settings…" button opens `x-apple.systempreferences:com.apple.preference.keyboard?Dictation` via `NSWorkspace.open`.
  - "Refresh list" button re-reads the enabled locales.
- **Speech model section** (visible only when enabled):
  - Picker over `WhisperModelOption.all` (Tiny / Base / Small recommended / Medium / Large v3 Turbo / Large v3) bound to `SettingsService.dictationModelName`. Changing the picker either eagerly loads the new model (if already on disk) or flips `SpeechRecognitionService.modelStatus` to `.notDownloaded` so the status row exposes the Download button for the new selection.
  - Description caption from the matching `WhisperModelOption.description`.
  - Status row driven by `SpeechRecognitionService.modelStatus`:
    - `.notDownloaded` → orange "Not downloaded" with a "Download <label>" button that calls `downloadAndLoadModel`.
    - `.downloading(progress, modelName)` → percentage label + linear `ProgressView`.
    - `.loading(modelName)` → small spinner + "Loading <name>…".
    - `.ready(modelName)` → green checkmark + "Ready (<name>)".
    - `.error(message)` → red triangle, error text, and a Retry button.
- **Status section** (visible only when enabled):
  - Current dictation language row — shows `DictationService.currentLanguage()` or `—`.
  - Explainer caption that recognition runs entirely on-device via WhisperKit, that macOS will prompt for microphone permission on first use, and how to stop a session (indicator click or ESC).
  - "Microphone Privacy…" button that opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`.
- **Microphone section** (always visible, outside the `if dictationEnabled` block):
  - Picker bound to `settings.dictationInputDeviceUID` (`String?`). First option is "System Default" tagged `nil`; remaining options come from `AudioInputDeviceService.listInputDevices()`, each tagged with `Optional(device.uid)` so the stable UID is persisted rather than the transient `AudioDeviceID`.
  - If the stored UID is not in the enumerated list (device disconnected), the picker shows an extra "⚠︎ Not connected (UID)" option so the user is not confused by an apparent silent reset. Selecting "System Default" writes `nil` and clears the warning.
  - "Refresh list" button re-enumerates devices and updates `availableInputDevices` state.
  - Caption explains that this device is used for all dictation and translation, and that "System Default" follows the macOS audio input setting.
  - Visible regardless of `dictationEnabled` or `translateTileEnabled` so the user can pre-configure their mic before enabling either feature.
- **Translation section** (always visible, outside the `if dictationEnabled` block):
  - Toggle "Show translate-to-English tile in Orbit ring" bound to `settings.translateTileEnabled`.
  - Source language picker populated from `DictationService.enabledLocales()` filtered to non-English locales (`!id.hasPrefix("en")`), bound to `settings.translateSourceLocaleId`. Disabled when the toggle is off.
  - When the filtered list is empty, the picker is replaced by an inline warning ("Enable a non-English dictation language in System Settings → Keyboard → Dictation first.") and an "Open Dictation Settings…" button.
  - Caption explains that Orbit speaks in the selected language and transcribes/translates to English using Whisper.
  - Toggling on triggers `SettingsService.ensureAnchorAngles(for:)` so the tile gets an angle on the next ring open.
- Uses `.formStyle(.grouped)`. Enabled locales are loaded via `refreshDictationLocales()` in `onAppear`. The view holds an `@ObservedObject var speech = SpeechRecognitionService.shared` so model status updates re-render the status row live.

### AppInfo Helper

```swift
struct AppInfo: Identifiable {
    let bundleId: String
    let name: String
    let icon: NSImage
    var id: String { bundleId }
}
```

## ShortcutRecorderView

A keyboard shortcut recorder:

- Shows the current shortcut display string, or "Press shortcut…" when recording
- **Record** button starts recording; **Cancel** button stops
- When recording, installs a local keyDown monitor:
  - ESC (without modifiers) cancels recording
  - Any key with at least one modifier (Cmd/Option/Control/Shift) is accepted
  - Converts `NSEvent.modifierFlags` to Carbon modifier constants (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`)
  - Saves keyCode, modifiers, and display name to settings
- Maps special keyCodes to display names (Space, Return, Tab, Delete, arrows, F1–F12, etc.)
- Falls back to `event.charactersIgnoringModifiers?.uppercased()` for regular keys

## Info.plist

Key entries:

| Key                             | Value                                                                                                                                        |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| LSUIElement                     | true (no Dock icon)                                                                                                                          |
| NSAccessibilityUsageDescription | "Orbit needs accessibility access to monitor global keyboard shortcuts and switch between applications."                                     |
| NSMicrophoneUsageDescription    | "Orbit captures microphone audio for on-device speech recognition when you select a language tile in the ring. Audio never leaves your Mac." |
| NSMainNibFile                   | (empty string)                                                                                                                               |
| NSPrincipalClass                | NSApplication                                                                                                                                |

`NSSpeechRecognitionUsageDescription` is intentionally absent — Orbit does not use `SFSpeechRecognizer`, only the microphone via `AVAudioEngine` plus WhisperKit's local CoreML pipeline.

## Entitlements

- `com.apple.security.app-sandbox` = `false`

## Build Configuration

- macOS deployment target: 14.0
- Swift version: 5.9
- Xcode `ASSETCATALOG_COMPILER_APPICON_NAME` = `AppIcon`
- Code sign identity: ad-hoc (`"-"`)

## User Flow

1. User launches Orbit → it appears only in the menu bar (no dock icon)
2. macOS prompts for Accessibility permissions on first launch
3. User presses **Option+Space** (default) → overlay appears centered on mouse cursor
4. Moving the mouse toward an app highlights it (glow + scale + dashed line from center)
5. User can also select apps via **scroll wheel / two-finger swipe** (rotates around the ring) or **arrow keys** (Left/Right)
6. Clicking the highlighted app or pressing **Enter** confirms: overlay dismisses, then the app activates after 50ms
7. Pressing ESC, clicking outside, or pressing the shortcut again dismisses without switching
8. User can choose **Mouse** or **Trackpad** input mode in Settings — trackpad mode has larger targets and sticky selection
9. User can change the trigger (keyboard shortcut or mouse button) and filter apps via Settings
