---
title: "feat: Allow both keyboard and mouse button triggers simultaneously"
type: feat
date: 2026-03-13
---

# Allow Both Keyboard and Mouse Button Triggers Simultaneously

## Overview

Currently Orbit supports either a keyboard shortcut OR a mouse button trigger, never both. This change adds a "Both" option so users can have a keyboard shortcut (e.g., Option+Space) and a mouse button (e.g., middle-click) active at the same time. This effectively gives "one trigger per device" without complex device detection.

## Problem Statement

Users with both a mouse and trackpad want different activation methods for each — a keyboard shortcut when using the trackpad and a mouse button when using a mouse. Detecting which physical device generated an event is unreliable on macOS (no public API tags events with source device). The simpler solution is to enable both triggers simultaneously.

## Research Findings

- **IOKit** can detect connected devices (mouse vs trackpad) but cannot identify which device triggered an event
- **CGEventTap** can distinguish scroll source devices (trackpad vs mouse) but not keyboard/click events
- **NSEvent** has no `sourceDevice` property for keyboard or mouse click events
- **Conclusion**: Device-aware activation is unreliable. Dual-trigger ("Both" mode) achieves the same UX goal simply.

## Proposed Solution

Add a third option to `TriggerType`: `.both`. When selected, HotkeyService registers both a keyboard hotkey AND mouse button monitors simultaneously.

### Settings Changes

```swift
enum TriggerType: String, CaseIterable {
    case keyboard
    case mouseButton
    case both        // NEW
}
```

### HotkeyService Changes

The key change: don't call `unregister()` at the start of each registration method. Instead, add targeted cleanup and a new `registerBoth()` method:

```swift
func registerFromSettings(_ settings: SettingsService) {
    unregister() // Clean slate
    switch settings.triggerType {
    case .keyboard:
        registerKeyboard(keyCode: settings.keyCode, modifiers: settings.modifiers)
    case .mouseButton:
        registerMouseButton(settings.mouseButton)
    case .both:
        registerKeyboard(keyCode: settings.keyCode, modifiers: settings.modifiers)
        registerMouseButtonOnly(settings.mouseButton) // Does NOT call unregister()
    }
}
```

Add `registerMouseButtonOnly()` — same as `registerMouseButton()` but without the `unregister()` call at the start.

### Settings UI Changes

Change the segmented picker from 2 to 3 options:

```swift
Picker("Activation Method", selection: $settings.triggerType) {
    Text("Keyboard").tag(SettingsService.TriggerType.keyboard)
    Text("Mouse Button").tag(SettingsService.TriggerType.mouseButton)
    Text("Both").tag(SettingsService.TriggerType.both)
}
```

When "Both" is selected, show BOTH the keyboard shortcut recorder AND the mouse button picker.

### Menu Bar Changes

Update `activationDisplayString()` to show both triggers when in `.both` mode:

```swift
case .both:
    return "\(settings.shortcutDisplayString) + \(settings.mouseButtonDisplayName)"
```

## Technical Approach

### Phase 1: Add `.both` case to TriggerType

**File: `Orbit/Services/SettingsService.swift`**

Add `case both` to the `TriggerType` enum. No other changes needed — existing UserDefaults persistence handles the new raw value automatically.

### Phase 2: Refactor HotkeyService for dual registration

**File: `Orbit/Services/HotkeyService.swift`**

- Extract mouse button registration logic into a helper that doesn't call `unregister()`
- Update `registerFromSettings()` to handle `.both` by registering keyboard first, then mouse button monitors
- `unregister()` already cleans up all four monitors — no changes needed there

### Phase 3: Update Settings UI

**File: `Orbit/Views/SettingsView.swift`**

- Add "Both" option to the segmented picker
- Show both shortcut recorder AND mouse button picker when `.both` is selected

### Phase 4: Update menu bar display

**File: `Orbit/AppDelegate.swift`**

- Update `activationDisplayString()` for the `.both` case
- Observe `keyCode`/`modifiers`/`mouseButton` changes to update display for both triggers

### Phase 5: Update SPEC.md

Document the new `.both` trigger type.

## Acceptance Criteria

- [ ] Settings shows three-option segmented picker: Keyboard / Mouse Button / Both
- [ ] "Both" mode: keyboard shortcut opens Orbit
- [ ] "Both" mode: mouse button also opens Orbit
- [ ] "Both" mode: settings UI shows both shortcut recorder and mouse button picker
- [ ] Changing shortcut while in "Both" mode re-registers both triggers
- [ ] Changing mouse button while in "Both" mode re-registers both triggers
- [ ] Menu bar shows combined display (e.g., "⌥ Space + Middle Button")
- [ ] Setting persists across app restarts
- [ ] Switching from "Both" to "Keyboard" properly cleans up mouse monitors
- [ ] Switching from "Both" to "Mouse Button" properly cleans up keyboard hotkey

## Files to Modify

| File | Changes |
|------|---------|
| `Orbit/Services/SettingsService.swift` | Add `case both` to `TriggerType` |
| `Orbit/Services/HotkeyService.swift` | Add `registerMouseButtonOnly()`, update `registerFromSettings()` |
| `Orbit/Views/SettingsView.swift` | Three-option picker, show both sections when `.both` |
| `Orbit/AppDelegate.swift` | Update `activationDisplayString()` for `.both` |
| `SPEC.md` | Document new trigger type |

## Dependencies & Risks

- **Low risk**: The change is additive — existing keyboard and mouse button code is unchanged
- **Cleanup safety**: `unregister()` already handles all four monitor types, so switching away from "Both" cleans up correctly
- **Carbon + NSEvent coexistence**: These are independent systems (Carbon event handler vs NSEvent monitors), so both running simultaneously is safe
