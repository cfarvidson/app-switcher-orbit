# Ring Positioning — Brainstorm

**Date:** 2026-04-08
**Status:** Approved, implementing directly

## Problem

With 2 languages + N pinned apps + M running apps in the ring, icons get cramped. User wants pinned apps and dictation languages to occupy fixed positions around the circle so non-pinned running apps can't push them around. Also wants pinned/language tiles to render larger (20%) so they're glanceable at a distance.

## Chosen Approach

**Fixed angles for pinned+languages; non-pinned running apps fill gaps proportionally and shrink if many.** All running apps remain accessible (nothing is hidden). Pinned/language items stay at user-assigned angles regardless of what else is running.

Rejected alternatives:

- Fixed 12-slot cap → non-pinned apps get hidden when ring is full; user wants everything accessible.
- Concentric outer ring for non-pinned → too much visual complexity for this project.

## Key Decisions

- **Storage:** `pinnedAngles: [String: Double]` (bundleId → degrees) and `languageAngles: [String: Double]` (localeId → degrees) in `SettingsService`. 0° = 12 o'clock, clockwise. Persisted via UserDefaults.
- **Default angles:** First-time users (or newly pinned items) get the center of the largest currently-free gap — same placement rule Hitman's weapon wheel uses when adding slots.
- **Reset:** A "Reset to default layout" button in the new Layout tab clears stored angles, causing fallback to even distribution among anchored items.
- **Non-pinned distribution:** For each gap between consecutive anchored items, allocate non-pinned items proportional to gap size (`round(N × gapSize / totalGapSize)` with remainders adjusted). Distribute evenly within each gap.
- **Visual differentiation:** Pinned apps and language tiles render at `iconSize × 1.2`. No extra chrome. `AppIconView` and `LanguageTileView` gain an `isAnchored: Bool` parameter.
- **UX for assignment:** New "Layout" tab (fifth tab) with a scaled-down circular preview (~280pt). User drags individual icons around the preview; on drag-end, angle snaps to 15° increments. The Pinned and Dictation tabs keep their existing pin/unpin + language-selection responsibilities — Layout only handles positioning.
- **Collision handling:** If a drag would land an item within ~5° of another anchored item, nudge to the nearest free 15° slot.

## Architecture Sketch

### New types

```swift
// Orbit/Models/RingLayout.swift (pure data)
enum RingLayout {
    struct Positioned {
        let item: OrbitItem
        let angleDegrees: Double
        let isAnchored: Bool
    }

    static func compute(
        anchoredItems: [(OrbitItem, Double)],
        nonPinned: [OrbitItem]
    ) -> [Positioned]
}
```

### Modified types

```swift
// Orbit/Services/SettingsService.swift
@Published var pinnedAngles: [String: Double]
@Published var languageAngles: [String: Double]

func ensureAngle(forBundleId: String)   // assigns default if missing
func ensureAngle(forLocaleId: String)   // assigns default if missing
func resetLayoutAngles()                // clears both dicts
```

```swift
// Orbit/ViewModels/OrbitViewModel.swift
// items: [OrbitItem] → positionedItems: [RingLayout.Positioned]
// angleForIndex(_:) reads positionedItems[i].angleDegrees instead of deriving
// selectAndSwitch etc. still work on indices unchanged
```

### New view

```swift
// Orbit/Views/LayoutPreviewView.swift
struct LayoutPreviewView: View {
    @ObservedObject var settings = SettingsService.shared
    let previewDiameter: CGFloat = 280
    // DragGesture on each anchored item; snap-to-15° on end; writes to settings
}
```

### Settings tab integration

```swift
// Orbit/Views/SettingsView.swift
// Add fifth tab:
layoutTab
    .tabItem { Label("Layout", systemImage: "circle.grid.cross") }
```

## Scope

In-scope for this feature:

- `RingLayout` pure algorithm
- `SettingsService` angle storage + default assignment + reset
- `OrbitViewModel` plumbing through `positionedItems`
- `OrbitView` rendering from positioned items
- Icon size differentiation (1.2× for anchored)
- New Layout settings tab with drag-and-drop preview
- Algorithm for filling non-pinned in gaps proportionally

Out of scope:

- Free-form angle input (only visual drag)
- Keyboard shortcuts for positioning
- Per-item rotation animation when angles change live (will animate via existing `.interpolatingSpring` on selection)
- Multiple layout presets / profiles
- Concentric rings / nested ring levels

## Open Questions

None blocking. The snap-to-15° and nudge-if-within-5° values are best-effort; we can tune them during manual testing.
