---
title: "feat: Add Mouse/Trackpad input mode setting"
type: feat
date: 2026-03-13
---

# Add Mouse/Trackpad Input Mode Setting

## Enhancement Summary

**Deepened on:** 2026-03-13
**Research agents used:** 6 (scroll wheel, onContinuousHover, keyboard nav, architecture, simplicity, performance)

### Key Improvements from Research

1. **Scroll + arrow keys enabled in BOTH modes** — universally useful, not trackpad-specific
2. **Snapshot geometry in `show()`** — not computed properties reading singleton every frame
3. **Filter momentum scroll events** — prevents 1-2s of unintended coasting after swipe
4. **Reset scroll accumulator on gesture boundaries** — prevents ghost inputs
5. **Use interruptible spring animation** — handles rapid selection changes without pile-up
6. **View model mediates all settings** — OrbitView never reads SettingsService directly

## Overview

Add an input mode setting that lets users choose between **Mouse** and **Trackpad** interaction styles. The key differences are geometry (larger targets in Trackpad mode) and sticky selection (selection persists when cursor leaves panel in Trackpad mode). Scroll-to-rotate and arrow key navigation are enabled in **both** modes since they benefit all users.

## Problem Statement

Orbit's current hover-and-click interaction works well with a mouse but is awkward on a trackpad. Precision hover over small 56pt icons in a ring is harder without a mouse's direct cursor control. Trackpad users need larger hit targets and an alternative selection mechanism.

## Proposed Solution

### Two Modes

**Mouse mode** (default) — current behavior plus new universal inputs:

- Hover to highlight, click to switch
- 140pt radius, 56pt icons, 400pt panel, 35pt dead zone
- Selection clears when cursor leaves panel
- Scroll-to-rotate and arrow key navigation available

**Trackpad mode** — optimized for trackpad:

- Larger geometry: 180pt radius, 68pt icons, 500pt panel, 45pt dead zone
- **Sticky selection**: selection does NOT clear when cursor exits the panel
- Scroll-to-rotate and arrow key navigation available (same as Mouse mode)
- Hover still works, but larger targets make it easier

### Universal Inputs (Both Modes)

- **Scroll-to-rotate**: two-finger swipe (or scroll wheel) rotates the highlight around the ring
- **Arrow key navigation**: Left/Right arrows cycle through apps
- **Enter to confirm**: Return key triggers `selectAndSwitch()`

### Settings

- Named **"Mouse"** / **"Trackpad"** (not Desktop/Laptop — accurate for Magic Trackpad on desktop users)
- Placed as a new section at the top of the existing **Shortcut** tab (segmented picker)
- Independent of trigger type — all four combinations are valid
- Defaults to **Mouse** (preserves current behavior)
- Changes take effect on next overlay open

## Technical Approach

### Phase 1: Add Setting to SettingsService

**File: `Orbit/Services/SettingsService.swift`**

```swift
enum InputMode: String, CaseIterable {
    case mouse
    case trackpad
}

@Published var inputMode: InputMode  // default: .mouse, key: "inputMode"
```

Touch points: add property, read in `init()`, write in `save()`.

### Phase 2: Snapshot Geometry in OrbitViewModel

**File: `Orbit/ViewModels/OrbitViewModel.swift`**

**Do NOT use computed properties.** Snapshot geometry once in `show()` to avoid hitting SettingsService singleton 35+ times per render frame:

```swift
private(set) var radius: CGFloat = 140
private(set) var iconSize: CGFloat = 56
private(set) var orbitSize: CGFloat = 400
private(set) var deadZone: CGFloat = 35
private(set) var stickySelection: Bool = false

func show() {
    let isTrackpad = SettingsService.shared.inputMode == .trackpad
    radius = isTrackpad ? 180 : 140
    iconSize = isTrackpad ? 68 : 56
    orbitSize = isTrackpad ? 500 : 400
    deadZone = isTrackpad ? 45 : 35
    stickySelection = isTrackpad

    scrollAccumulator = 0  // Reset to prevent ghost inputs

    let excluded = SettingsService.shared.excludedBundleIds
    apps = AppService.runningApps(excluding: excluded)
    selectedIndex = nil
    isVisible = true
    startMonitors()
}
```

Update `updateSelection` to use `deadZone` instead of hardcoded `35`.

### Research Insights (Architecture)

- **Consistency**: computed properties would be evaluated dozens of times per render with potentially inconsistent results if settings changed mid-display
- **Pattern**: matches existing `excludedBundleIds` pattern — settings read at show-time
- **MVVM boundary**: the view model mediates all settings; OrbitView never imports SettingsService

### Phase 3: Scroll-to-Rotate Selection (Both Modes)

**File: `Orbit/ViewModels/OrbitViewModel.swift`**

Add scroll handling with momentum filtering, gesture boundary reset, and time-gated debounce:

```swift
private var scrollAccumulator: CGFloat = 0
private var scrollMonitor: Any?
private var lastScrollSelectionTime: CFTimeInterval = 0
private let scrollSelectionMinInterval: CFTimeInterval = 0.06  // ~16/sec max

func handleScroll(deltaY: CGFloat) {
    guard !apps.isEmpty else { return }
    scrollAccumulator += deltaY
    let threshold: CGFloat = 3.0
    guard abs(scrollAccumulator) > threshold else { return }

    let now = CACurrentMediaTime()
    guard now - lastScrollSelectionTime >= scrollSelectionMinInterval else { return }

    let direction = scrollAccumulator > 0 ? -1 : 1
    let current = selectedIndex ?? 0
    selectedIndex = (current + direction + apps.count) % apps.count
    scrollAccumulator -= CGFloat(scrollAccumulator > 0 ? 1 : -1) * threshold  // carry remainder
    lastScrollSelectionTime = now
}
```

Add scroll monitor in `startMonitors()` (local only — no global scroll monitor needed):

```swift
scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
    guard let self else { return event }

    // Reset accumulator on new gesture
    if event.phase == .began {
        self.scrollAccumulator = 0
    }

    // Ignore momentum (inertial) events — only respond to direct contact
    guard event.momentumPhase == NSEvent.Phase(rawValue: 0) else {
        return event
    }

    self.handleScroll(deltaY: event.scrollingDeltaY)

    // Reset on gesture end
    if event.phase == .ended || event.phase == .cancelled {
        self.scrollAccumulator = 0
    }

    return event
}
```

### Research Insights (Scroll Performance)

- **Momentum filtering is critical**: without it, every swipe coasts through multiple selections for 1-2 seconds
- **Use `scrollingDeltaY`** not `deltaY` (deprecated for scroll events)
- **Carry remainder** instead of zeroing accumulator for responsive feel
- **60ms debounce** caps at ~16 changes/sec, preventing animation pile-up
- **Local monitor only**: global scroll monitor would intercept Safari/Chrome scrolling

### Phase 4: Arrow Key + Enter Navigation (Both Modes)

**File: `Orbit/ViewModels/OrbitViewModel.swift`**

Extend the **existing** local keyDown monitor (do not add a separate one):

```swift
escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
    guard let self else { return event }
    switch event.keyCode {
    case 53:  // ESC
        self.dismiss()
        return nil
    case 123:  // Left arrow — counterclockwise
        if !self.apps.isEmpty {
            let current = self.selectedIndex ?? 0
            self.selectedIndex = (current - 1 + self.apps.count) % self.apps.count
        }
        return nil
    case 124:  // Right arrow — clockwise
        if !self.apps.isEmpty {
            let current = self.selectedIndex ?? 0
            self.selectedIndex = (current + 1) % self.apps.count
        }
        return nil
    case 36:  // Return/Enter — confirm
        self.selectAndSwitch()
        return nil
    default:
        return event
    }
}
```

### Phase 5: Sticky Selection + View Model Mediation

**File: `Orbit/Views/OrbitView.swift`**

The view delegates the hover-ended decision to the view model (never reads SettingsService directly):

```swift
case .ended:
    viewModel.handleHoverEnded()
```

**File: `Orbit/ViewModels/OrbitViewModel.swift`**

```swift
func handleHoverEnded() {
    if !stickySelection {
        selectedIndex = nil
    }
}
```

### Phase 6: Animation Update

**File: `Orbit/Views/OrbitView.swift`**

Replace the easeInOut animation with an interruptible spring that handles rapid selection changes:

```swift
// Replace:
.animation(.easeInOut(duration: 0.1), value: viewModel.selectedIndex)

// With:
.animation(.interpolatingSpring(stiffness: 300, damping: 25), value: viewModel.selectedIndex)
```

### Phase 7: Settings UI

**File: `Orbit/Views/SettingsView.swift`**

Add a new `Section` at the top of `shortcutTab`:

```swift
Section {
    Picker("Input Mode", selection: $settings.inputMode) {
        Text("Mouse").tag(SettingsService.InputMode.mouse)
        Text("Trackpad").tag(SettingsService.InputMode.trackpad)
    }
    .pickerStyle(.segmented)
    .onChange(of: settings.inputMode) { settings.save() }

    Text(settings.inputMode == .mouse
        ? "Optimized for mouse. Hover to select, click to switch."
        : "Larger targets and sticky selection for trackpad use.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

### Phase 8: Update SPEC.md

Per CLAUDE.md convention, update SPEC.md to document all changes.

## Acceptance Criteria

- [ ] Settings shows Mouse/Trackpad segmented picker at top of Shortcut tab
- [ ] Setting persists across app restarts via UserDefaults
- [ ] Mouse mode: identical hover/click behavior to current app (no regressions)
- [ ] Trackpad mode: ring is visibly larger (180pt radius, 68pt icons, 500pt panel)
- [ ] Trackpad mode: selection does NOT clear when cursor leaves the panel
- [ ] **Both modes**: two-finger scroll / scroll wheel rotates selection around the ring
- [ ] **Both modes**: scroll momentum events are filtered (no coasting after lift-off)
- [ ] **Both modes**: Left/Right arrow keys cycle selection
- [ ] **Both modes**: Enter/Return confirms selection
- [ ] Clicking an app icon works in both modes
- [ ] ESC dismisses in both modes
- [ ] Panel stays within screen bounds in both modes (test near screen edge)
- [ ] 500pt panel fits on a 13" MacBook Air (1470x956 effective resolution)
- [ ] SPEC.md is updated to reflect all changes

## Files to Modify

| File | Changes |
|------|---------|
| `Orbit/Services/SettingsService.swift` | Add `InputMode` enum, `@Published var inputMode`, init/save |
| `Orbit/ViewModels/OrbitViewModel.swift` | Snapshot geometry in show(), scroll handler with momentum filtering, arrow keys in existing keyDown monitor, handleHoverEnded(), scrollAccumulator reset |
| `Orbit/Views/OrbitView.swift` | Delegate hover-ended to viewModel, interruptible spring animation |
| `Orbit/Views/SettingsView.swift` | Input Mode segmented picker section with description |
| `SPEC.md` | Document new setting, universal scroll/arrow navigation, geometry modes |

## Dependencies & Risks

- **Scroll momentum coasting**: Mitigated by filtering `event.momentumPhase` and resetting accumulator on gesture boundaries
- **Animation pile-up**: Mitigated by 60ms debounce + interruptible spring animation
- **Panel size on small screens**: 500pt panel leaves ~456pt margin on 13" screen. Existing clamping logic handles this.
- **Ghost scroll inputs**: Mitigated by resetting `scrollAccumulator` in `show()` and on `event.phase == .began`

## Future Considerations

- **Auto-detect input device**: Use IOKit to detect connected mice/trackpads and auto-select mode
- **Momentum scrolling**: Optionally allow controlled momentum with custom deceleration
- **Force Touch**: Use pressure-sensitive click on supported trackpads for confirmation
