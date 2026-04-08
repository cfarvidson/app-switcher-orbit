# Orbit — Specification

A macOS radial app switcher inspired by Hitman's weapon wheel. Press a global shortcut to summon a ring of running app icons around your mouse cursor, hover to select, click to switch.

## Platform & Requirements

- macOS 14+ (Sonoma)
- Swift 5.9
- SwiftUI + AppKit hybrid (no storyboards, no XIBs)
- Xcode project (not Swift Package Manager)
- No third-party dependencies

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
│   └── OrbitItem.swift         # Sum type: .app(RunningApp) | .language(DictationLanguage)
├── Services/
│   ├── AppService.swift        # Fetches running GUI apps
│   ├── HotkeyService.swift     # Carbon global hotkey + mouse button monitors
│   ├── OverlayPanel.swift      # Floating transparent NSPanel
│   ├── SettingsService.swift   # UserDefaults persistence (singleton)
│   ├── DictationService.swift  # macOS dictation language switching + shortcut synthesis
│   └── UpdateService.swift     # GitHub release update checker
├── ViewModels/
│   └── OrbitViewModel.swift    # Selection logic, angle math, event monitors
├── Views/
│   ├── OrbitView.swift         # SwiftUI radial layout with hover tracking
│   ├── AppIconView.swift       # Single app icon with selection glow
│   ├── LanguageTileView.swift  # Dictation language tile (flag emoji + locale badge)
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

1. **Accessibility prompt** — on launch, call `AXIsProcessTrustedWithOptions` with the prompt option to request Accessibility permissions
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
    var id: String { /* "app:<pid>" or "lang:<locale>" */ }
    var displayName: String { /* RunningApp.name or DictationLanguage.displayName */ }
}
```

The ring consumes `[OrbitItem]` so apps and dictation languages can coexist. All ring mechanics (angle math, scroll-to-rotate, arrow navigation, sticky selection) operate on indices over `items`, independent of item type.

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

| Property             | Type                                   | Default            | UserDefaults Key       |
| -------------------- | -------------------------------------- | ------------------ | ---------------------- |
| triggerType          | `.keyboard` / `.mouseButton` / `.both` | `.keyboard`        | `triggerType`          |
| inputMode            | `.mouse` / `.trackpad`                 | `.mouse`           | `inputMode`            |
| keyCode              | `UInt32`                               | `kVK_Space` (49)   | `keyCode`              |
| modifiers            | `UInt32`                               | `optionKey` (2048) | `modifiers`            |
| keyDisplayName       | `String`                               | `"Space"`          | `keyDisplayName`       |
| mouseButton          | `Int`                                  | `2` (middle)       | `mouseButton`          |
| edgeActivation       | `Bool`                                 | `false`            | `edgeActivation`       |
| pinnedBundleIds      | `[String]`                             | `[]`               | `pinnedBundleIds`      |
| excludedBundleIds    | `Set<String>`                          | `[]`               | `excludedBundleIds`    |
| dictationEnabled     | `Bool`                                 | `false`            | `dictationEnabled`     |
| dictationLanguage1Id | `String?`                              | `nil`              | `dictationLanguage1Id` |
| dictationLanguage2Id | `String?`                              | `nil`              | `dictationLanguage2Id` |

All properties are `@Published`. The `save()` method writes all properties to UserDefaults.

### Computed Properties

- `shortcutDisplayString` — builds a string like "⌥ Space" from modifier flags and key name, using Unicode symbols (⌃ ⌥ ⇧ ⌘)
- `mouseButtonDisplayName` — human-readable name for the selected mouse button
- `dictationLanguages: [DictationLanguage]` — resolved language tiles for the ring. Empty when `dictationEnabled` is false or no language ids are stored. Builds one `DictationLanguage` per non-nil id via `DictationLanguage.from(localeId:)`.

## DictationService

Stateless enum that reads and writes macOS built-in Dictation state via undocumented plist keys (verified on macOS 15.7.4 against open-source references such as tom-barone/dotfiles, benthamite/dotfiles, and ntkme/Swift-Dictation).

### Plist surface

- **Domain:** `com.apple.speech.recognition.AppleSpeechRecognition.prefs`
- **Active language key:** `DictationIMNetworkBasedLocaleIdentifier` (String, underscore locale format, e.g. `"en_US"`)
- **Preference order key:** `DictationIMPreferredLanguageIdentifiers` (Array<String>) — reordered so the target locale is first
- **Enabled locales key:** `VisibleNetworkSRLocaleIdentifiers` (Dict<String, Int>; `1` = enabled)
- **Shortcut key:** `CustomizedDictationHotKey` (Dict: `keyChar`, `virtualKey`, `modifiers` as NSEvent-style bitmask). Fallback source: `com.apple.symbolichotkeys.plist` → `AppleSymbolicHotKeys[164]`.
- **Daemon to restart:** `com.apple.inputmethod.ironwood` (DictationIM.app), gracefully terminated via `NSRunningApplication.terminate()`. `launchd` (ThrottleInterval=1) respawns on demand when the synthesized shortcut hits its MachService. **Not** `corespeechd`.

### API

- `enabledLocales() -> [DictationLanguage]` — reads `VisibleNetworkSRLocaleIdentifiers`, returns enabled entries, preserving `DictationIMPreferredLanguageIdentifiers` order.
- `currentLanguage() -> String?` — reads `DictationIMNetworkBasedLocaleIdentifier`.
- `dictationShortcut() -> (CGKeyCode, CGEventFlags)?` — returns nil on "Press Fn twice" (virtualKey == 65535) or disabled. Falls back to `AppleSymbolicHotKeys[164]` if `CustomizedDictationHotKey` is absent.
- `setLanguage(_ localeId:) -> Bool` — idempotent. Writes the active locale and reorders the preferred-language array; gracefully terminates DictationIM. Returns `true` when a restart was triggered (`false` when target already active). Performs a read-back verification after the write; mismatches are logged via `os.Logger`.
- `startDictation()` — synthesizes the user's configured dictation shortcut via `CGEvent.post(tap: .cghidEventTap)` using a `CGEventSource(stateID: .hidSystemState)`. No-op if no valid shortcut.
- `switchLanguageAndStart(_ localeId:)` — chains `setLanguage` and `startDictation`. Waits ~75ms between them only when a restart was triggered; zero delay on the fast path.

### Known limitation

Apple Feedback FB9093710 confirms that the `fn` modifier cannot be reliably synthesized via `CGEvent`. When the user's dictation shortcut is set to the default "Press Fn twice", `dictationShortcut()` returns nil and `startDictation()` is a no-op. The Dictation settings tab detects this and shows an orange warning with a deep link to System Settings → Keyboard → Dictation.

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

On each `show()`, the ring is rebuilt as:

```
items = SettingsService.dictationLanguages.map(.language) + AppService.runningApps(...).map(.app)
```

Languages come first so their ring positions remain stable regardless of which apps are running (muscle memory). Languages only appear when `SettingsService.dictationEnabled == true` and at least one language id is stored.

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
- The delay ensures the overlay is fully hidden before activation or language switch

## OrbitView (SwiftUI)

Layered inside a `ZStack`, only rendered when `viewModel.isVisible`:

1. **Background** — `Circle` with `.ultraThinMaterial` fill, size = `orbitSize - 40`, opacity 0.9, tap to dismiss
2. **Ring guide** — `Circle` stroke, white at 10% opacity, 1pt line, diameter = `radius × 2`
3. **Center dot** — 6pt white circle at 40% opacity
4. **Selection line** — dashed `Path` from center to selected app's position, accent color at 40% opacity, dash pattern `[4, 4]`
5. **Ring items** — `ForEach` over enumerated `viewModel.items`, switching on `OrbitItem` to render either an `AppIconView` (for `.app`) or a `LanguageTileView` (for `.language`). Each is positioned via `.position()`; tap triggers `selectAndSwitch()`.
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

- **Master enable toggle**: "Show dictation languages in the ring" — bound to `SettingsService.dictationEnabled`. Off by default because writing the undocumented plist keys is opt-in.
- **Languages section** (visible only when enabled):
  - Two language pickers ("Language 1" and "Language 2") populated from `DictationService.enabledLocales()`. Each includes a "None" option. Items render as "🇺🇸 English (US)".
  - "Add more languages in System Settings…" button opens `x-apple.systempreferences:com.apple.preference.keyboard?Dictation` via `NSWorkspace.open`.
  - "Refresh list" button re-reads the enabled locales.
- **Status section** (visible only when enabled):
  - Current dictation language row — shows `DictationService.currentLanguage()` or `—`.
  - Dictation shortcut status — if `DictationService.dictationShortcut()` returns nil (i.e. the user is on "Press Fn twice" or has no shortcut), shows an orange warning label, an explanatory caption, and an "Open System Settings" button. Otherwise shows "Configured ✓".
- Uses `.formStyle(.grouped)`. Enabled locales are loaded via `refreshDictationLocales()` in `onAppear`.

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

| Key                             | Value                                                                                                    |
| ------------------------------- | -------------------------------------------------------------------------------------------------------- |
| LSUIElement                     | true (no Dock icon)                                                                                      |
| NSAccessibilityUsageDescription | "Orbit needs accessibility access to monitor global keyboard shortcuts and switch between applications." |
| NSMainNibFile                   | (empty string)                                                                                           |
| NSPrincipalClass                | NSApplication                                                                                            |

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
