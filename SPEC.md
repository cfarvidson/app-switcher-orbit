# Orbit — Specification

A macOS radial app switcher inspired by Hitman's weapon wheel. Press a global shortcut to summon a ring of running app icons around your mouse cursor, hover to select, click to switch.

## Platform & Requirements

- macOS 14+ (Sonoma)
- Swift 5.9
- SwiftUI + AppKit hybrid (no storyboards, no XIBs)
- Xcode project with one Swift Package dependency: [FluidAudio](https://github.com/FluidInference/FluidAudio), pinned with `exactVersion: 0.15.5`, which provides the NVIDIA Parakeet TDT 0.6B v3 CoreML speech recognizer used for on-device dictation

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
│   ├── OrbitItem.swift         # Sum type: .app(RunningApp) | .dictation
│   └── RingLayout.swift        # Pure-data ring placement (anchors + gap filling)
├── Services/
│   ├── AppService.swift             # Fetches running GUI apps
│   ├── AudioInputDeviceService.swift # CoreAudio input device enumeration
│   ├── EscapeKeyTap.swift    # CGEvent tap that swallows ESC during a dictation session
│   ├── HotkeyService.swift          # Carbon global hotkey + mouse button monitors
│   ├── OverlayPanel.swift           # Floating transparent NSPanel
│   ├── SettingsService.swift        # UserDefaults persistence (singleton)
│   ├── SpeechRecognitionService.swift # In-process Parakeet pipeline (audio capture, VAD, transcription, text injection)
│   ├── StatusItemController.swift # Menu bar status item: icon states, menu, dictation stop command
│   └── UpdateService.swift          # GitHub release update checker
├── ViewModels/
│   └── OrbitViewModel.swift    # Selection logic, angle math, event monitors
├── Views/
│   ├── OrbitView.swift         # SwiftUI radial layout with hover tracking
│   ├── AppIconView.swift       # Single app icon with selection glow
│   ├── DictationTileView.swift # Dictation tile (mic.fill symbol)
│   ├── LayoutPreviewView.swift # Live preview of the resolved ring; drag pinned apps to set a preferred direction
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

The menu bar status item itself is owned by `StatusItemController`, not `AppDelegate`. `AppDelegate` retains only the menu actions the controller's items target via the responder chain (Settings, About, Check for Updates, Quit) plus the ones it wires up directly (opening the update URL).

Responsibilities:

1. **Accessibility prompt** — on launch, call `AXIsProcessTrustedWithOptions` with the prompt option to request Accessibility permissions. Also detects the **stale-TCC-entry** case (after every rebuild for ad-hoc-signed apps): if `AXIsProcessTrusted()` returns false even though the entry exists in System Settings, shows a custom warning alert with an "Open Privacy Settings…" button explaining the user needs to toggle Orbit off and back on. Without this check the rebuild silently breaks the global hotkey suppression and the dictation paste path because `CGEvent.post` is filtered while the Carbon hotkey keeps working
2. **Menu bar status item** — constructs a `StatusItemController`, passing it the initial activation and input-mode display strings. The status item no longer shows a single fixed symbol; it maps `SpeechRecognitionService.DictationState` to an icon treatment:

   | state        | SF Symbol       | treatment                                                        |
   | ------------ | --------------- | ---------------------------------------------------------------- |
   | idle         | `circle.dotted` | template, full opacity, static                                   |
   | loading      | `circle.dotted` | template, 45% alpha, 1.6 s breathe                               |
   | starting     | `waveform`      | template, 45% alpha, static                                      |
   | listening    | `waveform`      | `NSColor.controlAccentColor`, 1.2 s breathe between 100% and 55% |
   | transcribing | `ellipsis`      | template, full opacity, static                                   |
   - Menu items: Settings (Cmd+,), Check for Updates…, About Orbit, Quit Orbit (Cmd+Q)
   - Disabled info items show current activation method and input mode
   - "Update Available" item inserted at top when a newer GitHub release is found
   - See `## SpeechRecognitionService` → `### Menu bar feedback` for the full icon and menu treatment

3. **Hotkey setup** — create `HotkeyService` with a callback that calls `toggleOrbit()`
4. **Overlay panel** — create a single `OverlayPanel` hosting the `OrbitView`
5. **Settings observation** — use Combine to observe changes to trigger settings (debounced 100ms) and re-register the hotkey
6. **Settings window** - opened as a plain `NSWindow` (520x640) with `NSHostingView<SettingsView>`, not SwiftUI's Settings scene
7. **Toggle logic** — if visible, dismiss; if hidden, get `NSEvent.mouseLocation`, call `viewModel.show()`, then `overlayPanel.showOverlay(at:size:)`. If dictation is currently recording, the trigger stops and commits the session instead of opening the ring.
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

## OrbitItem Model

```swift
enum OrbitItem: Identifiable, Equatable {
    case app(RunningApp)
    case dictation
    var id: String { /* "app:<pid>" or "dictation" */ }
    var displayName: String { /* RunningApp.name or "Dictation" */ }
}
```

The ring consumes `[OrbitItem]` so apps and the dictation tile can coexist. There is exactly one dictation tile and it carries no payload: Parakeet detects the spoken language itself, so there is nothing to select per tile. All ring mechanics (angle math, scroll-to-rotate, arrow navigation, sticky selection) operate on indices over `items`, independent of item type.

## RingLayout

Pure-data layout engine (`enum RingLayout`, no state, no UI). Angles are degrees with 0° at 12 o'clock, increasing clockwise.

```swift
struct Positioned: Equatable {
    let item: OrbitItem
    let angleDegrees: Double
    let isAnchored: Bool
}

static func compute(preferred: [(item: OrbitItem, preferredAngle: Double)],
                    others: [OrbitItem]) -> [Positioned]
static func nextAnchorAngle(existingAngles: [Double]) -> Double
```

The ring is always evenly divided: `n` items (preferred plus others combined) means `n` slots, slot `i` at `i * 360/n` degrees, slot 0 always at twelve o'clock. Pinned apps and the dictation tile carry a _preferred direction_, not a fixed position:

- Every preferred item's direction is normalized and mapped to its ideal slot (`round(angle / step) % n`), and a residual - how far the preference sits from that slot. Claims are ranked by ascending residual (ties broken by normalized angle) so the closest claim is always honored first, rather than depending on the order the caller happened to list them in.
- Each claim, in ranked order, takes its ideal slot if free. If occupied, `firstFreeSlot` walks outward from the ideal slot alternating clockwise and counter-clockwise (offset 1 clockwise, offset 1 counter-clockwise, offset 2 clockwise, …) until it finds an empty one. This always succeeds because preferred items are themselves counted in the slot total, so demand never exceeds supply. Two preferences that resolve to the same ideal slot land on adjacent slots instead of stacking.
- Every slot left unclaimed after all preferred items are placed is filled with `others` in the order given.
- With zero items, `compute` returns an empty array.

`nextAnchorAngle` returns the angle for a newly anchored item: `0` when there are no anchors, the point opposite the single existing anchor when there is one, otherwise the midpoint of the largest empty arc. Duplicate angles in the input are tolerated and contribute a zero-width gap, never a full circle; if every anchor sits at the same angle there is no arc to measure and the result is the opposite point. `compute` now separates duplicate preferences onto adjacent slots via the outward search above, so the stacking failure this function used to guard against - two anchors sharing an angle rendering on the same point, with the later one taking the hit-testing - can no longer happen.

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

| Property                       | Type                                   | Default            | UserDefaults Key                 |
| ------------------------------ | -------------------------------------- | ------------------ | -------------------------------- |
| triggerType                    | `.keyboard` / `.mouseButton` / `.both` | `.keyboard`        | `triggerType`                    |
| inputMode                      | `.mouse` / `.trackpad`                 | `.mouse`           | `inputMode`                      |
| keyCode                        | `UInt32`                               | `kVK_Space` (49)   | `keyCode`                        |
| modifiers                      | `UInt32`                               | `optionKey` (2048) | `modifiers`                      |
| keyDisplayName                 | `String`                               | `"Space"`          | `keyDisplayName`                 |
| mouseButton                    | `Int`                                  | `2` (middle)       | `mouseButton`                    |
| edgeActivation                 | `Bool`                                 | `false`            | `edgeActivation`                 |
| pinnedBundleIds                | `[String]`                             | `[]`               | `pinnedBundleIds`                |
| excludedBundleIds              | `Set<String>`                          | `[]`               | `excludedBundleIds`              |
| dictationEnabled               | `Bool`                                 | `false`            | `dictationEnabled`               |
| dictationSilenceTriggerSeconds | `Double`                               | `0.8`              | `dictationSilenceTriggerSeconds` |
| pinnedPreferredAngles          | `[String: Double]`                     | `[:]`              | `pinnedAngles`                   |
| dictationPreferredAngle        | `Double?`                              | `nil`              | `dictationAngle`                 |
| dictationInputDeviceUID        | `String?`                              | `nil`              | `dictationInputDeviceUID`        |

The `pinnedAngles` / `dictationAngle` UserDefaults keys deliberately keep their pre-rename names even though the Swift properties are now `pinnedPreferredAngles` / `dictationPreferredAngle`. Renaming the keys to match would mean existing installs read back empty defaults on upgrade and silently lose every user's saved layout. Do not "fix" this mismatch.

All properties are `@Published`. The `save()` method writes all properties to UserDefaults; the two optional keys (`dictationAngle`, `dictationInputDeviceUID`) are removed from the domain rather than written when they are `nil`.

`dictationEnabled` defaults to `false` so existing users do not get a surprise tile after upgrading. `dictationPreferredAngle` is assigned by `ensurePreferredAngles()` the first time dictation is enabled and is preserved when the tile is toggled off - re-enabling restores the same preferred direction. `pinnedPreferredAngles` maps bundle id to a preferred direction in degrees clockwise from 12 o'clock - a direction the ring solver aims for, not a position the item is guaranteed to occupy; `RingLayout.compute` resolves it onto whichever evenly-spaced slot sits closest. It is read back through a manual `NSNumber`/`Double` walk because `dictionary(forKey:) as? [String: Double]` does not round-trip reliably through UserDefaults. `dictationInputDeviceUID` stores the CoreAudio `kAudioDevicePropertyDeviceUID` string (e.g. `"BuiltInMicrophoneDevice"`); `nil` means follow the system default input device.

### Layout preferences

- `allPreferredAngles: [Double]` - every stored preferred angle (pinned apps plus the dictation tile) in one flat list, used as the input to `RingLayout.nextAnchorAngle`.
- `ensurePreferredAngles()` - assigns a preferred angle to every pinned bundle id that lacks one and to the dictation tile when `dictationEnabled` is true, prunes angles for bundle ids that are no longer pinned, and saves if anything changed. Called at the start of every `OrbitViewModel.show()` and when the dictation toggle is switched on.
- `resetLayoutAngles()` - clears `pinnedPreferredAngles` and `dictationPreferredAngle` and saves; the next `ensurePreferredAngles()` reassigns defaults.

### Computed Properties

- `shortcutDisplayString` — builds a string like "⌥ Space" from modifier flags and key name, using Unicode symbols (⌃ ⌥ ⇧ ⌘)
- `mouseButtonDisplayName` — human-readable name for the selected mouse button

### Stale keys from earlier versions

Orbit does not read or migrate defaults keys written by versions before 2.0.0: `dictationLanguage1Id`, `dictationLanguage2Id`, `dictationModelName`, `languageAngles`, `translateTileEnabled`, `translateSourceLocaleId` and `translateAngle`. They are left in the domain untouched. A rebuild does not need to handle them.

### macOS system Dictation

Orbit does not read or write `com.apple.speech.recognition.AppleSpeechRecognition.prefs` and never invokes macOS's built-in DictationIM. Earlier versions did: they synthesized the user's dictation shortcut via `CGPostKeyboardEvent`, then walked the frontmost app's `Edit → Start Dictation…` menu via the Accessibility API, and mirrored the selected locale into the plist. All of it was abandoned. DictationIM consistently died ~1.4 s after start with `(null)` errors, its locale cache required process kills that opened windows where synthesized events were dropped, and the surface is undocumented. Recognition runs entirely inside Orbit instead. Do not reintroduce this path.

## SpeechRecognitionService

`ObservableObject` singleton (`SpeechRecognitionService.shared`) that runs the entire dictation pipeline in-process on NVIDIA Parakeet TDT 0.6B v3, a transducer ASR model executed as CoreML on Apple Silicon through the FluidAudio package. Parakeet auto-detects the spoken language across 25 European languages and emits punctuation and capitalization, so there is no locale to configure and nothing to select per session.

The service holds a `FluidAudio.AsrManager` (`private var asrManager: AsrManager?`), created and loaded once and reused for every session.

Public API:

- `startDictation(onError:)` - starts a session. Takes no locale and no task. Delegates to the private `startInternal(onError:)`.
- `warmupAudioCapture()` / `cancelWarmup()` - pre-roll capture, described below.
- `stop(reason:flushBuffer:)` - ends a session, optionally transcribing whatever is still buffered.
- `prewarm()` - loads an already-downloaded model into RAM at launch; never downloads.
- `downloadAndLoadModel()` - the Settings entry point; downloads if needed, then loads.
- `isModelDownloaded()` - presence check against FluidAudio's model cache, no network, no load.
- `modelStatus` - `@Published` lifecycle state driving the Settings UI.

### Pipeline

1. `AVAudioEngine` taps the input node and runs samples through an `AVAudioConverter` to 16 kHz mono Float32 (the format Parakeet expects).
2. Each tap callback computes RMS amplitude over the converted samples for a cheap voice-activity detector. Above the threshold = speech, below = silence.
3. After `SettingsService.dictationSilenceTriggerSeconds` of continuous silence following speech (and at least `minSpeechSeconds` of speech in the buffer), or after a hard `maxBufferSeconds` cap, the buffered audio is handed to `AsrManager.transcribe(_:decoderState:)`. Each flush allocates a **fresh** `TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)`: a flush is one complete utterance, so there is no decoder continuity to carry across calls. No language argument is passed - the model detects it.
4. The resulting transcript is filtered (a transcript wrapped entirely in `[...]` or `(...)` is dropped, and both the ASCII `...` and the Unicode `…` ellipsis forms are stripped because the model emits them for mid-sentence pauses, then any resulting double spaces are collapsed to single spaces and the result re-trimmed) and injected into the frontmost app via the **clipboard-paste path** described below. Consecutive utterances within a session are joined with a single space.
5. ESC cancels the session (discards the buffer). Clicking the floating indicator, re-triggering Orbit, or hitting the 60 s hard cap commits the session - `stop(reason:flushBuffer:)` runs a final transcription on whatever's still in the buffer before tearing down, so the natural "speak then press hotkey to stop" flow doesn't lose the last utterance. The final flush is skipped when a VAD-triggered transcription is already in flight (`transcribing == true`): that in-flight task still injects its own result, and the few hundred ms captured after it was dispatched would only transcribe as a broken fragment.

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

| Parameter                                        | Value           | Purpose                                                             |
| ------------------------------------------------ | --------------- | ------------------------------------------------------------------- |
| `speechRmsThreshold`                             | `0.012`         | Empirically tuned: quiet speech passes, baseline room noise doesn't |
| `SettingsService.dictationSilenceTriggerSeconds` | `0.8` (0.5-3.0) | How long to wait after speech before flushing; user-adjustable      |
| `minSpeechSeconds`                               | `0.3`           | Don't bother transcribing very short blips                          |
| `maxBufferSeconds`                               | `25.0`          | Hard cap so a sustained "uhhh" can't accumulate forever             |

Everything except the silence trigger is a compile-time constant on the service; the silence trigger is read from `SettingsService` on every tap callback so the Settings slider takes effect mid-session.

We deliberately do **not** transcribe on a fixed timer. Re-decoding the whole growing buffer on each pass makes the emitted text drift as more context arrives (e.g. "stad oskiven omting" → "starta och skriva någonting"). VAD-based one-shot flushes avoid that.

### Model lifecycle

- **Model:** one fixed model, `SpeechRecognitionService.modelDisplayName` = `"Parakeet TDT 0.6B v3"`. There is no picker and no catalog.
- **Cache location:** FluidAudio's own model cache, `AsrModels.defaultCacheDirectory(for: .v3)`, which resolves to `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3/`. `isModelDownloaded()` is `AsrModels.modelsExist(at:version:)` against that directory.
- **Download:** `downloadAndLoadModel()` calls `AsrModels.downloadAndLoad(version: .v3)` with a progress callback that republishes `progress.fractionCompleted` into `modelStatus`, then constructs `AsrManager(config: .default)` and calls `loadModels(_:)`. Idempotent - a call while a download is in flight, or after the manager already exists, is a no-op. Downloads only ever happen from explicit user actions in Settings → Dictation; clicking the dictation tile never triggers one.
- **Prewarm:** `AppDelegate.applicationDidFinishLaunching` calls `prewarm()` if dictation is enabled. Prewarm loads an already-downloaded model into RAM at startup but never initiates a download.
- **Status:** `@Published var modelStatus: ModelStatus`, where `ModelStatus` is `.notDownloaded` / `.downloading(progress: Double)` / `.loading` / `.ready` / `.error(String)`. No case carries a model name, because there is only one model.

### Models left behind by earlier versions

Versions before 2.0.0 ran WhisperKit and cached its models under `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/`. Orbit deliberately does not touch that directory: deleting files a previous version downloaded into the user's Documents folder is not something an app should do behind the user's back, and a user who downgrades would have to fetch them again. The directory can run to several GB and is safe for the user to delete by hand. A rebuild should reproduce this behavior, which is to say it should do nothing at all.

### Permissions

`ensurePermissions` uses `AVCaptureDevice.authorizationStatus(for: .audio)` and `AVCaptureDevice.requestAccess(for: .audio)` for the microphone. `Speech.framework` is not used, so `NSSpeechRecognitionUsageDescription` is intentionally absent from `Info.plist`. Accessibility is also required, for both the global hotkey (see `## HotkeyService`), text injection (see `### Text injection` above), and now Escape interception during a session (see `### Escape handling` below) - Orbit already requests Accessibility on launch (`## AppDelegate`), so dictation adds no new prompt.

### Escape handling

An `EscapeKeyTap` (`Orbit/Services/EscapeKeyTap.swift`) is installed for the duration of a session via `installEscMonitor()` and torn down in `stop(reason:flushBuffer:)`. It wraps a `CGEvent` tap (`CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, …)`) that is the only way to _consume_ a key press out of another app's event stream - `NSEvent.addGlobalMonitorForEvents` can observe but never swallow.

- The tap's event mask covers both `keyDown` and `keyUp` for keycode 53 (Escape). Both are swallowed so an app that acts on key-up never sees a release with no matching press.
- On `keyDown` for Escape, the tap hops to the main queue asynchronously and calls its `onEscape` closure, which calls `stop(reason: "esc", flushBuffer: false)` - Escape **cancels**, it does not commit: the buffer is discarded rather than transcribed, matching macOS's own Dictation. Every other way of ending a session (re-triggering Orbit, "Stop Dictation" in the menu bar, the 60 s hard cap) commits by running a final flush.
- Returning `nil` from the tap callback for a matched Escape event is what swallows it; every other event (including the `keyUp` half of Escape) passes through via `Unmanaged.passUnretained(event)`.
- The callback also watches for `.tapDisabledByTimeout` and `.tapDisabledByUserInput` - macOS disables a tap that responds too slowly or when input state resets - and re-enables the tap immediately via `CGEvent.tapEnable(tap:enable:)` rather than silently going deaf for the rest of the session.
- Creating the tap requires Accessibility permission. `EscapeKeyTap.start()` returns `false` when `CGEvent.tapCreate` fails, and `installEscMonitor()` falls back to an observe-only `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` global monitor. In that fallback, Escape still cancels the session, but it is not consumed - it also reaches the frontmost app, exactly as before this feature existed.

### Error surfacing

`startInternal(onError:)` runs three pre-flight checks before capture begins. Each failure both reports the error via the `onError` callback and shows a user-visible NSAlert so the failure isn't silent:

| Failure                      | Alert                                                                                |
| ---------------------------- | ------------------------------------------------------------------------------------ |
| Model not downloaded         | "Dictation needs setup" → opens Orbit Settings via `.orbitOpenSettings` notification |
| Microphone permission denied | "Microphone access denied" → opens System Settings → Privacy & Security → Microphone |
| Audio engine fails to start  | NSLogged; `onError` reports the underlying error                                     |

### Re-entrancy and lockout

`startInternal` is guarded by a 0.75 s `startLockout` and a `starting` re-entrancy flag so back-to-back triggers (e.g. a double-click) don't pile up sessions. If a session is already running, `stop(reason:)` is called first; the toggle handler in `AppDelegate.toggleOrbit` also calls `stop` when the user re-presses the global trigger while dictation is active.

### Menu bar feedback

There is no floating panel. Dictation feedback lives entirely in the menu bar icon, owned by `StatusItemController` (see `## AppDelegate` for the icon/treatment table).

`SpeechRecognitionService` publishes `@Published private(set) var dictationState: DictationState`:

```swift
enum DictationState: Equatable {
    case idle
    case loading(message: String)
    case starting
    case listening
    case transcribing
}
```

- `.idle` - no session active.
- `.loading(message:)` - the Parakeet model is being loaded into memory for the first time in this run; `message` is shown as the disabled menu status line (e.g. `"Loading model…"`).
- `.starting` - the audio engine has started but hasn't delivered its first buffer yet (`AVAudioEngine.start()` returns 100-300 ms before capture actually begins).
- `.listening` - actively capturing. This is the state for the entire duration of the session, including every VAD-triggered mid-session flush - `.transcribing` is deliberately **not** used there. Flipping the icon on every natural pause between utterances would strobe it; the icon should read "session is live," not "a network call is in flight right now."
- `.transcribing` - covers only the post-stop final flush that `stop(reason:flushBuffer:)` runs on whatever's left in the buffer. It is the last state before returning to `.idle`.

`StatusItemController` observes `dictationState` via Combine (`removeDuplicates()`, delivered on the main run loop) and maps each case to an `IconStyle` (SF Symbol, tinted or not, base alpha, optional breathe period) - the table is in `## AppDelegate`. The accent used for `.listening` is `NSColor.controlAccentColor`, applied via `button.contentTintColor`; every other state clears `contentTintColor` and relies on the image being a template (`isTemplate = true`) so it renders in the system's default menu bar color.

The breathe animation is a 30 fps (`1/30 s` tick) `Timer` added to `RunLoop.main` in `.common` mode - `.common` so it keeps ticking while a menu is open, which the default run loop mode would pause. Each tick advances a phase accumulator and sets `button.alphaValue` to oscillate between `baseAlpha` and 55% of `baseAlpha` on a sine wave. The timer is invalidated (and alpha reset to the state's static value) on every transition to a state with no `breathePeriod`.

While a session is live (any state but `.idle`), `StatusItemController` inserts a disabled status line plus a "Stop Dictation" command at the top of the menu, above a separator, and removes both when the state returns to `.idle`. This is the replacement for the old panel's click-to-stop; the status line text is `.loading`'s message, `"Starting…"`, `"Listening…"`, or `"Transcribing…"` depending on state. "Stop Dictation" calls `SpeechRecognitionService.shared.stop(reason:)`.

### Notification

`Notification.Name.orbitOpenSettings` is posted when the user clicks "Open Settings…" on the missing-model alert. `AppDelegate` listens for it and opens its Settings window.

### Input device selection

At the very top of `beginCapture`, before reading `inputNode.outputFormat`, the service checks `SettingsService.shared.dictationInputDeviceUID`. If non-nil, it resolves the UID to a live `AudioDeviceID` via `AudioInputDeviceService.audioDeviceID(forUID:)` and sets `kAudioOutputUnitProperty_CurrentDevice` on `audioEngine.inputNode.audioUnit` via `AudioUnitSetProperty`. Changing the device before installing the tap is required because the tap format is derived from the active device. If the stored UID does not resolve (device disconnected), the service logs a fallback line and proceeds with the system default — no alert, as unplugging a mic is a normal operating condition.

### Pre-roll capture (warmup)

When the Orbit ring opens, `OrbitViewModel.show()` calls `SpeechRecognitionService.shared.warmupAudioCapture()` (gated on `dictationEnabled`). This starts the audio engine in a "warmup" mode that fills a 2-second circular `prerollBuffer` (32 000 samples at 16 kHz) without changing `dictationState` away from `.idle` or committing to a session - so the menu bar icon stays at rest during warmup. It is a no-op when a session is already running, when warmup is already active, or when microphone permission has not already been granted - opening the ring must never trigger a permission prompt.

If the user clicks the dictation tile, `startInternal` detects warmup is active and calls `promoteWarmupToSession`, which atomically swaps the preroll contents into the session's `audioBuffer` under `audioBufferQueue.sync`. The engine continues running without restart - the user benefits from the audio captured before the click, eliminating the first-words-dropped problem caused by `AVAudioEngine.start()`'s 100-300ms startup latency. Because the engine has been delivering buffers since warmup began, `promoteWarmupToSession` sets `dictationState` straight to `.listening`, skipping `.starting` entirely - there is no startup gap to show.

If the user dismisses the ring without clicking a tile, `OrbitViewModel.dismiss()` calls `cancelWarmup()` which stops the engine and discards the preroll buffer.

**Trade-off:** the macOS mic privacy LED in the menu bar lights for the duration the ring is visible, even if the user doesn't dictate. This is the visible cost of pre-roll capture.

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
| radius          | 180pt      | 230pt         |
| iconSize        | 56pt       | 68pt          |
| orbitSize       | 480pt      | 600pt         |
| deadZone        | 45pt       | 55pt          |
| stickySelection | false      | true          |

### Key Properties

- `isVisible: Bool` — controls overlay visibility
- `positionedItems: [RingLayout.Positioned]` - the laid-out ring: each entry pairs an `OrbitItem` with its angle and whether it is anchored
- `items: [OrbitItem]` - convenience projection of `positionedItems` for the call sites that only care about count and index semantics
- `selectedIndex: Int?` — which item is highlighted
- `onDismiss: (() -> Void)?` — callback to hide the overlay panel

### Ring Contents (show)

On each `show()`:

1. `SettingsService.ensurePreferredAngles()` runs first, so every pinned app and the dictation tile have a preferred angle before layout.
2. A `preferred` list of `(item, preferredAngle)` directions is built: `(.dictation, dictationPreferredAngle)` when `dictationEnabled` and a preference exists, then one entry per pinned app that has a stored preference.
3. `AppService.runningApps(excluding:pinnedFirst:)` is split into pinned and non-pinned; the non-pinned apps become `others`.
4. `RingLayout.compute(preferred:others:)` resolves every preference onto the evenly spaced slot nearest it, fills the remaining slots with `others`, and returns `positionedItems` sorted clockwise from 12 o'clock. See `## RingLayout` for the slot-resolution algorithm.
5. `warmupAudioCapture()` is called when `dictationEnabled` is true.

### Angle & Position Math

- Angles are stored and laid out as degrees clockwise from 12 o'clock. `RingLayout` owns the placement; the view model only renders and hit-tests them.
- `positionForIndex` converts a stored angle to a SwiftUI point (y grows downward): `x = center.x + radius × sin(θ)`, `y = center.y - radius × cos(θ)`. So 0° is the top, 90° the right, 180° the bottom, 270° the left.
- `angleForIndex` converts the same stored angle into the math convention used by the mouse-angle comparison (radians, 0 at +x, counter-clockwise positive): `π/2 - θ`.

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
  - `.dictation` - calls `SpeechRecognitionService.shared.startDictation(onError:)`, logging any error
- The delay ensures the overlay is fully hidden before activation or dictation start

## OrbitView (SwiftUI)

Layered inside a `ZStack`, only rendered when `viewModel.isVisible`:

1. **Background** — `Circle` with `.ultraThinMaterial` fill, size = `orbitSize - 40`, opacity 0.9, tap to dismiss
2. **Ring guide** — `Circle` stroke, white at 10% opacity, 1pt line, diameter = `radius × 2`
3. **Center dot** — 6pt white circle at 40% opacity
4. **Selection line** — dashed `Path` from center to selected app's position, accent color at 40% opacity, dash pattern `[4, 4]`
5. **Ring items** - `ForEach` over enumerated `viewModel.positionedItems`, switching on `OrbitItem` to render an `AppIconView` (for `.app`) or a `DictationTileView` (for `.dictation`). Both receive the entry's `isAnchored` flag. Each is positioned via `.position()`; tap sets `selectedIndex` and triggers `selectAndSwitch()`.
6. **Item label** - shown when an item is selected, centered below the middle in a capsule with `.ultraThinMaterial`. Reads `viewModel.items[index].displayName`, so it renders the app name or "Dictation".

### Interactions

- `onContinuousHover` tracks mouse position and calls `viewModel.updateSelection(mouseInView:)`
- On hover ended, delegates to `viewModel.handleHoverEnded()` (clears selection in mouse mode, preserves in trackpad mode)
- Animations: `.easeOut(0.2)` on visibility, `.interpolatingSpring(stiffness: 300, damping: 25)` on selection changes (interruptible for rapid scroll/arrow input)

## AppIconView

Displays a single app icon:

- `Image(nsImage:)` resized to `effectiveSize × effectiveSize` with `.aspectRatio(.fit)`, where `effectiveSize = isAnchored ? size * 1.2 : size` - anchored (pinned) icons render 20% larger so the user's curated apps outweigh the transient running-app crowd
- Clipped to `RoundedRectangle(cornerRadius: 12)`
- When selected:
  - Blue glow shadow (accent color, 80% opacity, radius 12)
  - Accent color border stroke (2.5pt)
  - Scale up to 1.25×
- Animation: `.easeInOut(0.12)` on `isSelected`

## DictationTileView

Displays the single dictation tile. Visually mirrors `AppIconView` so both item types share the same affordances (rounded rect, selection glow, stroke, scale).

- `RoundedRectangle(cornerRadius: 12)` filled with `.ultraThinMaterial`
- `Image(systemName: "mic.fill")` centered, at `effectiveSize * 0.5`, `.medium` weight, `.primary` foreground. No flag and no locale badge: the tile is language-agnostic
- Same `effectiveSize` rule as `AppIconView` (`isAnchored ? size * 1.2 : size`). The tile is always anchored in the real ring, so `isAnchored` defaults to `true` and only `OrbitView` instantiates this view. `LayoutPreviewView` no longer builds a `DictationTileView` at all - it renders its own inline tile (a material rounded rect with `mic.fill`) sized and dimmed directly from `RingLayout.Positioned.isAnchored`, the same way it draws app icons inline rather than through `AppIconView`, so its preview matches `RingLayout.compute`'s output exactly without depending on the ring's own SwiftUI views
- Same selection treatment as `AppIconView`: accent glow + stroke + `scaleEffect(1.25)`
- Animation: `.easeInOut(0.12)` on `isSelected`

## SettingsView

A `TabView` with five tabs (Shortcut, Pinned, Apps, Dictation, Layout). The view sets `.frame(width: 520, height: 800)`; the window `AppDelegate` puts it in is 520x640, so the tab content is taller than the window. `onAppear` refreshes both the running-app list and the audio input device list.

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

There are no language pickers and no model picker: Parakeet detects the language itself and Orbit ships one model.

- **Master enable toggle**: "Show the dictation tile in the ring" - bound to `SettingsService.dictationEnabled`. Off by default. Caption explains that selecting the tile starts on-device dictation, that the spoken language is detected automatically, and that no audio leaves the Mac. Switching it on calls `SettingsService.ensurePreferredAngles()` so the tile has a preferred direction the next time the ring opens.
- **Speech model section** (visible only when enabled):
  - Static name row showing `SpeechRecognitionService.modelDisplayName`, with a caption that it runs on-device via CoreML and covers 25 European languages with automatic language detection, punctuation and capitalization.
  - Status row driven by `SpeechRecognitionService.modelStatus`:
    - `.notDownloaded` → orange "Not downloaded" with a "Download Parakeet TDT 0.6B v3" button that calls `downloadAndLoadModel()`.
    - `.downloading(progress)` → "Downloading…", percentage label, and a linear `ProgressView`.
    - `.loading` → small spinner + "Loading…".
    - `.ready` → green checkmark + "Ready".
    - `.error(message)` → red triangle, the message, and a Retry button.
  - Explainer caption that Orbit runs Parakeet TDT 0.6B v3 locally via FluidAudio (CoreML on Apple Silicon), that recognition bypasses the system Dictation HUD, that macOS will prompt for microphone permission on first use, and how to stop a session (indicator click or ESC). Followed by a "Microphone Privacy…" button that opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`.
- **Microphone section** (always visible, outside the `if dictationEnabled` block, so the user can pre-configure the mic before enabling dictation):
  - Picker bound to `settings.dictationInputDeviceUID` (`String?`). First option is "System Default" tagged `nil`; remaining options come from `AudioInputDeviceService.listInputDevices()`, each tagged with `Optional(device.uid)` so the stable UID is persisted rather than the transient `AudioDeviceID`.
  - If the stored UID is not in the enumerated list (device disconnected), the picker shows an extra "⚠︎ Not connected (UID)" option so the user is not confused by an apparent silent reset. Selecting "System Default" writes `nil` and clears the warning.
  - "Refresh list" button re-enumerates devices and updates `availableInputDevices` state.
  - Caption explains that this device is used for dictation and that "System Default" follows the macOS audio input setting.
  - Below a `Divider`, a **Pause tolerance** slider bound to `settings.dictationSilenceTriggerSeconds`, range 0.5-3.0 in 0.1 steps, with the current value shown as e.g. "0.8s" in monospaced digits. Caption explains that it is how long Orbit waits in silence before transcribing, and that higher values let the user pause mid-sentence without fragmenting the output.
- Uses `.formStyle(.grouped)`. The view holds an `@ObservedObject var speech = SpeechRecognitionService.shared` so model status updates re-render the status row live.

### Layout Tab

Hosts `LayoutPreviewView`, a 280pt circular live simulation of the real ring - it calls the exact same `RingLayout.compute(preferred:others:)` the ring uses, so what's shown here is what the ring will actually do, not an abstract approximation.

- **Every running app is shown**, not just the pinned ones. Pinned apps and the dictation tile are drawn at 44pt, full opacity, and are draggable. Every other running app is drawn at 26pt, 35% opacity, and is not hit-testable (`allowsHitTesting(false)`) - it fills whatever slot is left over, exactly like it would in the real ring.
- **Free drag, no snapping.** Dragging a pinned item or the dictation tile follows the cursor continuously - there is no angle snapping, no collision threshold, and no outward search step; none of that exists anymore. The solver in `RingLayout.compute` always quantizes to evenly spaced slots regardless of the exact drag angle, so snapping the drag itself would be redundant.
- While dragging, a hairline `Path` from the center shows the raw pointer direction, and a small accent-colored dot marks the slot the item will actually resolve to - so the difference between "where you dragged it" and "which slot it will claim" is visible live.
- On drag end, the raw angle (not the resolved slot) is written back to `SettingsService.pinnedPreferredAngles[bundleId]` or `SettingsService.dictationPreferredAngle` - it's a preference, not a position, so the exact value matters for future re-resolution as the running-app set changes.
- A "Reset to default layout" button calls `SettingsService.resetLayoutAngles()`; it's disabled when there is nothing pinned and dictation is off. When nothing is anchored the preview shows "Nothing pinned yet.\nPin an app or enable dictation to place it here." over the (all-dimmed) ring.

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

| Key                             | Value                                                                                                                                           |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| LSUIElement                     | true (no Dock icon)                                                                                                                             |
| NSAccessibilityUsageDescription | "Orbit needs accessibility access to monitor global keyboard shortcuts and switch between applications."                                        |
| NSMicrophoneUsageDescription    | "Orbit captures microphone audio for on-device speech recognition when you select the dictation tile in the ring. Audio never leaves your Mac." |
| NSMainNibFile                   | (empty string)                                                                                                                                  |
| NSPrincipalClass                | NSApplication                                                                                                                                   |

`NSSpeechRecognitionUsageDescription` is intentionally absent - Orbit does not use `SFSpeechRecognizer`, only the microphone via `AVAudioEngine` plus Parakeet's local CoreML pipeline.

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
