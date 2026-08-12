# Menu bar dictation feedback + soft ring anchors

Date: 2026-08-12
Status: approved, ready for implementation planning

## Problem

Two independent complaints about Orbit's current behavior:

1. **The dictation hover panel is in the way.** `RecordingIndicatorPanel` shows a
   220x64 floating panel near the cursor for the whole dictation session. It sits
   exactly where the user is looking and working. The feedback belongs somewhere
   ambient. Escape must keep cancelling a session.

2. **Ring positions are too static.** Pinned apps are stored at exact angles
   (snapped to 15 degrees) and non-pinned running apps are distributed
   proportionally into whatever gaps remain. Pin three apps near each other and
   they end up cramped while every auto-added app is smeared thinly across the
   remaining arc. The user wants to place pinned apps _approximately_ and have
   Orbit handle the exact placement.

Part 1 touches only `SpeechRecognitionService`, `AppDelegate` and the deleted
panel. Parts 2 and 3 touch only `RingLayout`, `SettingsService`,
`OrbitViewModel` and `LayoutPreviewView`. They share no code and can be built,
verified and shipped in either order. Parts 2 and 3 are coupled to each other and
must land together, since the preview depends on the new `compute` signature.

## Part 1 - Dictation feedback moves to the menu bar

### Removed

- `Orbit/Views/RecordingIndicatorPanel.swift` is deleted in full (166 lines:
  the `NSPanel` subclass, `RecordingIndicatorModel`, and `RecordingIndicatorView`).
- `indicatorPanel`, `showIndicator(state:)` and every `hideIndicator()` /
  `updateState(_:)` call site in `SpeechRecognitionService`.

### State publication

`SpeechRecognitionService` must not know the menu bar exists. It publishes state
and nothing more. It is already an `ObservableObject` with a `@Published
modelStatus`, so this follows the existing pattern:

```swift
enum DictationState: Equatable {
    case idle
    case loading(message: String)
    case starting
    case listening
    case transcribing
}

@Published private(set) var dictationState: DictationState = .idle
```

Every existing `showIndicator` / `updateState` / `hideIndicator` call is replaced
one-for-one with an assignment to `dictationState` at the same point in the
lifecycle. No new transitions are invented, with one exception: `.transcribing`
is set and cleared where the existing private `transcribing` flag is already set
and cleared, so the ~600 ms gap between stopping and the text landing is no
longer silent.

`.loading` carries the same message string the panel used to display. The icon
cannot express it, so it surfaces in the status item menu instead (see
"Stopping a session" below).

### Status item controller

A new `Orbit/Services/StatusItemController.swift` owns the `NSStatusItem`
button's appearance and subscribes to `dictationState` over Combine, mirroring
`AppDelegate.observeSettingsChanges`. Status item construction and the menu move
out of `AppDelegate.setupStatusItem` into this type; `AppDelegate` keeps only the
menu _actions_ it already implements (`openSettings`, `checkForUpdateManual`,
`showAbout`, `openUpdate`) and wires them as targets. This makes `AppDelegate`
smaller, not larger.

### Icon vocabulary

| state        | SF Symbol       | treatment                                                        |
| ------------ | --------------- | ---------------------------------------------------------------- |
| idle         | `circle.dotted` | template, full opacity, static                                   |
| loading      | `circle.dotted` | template, 45% alpha, 1.6 s breathe                               |
| starting     | `waveform`      | template, 45% alpha, static                                      |
| listening    | `waveform`      | `NSColor.controlAccentColor`, 1.2 s breathe between 100% and 55% |
| transcribing | `ellipsis`      | template, full opacity, static                                   |

Color is `NSColor.controlAccentColor` applied via the button's
`contentTintColor`. One accent, no new palette, inherits the user's macOS accent
setting, and stays visually distinct from the orange microphone dot macOS itself
places in the menu bar during capture.

The breathe is a `Timer` writing `button.alphaValue` along a sine curve. It is
created when entering an animated state and invalidated on every other
transition, so the icon is static except while loading or listening.

### Stopping a session

The panel's click-to-stop affordance is replaced by:

- **Escape** - already an unconditional global `NSEvent` monitor in
  `SpeechRecognitionService.installEscMonitor()` (line 899), independent of the
  panel. Unchanged.
- **Re-triggering Orbit** - already handled in `AppDelegate.toggleOrbit`.
  Unchanged.
- **A "Stop Dictation" menu item**, inserted at the top of the status item menu
  whenever `dictationState != .idle` and removed when it returns to `.idle`.
  This follows the same insert/remove pattern already used for the
  "Update Available" item.

Directly above it, and inserted and removed together with it, sits a disabled
status line carrying the state text: the `.loading` message verbatim, or
"Starting…", "Listening…", "Transcribing…". This is the only place the loading
message is still shown, and it matches how the existing disabled activation and
input-mode items already read.

### Accepted trade-off

In full screen the menu bar is hidden, so Escape and the hotkey are the only
feedback and control. This follows directly from removing all cursor-adjacent
feedback and is accepted.

## Part 2 - Soft anchors in `RingLayout`

### Model

A pinned app (and the dictation tile) stores a **preferred direction**, not a
position. The ring is always evenly divided: with `n` total items there are
exactly `n` slots, slot `i` at angle `i * 360/n` degrees clockwise from twelve
o'clock. Slot 0 is always at twelve, so a preference of 0 always resolves to the
top regardless of how many apps are running.

```swift
static func compute(
    preferred: [(item: OrbitItem, preferredAngle: Double)],
    others: [OrbitItem]
) -> [Positioned]
```

### Assignment

1. Return `[]` when there are no items at all.
2. Compute `step = 360 / n`. For each preferred item, its **ideal slot** is
   `Int((normalize(preferredAngle) / step).rounded()) % n` and its **residual**
   is the circular distance from the preference to that slot's angle.
3. Sort preferred items by ascending residual, breaking ties by ascending
   normalized preferred angle. The item closest to its ideal slot claims first.
4. Each item in that order takes its ideal slot if free. Otherwise it searches
   outward alternating clockwise and counter-clockwise (`+1, -1, +2, -2, ...`,
   modulo `n`) for the first free slot. This always succeeds because preferred
   items are themselves counted in `n`.
5. Remaining free slots, walked in ascending index order, receive `others` in the
   order `AppService.runningApps` returned them.
6. Results carry `isAnchored: true` for preferred items and `false` for others,
   preserving what `AppIconView` and `DictationTileView` already use to render
   anchors 1.2x larger.
7. The returned array is sorted by ascending slot index, which is clockwise from
   twelve o'clock - the same contract the current implementation guarantees, so
   scroll-to-rotate, arrow-key navigation and selection math are unaffected.

Sorting by residual is what makes the result explainable and independent of the
order of `pinnedBundleIds`. The app that genuinely wanted a slot gets it; there
is no last-writer-wins.

### Consequences

- **No preferred items:** the algorithm degenerates to plain even distribution,
  identical to today's behavior for users who have pinned nothing. The separate
  `evenDistribution` helper is no longer needed.
- **No other items:** anchors spread evenly rather than sitting at their exact
  stored angles. This is a behavior change, and it is the intended one - even
  spacing is guaranteed unconditionally.
- The entire proportional gap-filling block (roughly 80 lines: the `Gap` struct,
  floor-and-distribute-remainders logic, and the arithmetic-surprise fallback
  loop) is deleted.
- A pinned app's resolved angle shifts slightly as the number of running apps
  changes. This is inherent to the model and is the accepted cost of guaranteed
  even spacing.

### `SettingsService` naming

The stored value's meaning changes from "angle" to "preferred direction", so the
names follow:

- `pinnedAngles` becomes `pinnedPreferredAngles`
- `dictationAngle` becomes `dictationPreferredAngle`
- `allAnchorAngles` becomes `allPreferredAngles`
- `ensureAnchorAngles()` becomes `ensurePreferredAngles()`
- `resetLayoutAngles()` keeps its name

The UserDefaults keys (`pinnedAngles`, `dictationAngle`) are deliberately left
unchanged. Existing stored values are already valid preferences, so no migration
is needed and current user settings survive the upgrade.

`RingLayout.nextAnchorAngle(existingAngles:)` is kept unchanged. Placing a newly
pinned app at the midpoint of the largest empty arc is still the right way to
seed a starting preference.

## Part 3 - Live layout preview in Settings

`LayoutPreviewView` is rewritten to render the resolved ring rather than an
abstract set of anchors.

- It calls the same `RingLayout.compute` with the apps that are actually running,
  obtained through the same `AppService.runningApps(excluding:pinnedFirst:)` call
  and the same exclusion set the real ring uses. The preview is not a
  reimplementation of the layout - it is the layout.
- Hierarchy comes from scale and contrast, not borders or shadows, reusing the
  1.2x anchor convention already in `AppIconView`: anchors render at 44 pt at
  full opacity and are draggable; non-pinned apps render at 26 pt at 35% opacity
  and are not draggable or hit-testable.
- While dragging, the icon follows the cursor freely, a hairline from the center
  shows the direction being pointed at, and the rest of the ring re-solves live
  so the user sees auto-added apps move out of the way.
- On release the icon animates to its resolved slot.
- The guide circle, the 12/3/6/9 tick marks and the center dot are unchanged.
- `snap(_:avoiding:)`, `collisionThreshold`, `snapIncrement` and
  `smallestDifference` are deleted. There is no snapping and no collision
  avoidance; the solver quantizes regardless.
- The `.position()` (not `.offset()`) rule and the `"layoutRing"` named
  coordinate space on the ring `ZStack` must be preserved - both are load-bearing
  for drag hit-testing and are documented as such in the current file.

The help text is rewritten, since the current copy describes the old
gap-filling model, and the dimmed icons need a one-line legend explaining that
they are auto-added apps shown for context.

The preview snapshots the running-app set when the view appears and on the
existing `pinnedBundleIds` / `dictationEnabled` change handlers. It does not
observe app launches continuously; an app started while Settings is open will not
appear until the view is revisited. This is an accepted simplification.

## Verification

The project has no test target and this design does not add one. `RingLayout` is
pure data and is the only logic-dense part of the change, so it is verified by
building with `./build.sh` and exercising the ring directly: pinning apps at
clustered preferences, confirming even spacing, confirming a preference of 0
lands at twelve o'clock, and confirming the no-anchors case matches today's
layout. Dictation states are verified by running a session and watching the menu
bar through loading, listening and transcribing, and by cancelling with Escape.

## Out of scope

- Ordering of non-pinned apps around the ring. They keep the order
  `AppService.runningApps` returns (roughly launch order). Making that
  deterministic is a separate change.
- Adding an XCTest target to the xcodegen project.
- Any change to dictation capture, transcription or paste behavior.

## Documentation

`SPEC.md` must be updated per the project's `CLAUDE.md`: the recording indicator
section, the ring layout section, the settings layout preview section, and the
menu bar description all change.
