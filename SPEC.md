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
│   └── RunningApp.swift        # Wraps NSRunningApplication
├── Services/
│   ├── AppService.swift        # Fetches running GUI apps
│   ├── HotkeyService.swift     # Carbon global hotkey + mouse button monitors
│   ├── OverlayPanel.swift      # Floating transparent NSPanel
│   └── SettingsService.swift   # UserDefaults persistence (singleton)
├── ViewModels/
│   └── OrbitViewModel.swift    # Selection logic, angle math, event monitors
├── Views/
│   ├── OrbitView.swift         # SwiftUI radial layout with hover tracking
│   ├── AppIconView.swift       # Single app icon with selection glow
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
3. **Hotkey setup** — create `HotkeyService` with a callback that calls `toggleOrbit()`
4. **Overlay panel** — create a single `OverlayPanel` hosting the `OrbitView`
5. **Settings observation** — use Combine to observe changes to trigger settings (debounced 100ms) and re-register the hotkey
6. **Settings window** — opened as a plain `NSWindow` (420x380) with `NSHostingView<SettingsView>`, not SwiftUI's Settings scene
7. **Toggle logic** — if visible, dismiss; if hidden, get `NSEvent.mouseLocation`, call `viewModel.show()`, then `overlayPanel.showOverlay(at:size:)`

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

## AppService

A stateless enum with one static method:

- `runningApps(excluding: Set<String>) -> [RunningApp]`
- Queries `NSWorkspace.shared.runningApplications`
- Filters to `activationPolicy == .regular` (GUI apps only)
- Excludes apps whose bundle ID is in the exclusion set
- Falls back to a blank 64x64 NSImage if `app.icon` is nil

## HotkeyService

Supports two trigger modes:

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

### registerFromSettings

Reads `SettingsService.triggerType` and calls either `registerKeyboard` or `registerMouseButton`.

### Cleanup

`unregister()` tears down whichever is active (hotkey ref, event handler, mouse monitors). Called from `deinit` and before every new registration.

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

## SettingsService

Singleton (`shared`) `ObservableObject` backed by `UserDefaults`.

### Stored Properties

| Property          | Type                         | Default            | UserDefaults Key    |
| ----------------- | ---------------------------- | ------------------ | ------------------- |
| triggerType       | `.keyboard` / `.mouseButton` | `.keyboard`        | `triggerType`       |
| keyCode           | `UInt32`                     | `kVK_Space` (49)   | `keyCode`           |
| modifiers         | `UInt32`                     | `optionKey` (2048) | `modifiers`         |
| keyDisplayName    | `String`                     | `"Space"`          | `keyDisplayName`    |
| mouseButton       | `Int`                        | `2` (middle)       | `mouseButton`       |
| excludedBundleIds | `Set<String>`                | `[]`               | `excludedBundleIds` |

All properties are `@Published`. The `save()` method writes all properties to UserDefaults.

### Computed Properties

- `shortcutDisplayString` — builds a string like "⌥ Space" from modifier flags and key name, using Unicode symbols (⌃ ⌥ ⇧ ⌘)
- `mouseButtonDisplayName` — human-readable name for the selected mouse button

## OrbitViewModel

`ObservableObject` managing the radial UI state.

### Constants

| Property  | Value |
| --------- | ----- |
| radius    | 140pt |
| iconSize  | 56pt  |
| orbitSize | 400pt |

### Key Properties

- `isVisible: Bool` — controls overlay visibility
- `apps: [RunningApp]` — current running apps
- `selectedIndex: Int?` — which app is highlighted
- `onDismiss: (() -> Void)?` — callback to hide the overlay panel

### Angle & Position Math

- Apps are distributed evenly around a circle: `angle = (2π / count) × index - π/2`
- The `-π/2` offset places the first app at the 12 o'clock position
- `positionForIndex` converts the angle to (x, y) using `center + radius × (cos, -sin)` (Y is inverted for SwiftUI coordinates)

### Selection Logic (updateSelection)

- Ignore if mouse is within 35pt of center (dead zone)
- Calculate mouse angle: `atan2(-dy, dx)`, normalized to [0, 2π)
- Find the app whose angle is closest to the mouse angle (handling the 0/2π wrap)
- Set `selectedIndex` to that app

### Event Monitors

When visible, installs:

- **Local + global keyDown** monitors for ESC (keyCode 53) → dismiss
- **Global leftMouseDown** monitor → dismiss (click outside)

All monitors are removed on dismiss.

### selectAndSwitch

- Dismisses the overlay
- After a 50ms delay, calls `app.app.activate()` on the selected `NSRunningApplication`
- The delay ensures the overlay is fully hidden before activation

## OrbitView (SwiftUI)

Layered inside a `ZStack`, only rendered when `viewModel.isVisible`:

1. **Background** — `Circle` with `.ultraThinMaterial` fill, size = `orbitSize - 40`, opacity 0.9, tap to dismiss
2. **Ring guide** — `Circle` stroke, white at 10% opacity, 1pt line, diameter = `radius × 2`
3. **Center dot** — 6pt white circle at 40% opacity
4. **Selection line** — dashed `Path` from center to selected app's position, accent color at 40% opacity, dash pattern `[4, 4]`
5. **App icons** — `ForEach` over enumerated apps, each `AppIconView` positioned via `.position()`; tap triggers `selectAndSwitch()`
6. **App name label** — shown when an app is selected, centered below the middle in a capsule with `.ultraThinMaterial`

### Interactions

- `onContinuousHover` tracks mouse position and calls `viewModel.updateSelection(mouseInView:)`
- Animations: `.easeOut(0.2)` on visibility, `.easeInOut(0.1)` on selection changes

## AppIconView

Displays a single app icon:

- `Image(nsImage:)` resized to `size × size` with `.aspectRatio(.fit)`
- Clipped to `RoundedRectangle(cornerRadius: 12)`
- When selected:
  - Blue glow shadow (accent color, 80% opacity, radius 12)
  - Accent color border stroke (2.5pt)
  - Scale up to 1.25×
- Animation: `.easeInOut(0.12)` on `isSelected`

## SettingsView

A `TabView` with two tabs:

### Shortcut Tab

- Segmented picker: Keyboard Shortcut vs Mouse Button
- If keyboard: shows `ShortcutRecorderView`
- If mouse: shows a picker with Middle Button, Button 4 (Back), Button 5 (Forward)
- Uses `.formStyle(.grouped)`

### Apps Tab

- Header text explaining the purpose
- `List` of all running GUI apps (`activationPolicy == .regular`), sorted alphabetically
- Each row: 28×28 icon, app name, toggle switch
- Toggle controls whether the app's bundle ID is in `excludedBundleIds`
- Footer: Refresh button + count of hidden apps
- Apps list is refreshed on appear and via the Refresh button

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
5. Clicking the highlighted app: overlay dismisses, then the app activates after 50ms
6. Pressing ESC, clicking outside, or pressing the shortcut again dismisses without switching
7. User can change the trigger (keyboard shortcut or mouse button) and filter apps via Settings
