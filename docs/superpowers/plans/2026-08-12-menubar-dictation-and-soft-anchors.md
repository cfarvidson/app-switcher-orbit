# Menu Bar Dictation Feedback + Soft Ring Anchors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move all dictation feedback from a floating panel near the cursor into the menu bar icon, and replace exact pinned ring angles with preferred directions resolved onto an always-evenly-spaced ring.

**Architecture:** `SpeechRecognitionService` publishes a `DictationState` and knows nothing about presentation; a new `StatusItemController` owns the `NSStatusItem` and maps that state to an icon treatment. `RingLayout.compute` is rewritten from proportional gap-filling to slot assignment: `n` items means `n` evenly spaced slots, and each pinned app claims the free slot nearest its stored preferred direction. `LayoutPreviewView` calls the same `compute` so the Settings preview is the real layout rather than a lookalike.

**Tech Stack:** Swift 5.9, SwiftUI + AppKit, Combine, macOS 14 deployment target, xcodegen (`project.yml`), FluidAudio 0.15.5.

## Global Constraints

- Deployment target is macOS 14.0. Do not use API newer than that.
- The project has **no test target** and this plan does not add one. Every task is verified by `./build.sh` plus the specific manual checks written into that task.
- Build with `./build.sh` from the repo root. It builds Release and copies `Orbit.app` to the repo root.
- Run `npx prettier --write .` before every commit (project `CLAUDE.md`).
- `SPEC.md` must reflect the final state of the app before the last commit (project `CLAUDE.md`). Task 8 does this.
- UserDefaults keys `pinnedAngles` and `dictationAngle` must NOT be renamed. Only the Swift property names change, so existing user settings survive the upgrade with no migration.
- Angles are degrees, 0 at twelve o'clock, increasing clockwise. This convention is load-bearing across `RingLayout`, `OrbitViewModel` and `LayoutPreviewView`.
- Never use em dashes in code comments or user-facing copy; use a plain hyphen.
- Orbit is a menu bar app (`LSUIElement`). It has no dock icon and no main window.

## Task Order and Independence

Tasks 1-4 (dictation) and tasks 5-7 (ring) touch disjoint files and can be done in either order. Within each group the order is required. Task 8 documents both and must run last.

---

### Task 1: Publish `DictationState` from `SpeechRecognitionService`

The panel keeps working exactly as it does today. This task only adds a published state alongside it, so the next task has something to subscribe to. Nothing user-visible changes.

**Files:**

- Modify: `Orbit/Services/SpeechRecognitionService.swift`

**Interfaces:**

- Consumes: nothing from earlier tasks.
- Produces: `SpeechRecognitionService.DictationState` (enum, `Equatable`, cases `idle`, `loading(message: String)`, `starting`, `listening`, `transcribing`) and `@Published private(set) var dictationState: DictationState` on the shared singleton. Task 2 subscribes to it.

- [ ] **Step 1: Add the state enum and published property**

In `Orbit/Services/SpeechRecognitionService.swift`, directly below the existing `@Published var modelStatus: ModelStatus = .notDownloaded` (line 46):

```swift
/// Presentation-facing dictation lifecycle state. The service publishes it
/// and does not care who renders it; `StatusItemController` maps it to a
/// menu bar icon treatment.
///
/// `.transcribing` covers only the post-stop final flush. Mid-session VAD
/// flushes deliberately stay `.listening`: the session is still capturing,
/// and flipping the icon on every natural pause would strobe it.
enum DictationState: Equatable {
    case idle
    case loading(message: String)
    case starting
    case listening
    case transcribing
}

@Published private(set) var dictationState: DictationState = .idle
```

- [ ] **Step 2: Set the state at every existing indicator call site**

Add one assignment next to each existing panel call. Do not remove any panel call in this task.

`startInternal`, at line 291-293, alongside the existing `showIndicator(state:)`:

```swift
let initialState: RecordingIndicatorPanel.State =
    (asrManager == nil) ? .loading(message: "Loading model\u{2026}") : .listening
dictationState = (asrManager == nil) ? .loading(message: "Loading model\u{2026}") : .listening
showIndicator(state: initialState)
```

`startInternal`, permission-denied branch at line 301-302:

```swift
self.indicatorPanel?.hideIndicator()
self.indicatorPanel = nil
self.dictationState = .idle
```

`startInternal`, pre-capture branch at line 314:

```swift
self.indicatorPanel?.updateState(.starting)
self.dictationState = .starting
self.beginCapture(onError: onError)
```

`ensureModelsLoaded`, load-failure branch at line 509-510:

```swift
indicatorPanel?.hideIndicator()
indicatorPanel = nil
dictationState = .idle
```

`promoteWarmupToSession`, line 554:

```swift
indicatorPanel?.updateState(.listening)
dictationState = .listening
```

`beginCapture`, engine-start-failure branch at line 621-622:

```swift
indicatorPanel?.hideIndicator()
indicatorPanel = nil
dictationState = .idle
```

`processAudioBuffer`, first-buffer hook at line 717-721:

```swift
if shouldFlipToListening {
    DispatchQueue.main.async { [weak self] in
        self?.indicatorPanel?.updateState(.listening)
        self?.dictationState = .listening
    }
}
```

- [ ] **Step 3: Wire `.transcribing` into `stop(reason:flushBuffer:)`**

In `stop`, the panel is hidden at line 400-401. Replace the state there with `.transcribing` only when a final flush will actually be dispatched, otherwise `.idle`. The flush condition is already computed at line 427, so move the state assignment below it.

At line 400-401, leave the panel calls and set nothing yet:

```swift
indicatorPanel?.hideIndicator()
indicatorPanel = nil
```

Then at line 427, in the `if`/`else`:

```swift
if flushBuffer, hadSpeech, finalSnapshot.count > minSamples, let manager = asrManager, !transcribing {
    NSLog("[Orbit.speech] stop: final flush \(String(format: "%.2f", Double(finalSnapshot.count) / targetSampleRate))s audio")
    transcribing = true
    dictationState = .transcribing
    Task { [weak self] in
        guard let self else { return }
        do {
            let decoderLayers = await manager.decoderLayerCount
            var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
            let result = try await manager.transcribe(finalSnapshot, decoderState: &decoderState)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                self.handleFlushedTranscript(text)
                self.injectedSoFar = ""
                self.transcribing = false
                self.dictationState = .idle
            }
        } catch {
            NSLog("[Orbit.speech] final flush transcribe error: \(error.localizedDescription)")
            await MainActor.run {
                self.injectedSoFar = ""
                self.transcribing = false
                self.dictationState = .idle
            }
        }
    }
} else {
    injectedSoFar = ""
    dictationState = .idle
}
```

Leave `flushAndTranscribe` (line 737) completely untouched. Its `transcribing` flag is mid-session and must not change `dictationState`.

- [ ] **Step 4: Log every state transition**

The state needs to be observable from outside for the verification step below. Add a self-subscription in the initializer. Replace `private init() {}` (line 136) with:

```swift
private var stateLogCancellable: AnyCancellable?

private init() {
    stateLogCancellable = $dictationState
        .removeDuplicates()
        .sink { state in
            NSLog("[Orbit.dictation] state=\(state)")
        }
}
```

`Combine` is already imported in this file's dependency graph via `SettingsService`; verify `import Combine` is present at the top of `SpeechRecognitionService.swift` and add it if not.

- [ ] **Step 5: Build**

Run: `./build.sh`
Expected: `Copied to ./Orbit.app`, no errors.

- [ ] **Step 6: Verify the state stream by hand**

Quit any running Orbit, launch the freshly built one, and stream its logs:

Run: `log stream --predicate 'process == "Orbit"' --style compact | grep Orbit.dictation`

Open the ring, click the dictation tile, say one sentence, then press Escape.
Expected sequence: `state=listening` (or `state=loading(...)` then `state=starting` then `state=listening` on a cold model), then `state=idle` on Escape.

Repeat, but stop with the hotkey instead of Escape after speaking.
Expected: `state=transcribing` then `state=idle` once the text lands.

Speak two sentences with a clear pause between them without stopping.
Expected: no `state=transcribing` in the middle. The pause must not change state.

- [ ] **Step 7: Commit**

```bash
npx prettier --write .
git add Orbit/Services/SpeechRecognitionService.swift
git commit -m "feat: publish DictationState from SpeechRecognitionService"
```

---

### Task 2: Add `StatusItemController` and render the icon states

The panel still exists and still works after this task. Both the panel and the menu bar icon show the state, which makes the icon easy to verify against known-good behavior.

**Files:**

- Create: `Orbit/Services/StatusItemController.swift`
- Modify: `Orbit/AppDelegate.swift`

**Interfaces:**

- Consumes: `SpeechRecognitionService.shared.$dictationState` from Task 1.
- Produces: `StatusItemController`, an `NSObject` subclass with `init(activationTitle: String, inputModeTitle: String)` and the methods `setActivationTitle(_ title: String)`, `setInputModeTitle(_ title: String)` and `showUpdateItem(title: String, url: URL, target: AnyObject, action: Selector)`. Task 3 adds the `Stop Dictation` menu items to this same type.

- [ ] **Step 1: Create the controller**

Create `Orbit/Services/StatusItemController.swift`:

```swift
import AppKit
import Combine

/// Owns the menu bar status item: its button appearance, its menu, and the
/// mapping from `SpeechRecognitionService.DictationState` to an icon
/// treatment. Split out of `AppDelegate` so the delegate keeps only the menu
/// actions and the app lifecycle.
///
/// Menu items built here use a `nil` target so their actions travel the
/// responder chain to `AppDelegate`, which is how the menu already worked
/// before this type existed. Items owned by this controller set an explicit
/// target instead.
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private var cancellables = Set<AnyCancellable>()

    private var activationMenuItem: NSMenuItem?
    private var inputModeMenuItem: NSMenuItem?
    private var updateMenuItem: NSMenuItem?

    private var breatheTimer: Timer?
    private var breathePhase: Double = 0

    /// How the button renders in a given dictation state. `breathePeriod` of
    /// nil means a static icon.
    private struct IconStyle {
        let symbol: String
        let tinted: Bool
        let alpha: CGFloat
        let breathePeriod: Double?
    }

    init(activationTitle: String, inputModeTitle: String) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        buildMenu(activationTitle: activationTitle, inputModeTitle: inputModeTitle)
        apply(state: .idle)
        observeDictationState()
    }

    // MARK: - Menu

    private func buildMenu(activationTitle: String, inputModeTitle: String) {
        let menu = NSMenu()

        let activation = NSMenuItem(title: activationTitle, action: nil, keyEquivalent: "")
        activation.isEnabled = false
        menu.addItem(activation)
        activationMenuItem = activation

        let inputMode = NSMenuItem(title: inputModeTitle, action: nil, keyEquivalent: "")
        inputMode.isEnabled = false
        menu.addItem(inputMode)
        inputModeMenuItem = inputMode

        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(title: "Settings\u{2026}", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        )
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(title: "Check for Updates\u{2026}", action: #selector(AppDelegate.checkForUpdateManual), keyEquivalent: "")
        )
        menu.addItem(
            NSMenuItem(title: "About Orbit", action: #selector(AppDelegate.showAbout), keyEquivalent: "")
        )
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit Orbit",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        statusItem.menu = menu
    }

    func setActivationTitle(_ title: String) {
        activationMenuItem?.title = title
    }

    func setInputModeTitle(_ title: String) {
        inputModeMenuItem?.title = title
    }

    /// Inserts (or replaces) the "Update Available" item at the top of the
    /// menu, followed by a separator.
    func showUpdateItem(title: String, url: URL, target: AnyObject, action: Selector) {
        if let existing = updateMenuItem, let menu = statusItem.menu {
            let index = menu.index(of: existing)
            if index >= 0 {
                menu.removeItem(at: index + 1)
                menu.removeItem(existing)
            }
        }

        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = url
        statusItem.menu?.insertItem(item, at: 0)
        statusItem.menu?.insertItem(NSMenuItem.separator(), at: 1)
        updateMenuItem = item
    }

    // MARK: - Dictation state

    private func observeDictationState() {
        SpeechRecognitionService.shared.$dictationState
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.apply(state: state)
            }
            .store(in: &cancellables)
    }

    private func style(for state: SpeechRecognitionService.DictationState) -> IconStyle {
        switch state {
        case .idle:
            return IconStyle(symbol: "circle.dotted", tinted: false, alpha: 1.0, breathePeriod: nil)
        case .loading:
            return IconStyle(symbol: "circle.dotted", tinted: false, alpha: 0.45, breathePeriod: 1.6)
        case .starting:
            return IconStyle(symbol: "waveform", tinted: false, alpha: 0.45, breathePeriod: nil)
        case .listening:
            return IconStyle(symbol: "waveform", tinted: true, alpha: 1.0, breathePeriod: 1.2)
        case .transcribing:
            return IconStyle(symbol: "ellipsis", tinted: false, alpha: 1.0, breathePeriod: nil)
        }
    }

    private func apply(state: SpeechRecognitionService.DictationState) {
        guard let button = statusItem.button else { return }
        let style = style(for: state)

        button.image = NSImage(
            systemSymbolName: style.symbol,
            accessibilityDescription: "Orbit"
        )
        // The image must stay a template for `contentTintColor` to have any
        // effect. A non-template image ignores the tint entirely, which is
        // why the tinted state is expressed purely through the tint color.
        button.image?.isTemplate = true
        button.contentTintColor = style.tinted ? NSColor.controlAccentColor : nil

        if let period = style.breathePeriod {
            startBreathing(period: period, baseAlpha: style.alpha)
        } else {
            stopBreathing(resetTo: style.alpha)
        }
    }

    // MARK: - Breathe animation

    /// Oscillates the button's alpha between `baseAlpha` and 55% of it. Runs
    /// on `.common` so it keeps animating while a menu is open. Invalidated
    /// on every transition to a static state, so the icon is motionless
    /// except while loading or listening.
    private func startBreathing(period: Double, baseAlpha: CGFloat) {
        stopBreathing(resetTo: baseAlpha)
        breathePhase = 0
        let tick = 1.0 / 30.0
        let timer = Timer(timeInterval: tick, repeats: true) { [weak self] _ in
            guard let self, let button = self.statusItem.button else { return }
            self.breathePhase += tick / period * 2 * .pi
            let wave = (sin(self.breathePhase) + 1) / 2  // 0...1
            button.alphaValue = baseAlpha * (0.55 + 0.45 * CGFloat(wave))
        }
        RunLoop.main.add(timer, forMode: .common)
        breatheTimer = timer
    }

    private func stopBreathing(resetTo alpha: CGFloat) {
        breatheTimer?.invalidate()
        breatheTimer = nil
        statusItem.button?.alphaValue = alpha
    }
}
```

- [ ] **Step 2: Make the AppDelegate menu actions visible to the controller**

`#selector(AppDelegate.openSettings)` requires those methods to be `@objc` and non-private. In `Orbit/AppDelegate.swift`, change these three declarations from `@objc private func` to `@objc func`:

```swift
@objc func openSettings() {
@objc func checkForUpdateManual() {
@objc func showAbout() {
```

Leave `@objc private func openUpdate(_ sender: NSMenuItem)` private; it is passed by selector from within `AppDelegate` itself.

- [ ] **Step 3: Replace `setupStatusItem` in `AppDelegate`**

Delete the entire `setupStatusItem()` method (lines 95-136) and the three stored properties it populated (`statusItem`, `activationMenuItem`, `inputModeMenuItem`, `updateMenuItem`). Replace the property block at lines 6-16 with:

```swift
private var statusItemController: StatusItemController!
private var overlayPanel: OverlayPanel?
private var hotkeyService: HotkeyService!
private let viewModel = OrbitViewModel()
private let settings = SettingsService.shared
private var cancellables = Set<AnyCancellable>()
private var settingsWindow: NSWindow?
private var lastToggleTime: Date = .distantPast
```

In `applicationDidFinishLaunching`, replace `setupStatusItem()` with:

```swift
statusItemController = StatusItemController(
    activationTitle: activationDisplayString(),
    inputModeTitle: inputModeDisplayString()
)
```

- [ ] **Step 4: Repoint the remaining `AppDelegate` call sites**

In `observeSettingsChanges`, replace `self.activationMenuItem?.title = self.activationDisplayString()` with:

```swift
self.statusItemController.setActivationTitle(self.activationDisplayString())
```

and `self.inputModeMenuItem?.title = self.inputModeDisplayString()` with:

```swift
self.statusItemController.setInputModeTitle(self.inputModeDisplayString())
```

Replace the whole body of `showUpdateMenuItem(_ release:)` with:

```swift
private func showUpdateMenuItem(_ release: UpdateService.Release) {
    statusItemController.showUpdateItem(
        title: "Update Available (v\(release.version))",
        url: release.url,
        target: self,
        action: #selector(openUpdate(_:))
    )
}
```

- [ ] **Step 5: Register the new file with xcodegen**

`project.yml` globs the whole `Orbit` directory, so no edit is needed there, but the `.xcodeproj` must be regenerated if it is checked in and stale.

Run: `xcodegen generate`
Expected: `Created project at Orbit.xcodeproj`. If `xcodegen` is not installed, skip this step - `sources: - path: Orbit` picks up new files on the next build regardless.

- [ ] **Step 6: Build**

Run: `./build.sh`
Expected: `Copied to ./Orbit.app`, no errors.

- [ ] **Step 7: Verify the icon states**

Launch the freshly built `Orbit.app`. Watch the menu bar icon while running a dictation session.

Expected, with the panel still visible for comparison:

- Idle: a static dotted circle, full opacity.
- Cold start (quit and relaunch Orbit first so the model is unloaded): the dotted circle dims to about 45% and breathes slowly while the panel reads "Loading model…".
- Listening: the icon becomes a waveform in your macOS accent color and breathes faster. Confirm the color matches System Settings → Appearance → accent color by changing the accent and reopening a session.
- Stop with the hotkey after speaking: the icon becomes a static ellipsis for roughly half a second, then returns to the dotted circle.
- Escape: the icon returns to the dotted circle immediately, with no ellipsis.
- Speak, pause, speak again without stopping: the icon must stay a breathing waveform through the pause.

Also confirm the menu still works end to end: Settings…, Check for Updates…, About Orbit and Quit Orbit all respond, and the activation line at the top updates when you change the shortcut in Settings.

- [ ] **Step 8: Commit**

```bash
npx prettier --write .
git add Orbit/Services/StatusItemController.swift Orbit/AppDelegate.swift
git commit -m "feat: render dictation state in the menu bar icon"
```

---

### Task 3: Delete the floating panel and add the dictation menu items

**Files:**

- Delete: `Orbit/Views/RecordingIndicatorPanel.swift`
- Modify: `Orbit/Services/SpeechRecognitionService.swift`
- Modify: `Orbit/Services/StatusItemController.swift`

**Interfaces:**

- Consumes: `DictationState` from Task 1, `StatusItemController` from Task 2.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add the dictation menu items to `StatusItemController`**

Add these three stored properties next to `updateMenuItem`. All three items are tracked by reference, including the separator, so teardown never has to reason about indices:

```swift
private var dictationStatusItem: NSMenuItem?
private var stopDictationItem: NSMenuItem?
private var dictationSeparatorItem: NSMenuItem?
```

Add this method and its action:

```swift
/// Inserts a disabled status line plus a "Stop Dictation" command at the
/// top of the menu while a session is live, and removes both when it ends.
/// This is the visible replacement for the old click-to-stop panel, and the
/// only place the `.loading` message is still shown.
private func updateDictationMenuItems(for state: SpeechRecognitionService.DictationState) {
    guard let menu = statusItem.menu else { return }

    // Tear down whatever is currently installed, separator included.
    for item in [stopDictationItem, dictationStatusItem].compactMap({ $0 }) {
        let index = menu.index(of: item)
        if index >= 0 { menu.removeItem(at: index) }
    }
    if let separator = dictationSeparatorItem, menu.index(of: separator) >= 0 {
        menu.removeItem(separator)
    }
    dictationStatusItem = nil
    stopDictationItem = nil
    dictationSeparatorItem = nil

    let statusText: String
    switch state {
    case .idle: return
    case .loading(let message): statusText = message
    case .starting: statusText = "Starting\u{2026}"
    case .listening: statusText = "Listening\u{2026}"
    case .transcribing: statusText = "Transcribing\u{2026}"
    }

    let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
    status.isEnabled = false
    let stop = NSMenuItem(title: "Stop Dictation", action: #selector(stopDictation), keyEquivalent: "")
    stop.target = self
    let separator = NSMenuItem.separator()

    menu.insertItem(status, at: 0)
    menu.insertItem(stop, at: 1)
    menu.insertItem(separator, at: 2)
    dictationStatusItem = status
    stopDictationItem = stop
    dictationSeparatorItem = separator
}

@objc private func stopDictation() {
    SpeechRecognitionService.shared.stop(reason: "menu bar stop")
}
```

Call it from `apply(state:)`, as the last line of that method:

```swift
updateDictationMenuItems(for: state)
```

- [ ] **Step 2: Strip the panel out of `SpeechRecognitionService`**

Delete the stored property at line 107:

```swift
private var indicatorPanel: RecordingIndicatorPanel?
```

Delete the entire `// MARK: - Indicator` section at the end of the class (the `showIndicator(state:)` method, lines 916-924).

Then delete every remaining panel statement, keeping the `dictationState` assignment that Task 1 placed beside it:

- `startInternal` lines 284-293: delete the `if indicatorPanel != nil { ... }` block, the `let initialState: RecordingIndicatorPanel.State = ...` binding and the `showIndicator(state: initialState)` call. What remains is the single `dictationState = ...` assignment.
- `startInternal` permission-denied branch: delete the two `indicatorPanel` lines, keep `self.dictationState = .idle`.
- `startInternal` pre-capture branch: delete `self.indicatorPanel?.updateState(.starting)`.
- `ensureModelsLoaded`: delete the two `indicatorPanel` lines.
- `stop`: delete the two `indicatorPanel` lines at 400-401.
- `promoteWarmupToSession`: delete `indicatorPanel?.updateState(.listening)`.
- `beginCapture` engine-failure branch: delete the two `indicatorPanel` lines.
- `processAudioBuffer`: delete `self?.indicatorPanel?.updateState(.listening)`.

- [ ] **Step 3: Update the two stale doc comments**

At the top of the file, line 27-28 currently reads:

```swift
///   4. ESC or any other physical keypress stops the session. Click on the
///      indicator stops it. Re-triggering Orbit stops it.
```

Replace with:

```swift
///   4. ESC cancels the session (discarding the buffer). Re-triggering Orbit
///      stops it and commits. "Stop Dictation" in the menu bar stops it and
///      commits. Session state is published as `dictationState` and rendered
///      by `StatusItemController` in the menu bar.
```

In the `stop(reason:flushBuffer:)` doc comment at line 366-369, `the indicator click both commit` is now wrong. Replace that sentence with:

```swift
///     cancels". The hotkey re-trigger and the menu bar "Stop Dictation"
///     command both commit (flushBuffer=true) because using those means
///     "I'm done", not "throw it away".
```

In `installEscMonitor` at line 897, `click the indicator` is now wrong:

```swift
// dictation to typing should press ESC, use "Stop Dictation" in the
// menu bar, or re-trigger Orbit.
```

In the `stop` comment at line 411, `the indicator is already hidden` becomes `the menu bar has already returned to idle`.

- [ ] **Step 4: Delete the panel file**

```bash
git rm Orbit/Views/RecordingIndicatorPanel.swift
```

- [ ] **Step 5: Confirm nothing else references it**

Run: `grep -rn "RecordingIndicator\|indicatorPanel\|showIndicator\|hideIndicator" Orbit --include="*.swift"`
Expected: no output.

- [ ] **Step 6: Build**

Run: `./build.sh`
Expected: `Copied to ./Orbit.app`, no errors.

- [ ] **Step 7: Verify**

Launch the freshly built app.

- Run a dictation session. No panel appears anywhere near the cursor.
- While listening, open the menu bar menu. The top line reads "Listening…" and is greyed out; below it is "Stop Dictation".
- Click "Stop Dictation" mid-sentence. The spoken text is transcribed and pasted, and both menu items disappear.
- Start again and press Escape. The menu items disappear and no text is pasted.
- With the menu open during a session, confirm the icon keeps breathing (this is what `.common` run loop mode buys).
- Open the menu with no session running. The top item is the activation shortcut, exactly as before, with no dictation items.

- [ ] **Step 8: Commit**

```bash
npx prettier --write .
git add -A
git commit -m "feat: remove the floating dictation panel, add menu bar stop command"
```

---

### Task 4: Swallow Escape during a dictation session

Today `installEscMonitor` uses `NSEvent.addGlobalMonitorForEvents`, which can only _observe_ another app's key presses. Escape therefore cancels dictation **and** still reaches whatever app the user is typing into, where it closes their dialog, exits their editor mode, or dismisses their sheet. Consuming the key requires a `CGEvent` tap, which needs Accessibility permission - something Orbit already requires and already prompts for in `AppDelegate.promptAccessibilityIfNeeded`.

**Files:**

- Create: `Orbit/Services/EscapeKeyTap.swift`
- Modify: `Orbit/Services/SpeechRecognitionService.swift`

**Interfaces:**

- Consumes: nothing from earlier tasks.
- Produces: `EscapeKeyTap` with `init(onEscape: @escaping () -> Void)`, `func start() -> Bool` (false when the tap could not be created) and `func stop()`. Nothing later consumes it.

- [ ] **Step 1: Create the tap**

Create `Orbit/Services/EscapeKeyTap.swift`:

```swift
import AppKit
import ApplicationServices

/// Swallows the Escape key system-wide while active and reports each press
/// to `onEscape`. Used during dictation so that cancelling a session does
/// not also deliver an Escape to whatever app the user is typing into.
///
/// A `CGEvent` tap is the only way to *consume* a key press from another
/// app's event stream. `NSEvent.addGlobalMonitorForEvents` can observe but
/// never swallow, which is why this type exists. Taps require Accessibility
/// permission - already required by Orbit for its hotkey and text injection.
///
/// `start()` returns false when the tap cannot be created, so the caller can
/// fall back to an observe-only monitor. In that state Escape still cancels
/// dictation, it just also reaches the frontmost app.
final class EscapeKeyTap {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onEscape: () -> Void

    private static let escapeKeyCode: Int64 = 53

    init(onEscape: @escaping () -> Void) {
        self.onEscape = onEscape
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        // Both keyDown and keyUp: swallowing only the down would leave apps
        // that act on key-up seeing an Escape release with no press.
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        // The callback is a C function pointer and cannot capture, so `self`
        // travels through `userInfo` as an opaque pointer.
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<EscapeKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
            return tap.handle(type: type, event: event)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("[Orbit.speech] escape tap could not be created (Accessibility?), falling back to observe-only")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        tap = port
        runLoopSource = source
        NSLog("[Orbit.speech] escape tap installed")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that takes too long to respond, or when the
        // user input state is reset. Re-enable instead of silently going
        // deaf for the rest of the session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            NSLog("[Orbit.speech] escape tap was disabled by the system, re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        // Act on the press only; the release is swallowed silently. Hop to
        // main asynchronously so the event callback returns immediately -
        // a slow callback is exactly what makes macOS disable the tap.
        if type == .keyDown {
            DispatchQueue.main.async { [weak self] in self?.onEscape() }
        }
        return nil  // swallowed, never reaches the frontmost app
    }
}
```

- [ ] **Step 2: Use it in `SpeechRecognitionService`**

Replace the stored property at line 103:

```swift
private var escMonitor: Any?
```

with:

```swift
private var escTap: EscapeKeyTap?
/// Observe-only fallback, used only when the `CGEvent` tap cannot be
/// created. Escape still cancels, but also reaches the frontmost app.
private var escMonitor: Any?
```

Replace the whole `installEscMonitor()` method:

```swift
private func installEscMonitor() {
    // ESC = cancel (matches macOS Dictation). Discards the audio buffer
    // instead of transcribing it.
    //
    // The tap swallows the key so it never reaches the app the user is
    // typing into. Without that, cancelling dictation inside a dialog or a
    // modal editor would also dismiss it.
    //
    // "Stop on any keypress" was tried and reverted: it killed legitimate
    // sessions whenever an incidental keystroke arrived between audio
    // capture and the model finishing transcription (~600ms). Users who
    // want to switch from dictation to typing should press ESC, use
    // "Stop Dictation" in the menu bar, or re-trigger Orbit.
    let tap = EscapeKeyTap { [weak self] in
        self?.stop(reason: "esc", flushBuffer: false)
    }
    if tap.start() {
        escTap = tap
        return
    }

    escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self else { return }
        if event.keyCode != 53 { return }  // kVK_Escape
        DispatchQueue.main.async { self.stop(reason: "esc", flushBuffer: false) }
    }
}
```

In `stop(reason:flushBuffer:)`, replace the teardown block at lines 395-398:

```swift
escTap?.stop()
escTap = nil
if let monitor = escMonitor {
    NSEvent.removeMonitor(monitor)
    escMonitor = nil
}
```

- [ ] **Step 3: Update the header doc comment**

Task 3 rewrote the numbered list at line 27-28. Amend the Escape clause to note the swallow:

```swift
///   4. ESC cancels the session (discarding the buffer) and is swallowed so
///      it never reaches the app being typed into. Re-triggering Orbit stops
///      it and commits. "Stop Dictation" in the menu bar stops it and
///      commits. Session state is published as `dictationState` and rendered
///      by `StatusItemController` in the menu bar.
```

- [ ] **Step 4: Build**

Run: `./build.sh`
Expected: `Copied to ./Orbit.app`, no errors.

- [ ] **Step 5: Verify Escape is swallowed**

Launch the freshly built app. macOS may re-prompt for Accessibility because the binary changed; if the alert about a stale entry appears, toggle Orbit off and on in System Settings → Privacy & Security → Accessibility and relaunch.

Stream the logs to confirm the tap installed:

Run: `log stream --predicate 'process == "Orbit"' --style compact | grep Orbit.speech`
Expected on session start: `escape tap installed`. If you see `escape tap could not be created`, Accessibility is not actually granted - fix that before continuing, otherwise you are testing the fallback path.

Now the behavior itself. Open TextEdit, then Format → Font to open the Fonts panel, click into the document, and start dictation. Press Escape.
Expected: dictation cancels and the Fonts panel stays open. Before this task the panel would close.

Second check, in Safari: open any page, press Command-F to show the find bar, click into the page, start dictation, press Escape.
Expected: dictation cancels and the find bar stays open.

Third check, that nothing else is swallowed: start dictation, type a few ordinary characters and press Tab and Return.
Expected: every one of them lands in the target app as usual. Only Escape is intercepted.

Fourth check, that the tap is torn down: stop a session with the hotkey, then press Escape in TextEdit's Fonts panel.
Expected: the panel closes. Escape must behave completely normally when no session is running.

- [ ] **Step 6: Commit**

```bash
npx prettier --write .
git add Orbit/Services/EscapeKeyTap.swift Orbit/Services/SpeechRecognitionService.swift
git commit -m "feat: swallow ESC during dictation so it doesn't reach the target app"
```

---

### Task 5: Rename angle properties to preferred angles

Pure mechanical rename. No behavior change, no UserDefaults key change. Doing it on its own keeps the algorithm diff in Task 6 readable.

**Files:**

- Modify: `Orbit/Services/SettingsService.swift`
- Modify: `Orbit/ViewModels/OrbitViewModel.swift`
- Modify: `Orbit/Views/LayoutPreviewView.swift`
- Modify: `Orbit/Views/SettingsView.swift`

**Interfaces:**

- Consumes: nothing.
- Produces: `SettingsService.pinnedPreferredAngles: [String: Double]`, `SettingsService.dictationPreferredAngle: Double?`, `SettingsService.allPreferredAngles: [Double]`, `SettingsService.ensurePreferredAngles()`. Tasks 6 and 7 use these names.

- [ ] **Step 1: Rename in `SettingsService`**

- `@Published var pinnedAngles` becomes `@Published var pinnedPreferredAngles` (line 30)
- `@Published var dictationAngle` becomes `@Published var dictationPreferredAngle` (line 31)
- `var allAnchorAngles` becomes `var allPreferredAngles` (line 114)
- `func ensureAnchorAngles()` becomes `func ensurePreferredAngles()` (line 127)

Every string literal `"pinnedAngles"` and `"dictationAngle"` passed to `UserDefaults` stays exactly as it is. There are four of them: lines 62, 63, 96, 98 and 100.

Update the doc comment on `ensurePreferredAngles` to describe preferences rather than positions:

```swift
/// Ensures every currently-pinned bundle id, and the dictation tile when
/// enabled, has a stored preferred direction. Newly seen items get the
/// center of the largest currently-empty arc, then auto-save. A preference
/// is a direction the ring solver aims for, not a fixed position: the item
/// lands on whichever free slot sits closest to it.
```

- [ ] **Step 2: Rename at the call sites**

`Orbit/ViewModels/OrbitViewModel.swift` lines 62, 71, 75, 80.
`Orbit/Views/LayoutPreviewView.swift` lines 231, 238, 250, 269, 272.
`Orbit/Views/SettingsView.swift` line 257.

- [ ] **Step 3: Confirm the rename is complete**

Run: `grep -rn "pinnedAngles\|dictationAngle\|allAnchorAngles\|ensureAnchorAngles" Orbit --include="*.swift"`
Expected: exactly five hits, all of them the UserDefaults key strings in `SettingsService.swift` (lines 62, 63, 96, 98, 100). Any hit that is not a quoted string literal is a missed rename.

- [ ] **Step 4: Build**

Run: `./build.sh`
Expected: `Copied to ./Orbit.app`, no errors.

- [ ] **Step 5: Verify settings survive**

Launch the freshly built app. Open Settings → Layout.
Expected: your existing pinned apps are still at the positions they were at before this change. If the preview is empty or everything reset to 12 o'clock, a UserDefaults key was renamed by mistake.

- [ ] **Step 6: Commit**

```bash
npx prettier --write .
git add Orbit/Services/SettingsService.swift Orbit/ViewModels/OrbitViewModel.swift Orbit/Views/LayoutPreviewView.swift Orbit/Views/SettingsView.swift
git commit -m "refactor: rename ring angles to preferred angles"
```

---

### Task 6: Rewrite `RingLayout.compute` as slot assignment

**Files:**

- Modify: `Orbit/Models/RingLayout.swift`
- Modify: `Orbit/ViewModels/OrbitViewModel.swift:69-88`

**Interfaces:**

- Consumes: `SettingsService.pinnedPreferredAngles` and `dictationPreferredAngle` from Task 5.
- Produces: `RingLayout.compute(preferred: [(item: OrbitItem, preferredAngle: Double)], others: [OrbitItem]) -> [Positioned]`. Task 7 calls this exact signature. `Positioned` keeps its existing shape: `let item: OrbitItem`, `let angleDegrees: Double`, `let isAnchored: Bool`.

- [ ] **Step 1: Replace the body of `RingLayout.swift`**

Keep `import Foundation`, the `Positioned` struct, `nextAnchorAngle(existingAngles:)` and `normalize(_:)` exactly as they are. Replace `compute` and delete `evenDistribution` entirely.

Update the type doc comment at the top of the file:

```swift
/// Pure-data layout engine for the Orbit ring.
///
/// The ring is always evenly divided: `n` items means `n` slots, slot `i` at
/// `i * 360/n` degrees. Slot 0 is always twelve o'clock, so a preference of 0
/// always resolves to the top no matter how many apps are running.
///
/// Pinned apps and the dictation tile carry a *preferred direction*, not a
/// position. Each claims the free slot nearest its preference; everything
/// else fills what is left. This is what keeps the ring evenly spaced no
/// matter how many apps macOS reports as running, which fixed-angle anchors
/// could not do - clustered pins used to cram together and smear every
/// auto-added app across the remaining arc.
///
/// Angles are degrees with 0 at twelve o'clock, increasing clockwise. Output
/// is sorted clockwise from twelve, so the returned indices drive
/// scroll-to-rotate, arrow-key navigation and selection math unchanged.
```

Then:

```swift
/// Resolve `preferred` items onto the evenly spaced slot nearest each one's
/// preferred direction, and fill every remaining slot with `others` in the
/// order given.
static func compute(
    preferred: [(item: OrbitItem, preferredAngle: Double)],
    others: [OrbitItem]
) -> [Positioned] {
    let n = preferred.count + others.count
    guard n > 0 else { return [] }

    let step = 360.0 / Double(n)
    var slots: [Positioned?] = Array(repeating: nil, count: n)

    /// A preferred item's bid for a slot. `residual` is how far the
    /// preference sits from the slot it would ideally take.
    struct Claim {
        let item: OrbitItem
        let idealSlot: Int
        let residual: Double
        let normalizedAngle: Double
    }

    // Rank by residual so the closest claim is honored first. Without this
    // the result would depend on the order of `pinnedBundleIds`, which is
    // the order the user happened to pin things in - not something they
    // can see or reason about.
    let claims: [Claim] = preferred
        .map { entry in
            let angle = normalize(entry.preferredAngle)
            let ideal = Int((angle / step).rounded()) % n
            return Claim(
                item: entry.item,
                idealSlot: ideal,
                residual: abs(smallestDifference(angle, Double(ideal) * step)),
                normalizedAngle: angle
            )
        }
        .sorted {
            $0.residual == $1.residual
                ? $0.normalizedAngle < $1.normalizedAngle
                : $0.residual < $1.residual
        }

    for claim in claims {
        let slot = firstFreeSlot(from: claim.idealSlot, in: slots)
        slots[slot] = Positioned(
            item: claim.item,
            angleDegrees: Double(slot) * step,
            isAnchored: true
        )
    }

    var remaining = others.makeIterator()
    for i in 0..<n where slots[i] == nil {
        guard let item = remaining.next() else { break }
        slots[i] = Positioned(
            item: item,
            angleDegrees: Double(i) * step,
            isAnchored: false
        )
    }

    return slots.compactMap { $0 }
}

/// Walks outward from `ideal`, alternating clockwise and counter-clockwise,
/// for the first unoccupied slot. Always succeeds: preferred items are
/// themselves counted in `slots.count`, so demand never exceeds supply.
private static func firstFreeSlot(from ideal: Int, in slots: [Positioned?]) -> Int {
    let n = slots.count
    if slots[ideal] == nil { return ideal }
    for offset in 1...n {
        let clockwise = (ideal + offset) % n
        if slots[clockwise] == nil { return clockwise }
        let counter = ((ideal - offset) % n + n) % n
        if slots[counter] == nil { return counter }
    }
    return ideal  // unreachable
}

/// Signed shortest angular distance from `b` to `a`, in (-180, 180].
private static func smallestDifference(_ a: Double, _ b: Double) -> Double {
    var diff = a - b
    while diff > 180 { diff -= 360 }
    while diff < -180 { diff += 360 }
    return diff
}
```

- [ ] **Step 2: Rewrite the call site in `OrbitViewModel.show()`**

Replace lines 69-88 with:

```swift
// Build the preferred (item, direction) list from the user's stored
// preferences. These are directions the solver aims for, not positions.
var preferred: [(item: OrbitItem, preferredAngle: Double)] = []
if settings.dictationEnabled, let angle = settings.dictationPreferredAngle {
    preferred.append((.dictation, angle))
}
for app in anchoredApps {
    if let bundleId = app.bundleIdentifier, let angle = settings.pinnedPreferredAngles[bundleId] {
        preferred.append((.app(app), angle))
    }
}

NSLog("[Orbit.layout] show() dictationPref=\(String(describing: settings.dictationPreferredAngle)) pinPrefs=\(settings.pinnedPreferredAngles)")
NSLog("[Orbit.layout] show() preferred=\(preferred.map { "\($0.item.id)@\(Int($0.preferredAngle))°" })")

positionedItems = RingLayout.compute(
    preferred: preferred,
    others: nonPinnedApps.map(OrbitItem.app)
)

NSLog("[Orbit.layout] show() positioned=\(positionedItems.map { "\($0.item.id)@\(Int($0.angleDegrees))°\($0.isAnchored ? "*" : "")" })")
```

Rename the local `anchored` to `preferred` throughout; there are no other references to it.

- [ ] **Step 3: Build**

Run: `./build.sh`
Expected: `Copied to ./Orbit.app`, no errors.

- [ ] **Step 4: Verify the assignment against the log**

Launch the freshly built app and stream layout logs:

Run: `log stream --predicate 'process == "Orbit"' --style compact | grep Orbit.layout`

Open the ring and read the `positioned=` line. Check each of these:

1. **Even spacing.** With `n` items in the line, consecutive angles must differ by exactly `360/n`, and the first must be `0`. With 9 items: `0, 40, 80, 120, 160, 200, 240, 280, 320`.
2. **Twelve o'clock is honored.** In Settings → Layout, drag one pinned app to the top. Reopen the ring. That app must appear at `0°` in the log, marked with `*`.
3. **Clustered pins no longer cram.** Pin three apps and drag all three into the top-right quadrant, within about 30° of each other. Reopen the ring. All three must still be `360/n` apart in the log, not 15° apart.
4. **No preferences means unchanged behavior.** Unpin everything and disable dictation. The log must show every app evenly spaced with no `*` markers.
5. **Order is stable across the same app set.** Open and close the ring three times without launching anything. The `positioned=` line must be identical each time.

Then confirm interaction still works: open the ring, scroll to rotate the selection all the way round, use the left and right arrow keys, and press Enter to switch. Selection must follow the visible clockwise order with no jumps.

- [ ] **Step 5: Commit**

```bash
npx prettier --write .
git add Orbit/Models/RingLayout.swift Orbit/ViewModels/OrbitViewModel.swift
git commit -m "feat: resolve ring anchors onto evenly spaced slots"
```

---

### Task 7: Rebuild `LayoutPreviewView` as a live simulation

**Files:**

- Modify: `Orbit/Views/LayoutPreviewView.swift` (full rewrite)

**Interfaces:**

- Consumes: `RingLayout.compute(preferred:others:)` from Task 6, the renamed `SettingsService` properties from Task 5, `AppService.runningApps(excluding:pinnedFirst:)`.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Replace the file**

Two things in the old file are load-bearing and must survive the rewrite: the `.coordinateSpace(name: "layoutRing")` modifier belongs on the ring `ZStack`, not on individual icons, and icon placement must use `.position()` rather than `.offset()` because `.offset` moves the visual without moving the hit-testing region, which silently breaks drags.

Replace `Orbit/Views/LayoutPreviewView.swift` with:

```swift
import AppKit
import SwiftUI

/// Live preview of the resolved ring. Pinned apps and the dictation tile are
/// draggable and set a preferred direction; every non-pinned running app is
/// drawn dimmed and smaller so the user can see what the ring will actually
/// look like rather than an abstract set of anchors.
///
/// This view calls the same `RingLayout.compute` the real ring uses, so the
/// preview cannot drift from the thing it is previewing.
struct LayoutPreviewView: View {
    @ObservedObject var settings = SettingsService.shared
    @State private var runningApps: [RunningApp] = []
    @State private var draggingId: String?
    @State private var dragAngle: Double = 0

    private let diameter: CGFloat = 280
    private let anchorIconSize: CGFloat = 44
    private let otherIconSize: CGFloat = 26

    private var ringRadius: CGFloat { (diameter - 40) / 2 }
    private var center: CGPoint { CGPoint(x: diameter / 2, y: diameter / 2) }

    var body: some View {
        VStack(spacing: 12) {
            Text("Drag a pinned app to roughly where you want it. Orbit keeps every app evenly spaced and gives each pinned app the free slot closest to your direction.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    .frame(width: ringRadius * 2, height: ringRadius * 2)

                ForEach(0..<4, id: \.self) { i in
                    Rectangle()
                        .fill(Color.primary.opacity(0.25))
                        .frame(width: 1, height: 6)
                        .offset(y: -ringRadius)
                        .rotationEffect(.degrees(Double(i) * 90))
                }

                Circle()
                    .fill(Color.primary.opacity(0.3))
                    .frame(width: 4, height: 4)

                if draggingId != nil {
                    preferenceRay
                    resolvedSlotDot
                }

                ForEach(resolvedRing, id: \.item.id) { positioned in
                    tile(positioned)
                }

                // The ring is almost never empty - every running app is in
                // it - so the empty state keys off having nothing draggable,
                // and sits in the middle of the dimmed apps rather than
                // replacing them.
                if !hasAnchors {
                    Text("Nothing pinned yet.\nPin an app or enable dictation to place it here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 160)
                }
            }
            .frame(width: diameter, height: diameter)
            .coordinateSpace(name: "layoutRing")
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .padding(8)
            )
            .animation(
                .interpolatingSpring(stiffness: 260, damping: 22),
                value: resolvedRing.map(\.angleDegrees)
            )

            Text("Dimmed icons are running apps that aren't pinned. They fill whatever slots are left.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Reset to default layout") {
                settings.resetLayoutAngles()
                reload()
            }
            .buttonStyle(.borderless)
            .disabled(!hasAnchors)
        }
        .padding(.vertical, 12)
        .onAppear { reload() }
        .onChange(of: settings.pinnedBundleIds) { reload() }
        .onChange(of: settings.dictationEnabled) { reload() }
    }

    // MARK: - Ring resolution

    /// The ring as `RingLayout` resolves it right now. While a drag is in
    /// flight the dragged item's stored preference is replaced by the live
    /// drag angle, so the rest of the ring re-solves under the cursor.
    private var resolvedRing: [RingLayout.Positioned] {
        var preferred: [(item: OrbitItem, preferredAngle: Double)] = []
        var others: [OrbitItem] = []

        if settings.dictationEnabled, let stored = settings.dictationPreferredAngle {
            let angle = (draggingId == "dictation") ? dragAngle : stored
            preferred.append((.dictation, angle))
        }

        for app in runningApps {
            guard let bundleId = app.bundleIdentifier,
                  let stored = settings.pinnedPreferredAngles[bundleId]
            else {
                others.append(.app(app))
                continue
            }
            let id = "app:\(bundleId)"
            let angle = (draggingId == id) ? dragAngle : stored
            preferred.append((.app(app), angle))
        }

        return RingLayout.compute(preferred: preferred, others: others)
    }

    /// True when there is at least one draggable item in the ring.
    private var hasAnchors: Bool {
        resolvedRing.contains { $0.isAnchored }
    }

    /// The drag id for an item, or nil when it is not draggable.
    private func anchorId(for item: OrbitItem) -> String? {
        switch item {
        case .dictation:
            return "dictation"
        case .app(let app):
            guard let bundleId = app.bundleIdentifier,
                  settings.pinnedPreferredAngles[bundleId] != nil
            else { return nil }
            return "app:\(bundleId)"
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func tile(_ positioned: RingLayout.Positioned) -> some View {
        let id = anchorId(for: positioned.item)
        let isDragged = id != nil && id == draggingId
        // The dragged icon follows the cursor freely; everything else sits on
        // its resolved slot.
        let angle = isDragged ? dragAngle : positioned.angleDegrees
        let size = positioned.isAnchored ? anchorIconSize : otherIconSize

        Group {
            switch positioned.item {
            case .app(let app):
                Image(nsImage: app.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
            case .dictation:
                RoundedRectangle(cornerRadius: size * 0.18)
                    .fill(.ultraThinMaterial)
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "mic.fill")
                            .font(.system(size: size * 0.5, weight: .medium))
                            .foregroundStyle(.primary)
                    )
            }
        }
        .opacity(positioned.isAnchored ? 1.0 : 0.35)
        .position(positionForAngle(angle))
        .allowsHitTesting(positioned.isAnchored)
        .gesture(dragGesture(for: id))
    }

    private func dragGesture(for id: String?) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("layoutRing"))
            .onChanged { value in
                guard let id else { return }
                draggingId = id
                dragAngle = angleFrom(point: value.location)
            }
            .onEnded { value in
                guard let id else { return }
                let angle = angleFrom(point: value.location)
                draggingId = nil
                dragAngle = angle
                commit(id: id, angle: angle)
            }
    }

    /// Hairline from the center showing the direction the cursor is pointing.
    private var preferenceRay: some View {
        Path { path in
            path.move(to: center)
            path.addLine(to: positionForAngle(dragAngle))
        }
        .stroke(Color.primary.opacity(0.25), lineWidth: 1)
    }

    /// Small accent dot marking the slot the dragged item will land on.
    @ViewBuilder
    private var resolvedSlotDot: some View {
        if let draggingId,
           let resolved = resolvedRing.first(where: { anchorId(for: $0.item) == draggingId })
        {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
                .position(positionForAngle(resolved.angleDegrees))
        }
    }

    // MARK: - Angle math

    /// Convert a point in the ring's named coordinate space into a
    /// degrees-clockwise-from-twelve angle. SwiftUI's +y goes down, so twelve
    /// o'clock is -y and `atan2(dx, -dy)` gives the clockwise angle.
    private func angleFrom(point: CGPoint) -> Double {
        let dx = point.x - center.x
        let dy = point.y - center.y
        var degrees = atan2(dx, -dy) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    /// 0 degrees is twelve o'clock, clockwise. In SwiftUI's +y-down space
    /// that is x = sin(theta), y = -cos(theta).
    private func positionForAngle(_ degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(
            x: center.x + CGFloat(sin(radians)) * ringRadius,
            y: center.y - CGFloat(cos(radians)) * ringRadius
        )
    }

    // MARK: - Persistence

    private func reload() {
        settings.ensurePreferredAngles()
        runningApps = AppService.runningApps(
            excluding: settings.excludedBundleIds,
            pinnedFirst: settings.pinnedBundleIds
        )
    }

    private func commit(id: String, angle: Double) {
        if id == "dictation" {
            settings.dictationPreferredAngle = angle
        } else {
            settings.pinnedPreferredAngles[String(id.dropFirst("app:".count))] = angle
        }
        settings.save()
    }
}
```

- [ ] **Step 2: Build**

Run: `./build.sh`
Expected: `Copied to ./Orbit.app`, no errors.

- [ ] **Step 3: Verify the preview**

Launch the freshly built app and open Settings → Layout.

- The preview shows every running app, not just the pinned ones. Pinned apps and the dictation tile are large and fully opaque; the rest are small and dimmed.
- Drag a pinned app slowly around the circle. The icon follows the cursor freely, a hairline points from the center to the cursor, an accent dot marks the slot it will land on, and the dimmed icons visibly rearrange as you cross slot boundaries.
- Release. The icon animates onto the dot's position.
- Try to drag a dimmed icon. Nothing happens.
- Drag two pinned apps to nearly the same direction. Both must end up on adjacent slots, never stacked on the same point.
- Close Settings, open the ring. The real ring must match what the preview showed.
- Click "Reset to default layout". Pinned apps redistribute and the preview updates immediately.
- Unpin everything and disable dictation. The dimmed running apps stay on the ring, "Nothing pinned yet." appears in the middle, and "Reset to default layout" is disabled.

- [ ] **Step 4: Commit**

```bash
npx prettier --write .
git add Orbit/Views/LayoutPreviewView.swift
git commit -m "feat: preview the resolved ring live in Settings"
```

---

### Task 8: Update SPEC.md, CHANGELOG.md and the version

**Files:**

- Modify: `SPEC.md`
- Modify: `CHANGELOG.md`
- Modify: `project.yml`

**Interfaces:**

- Consumes: everything from Tasks 1-7.
- Produces: nothing.

- [ ] **Step 1: Update the file tree and AppDelegate sections of SPEC.md**

Line 44-45: remove the `RecordingIndicatorPanel.swift` entry and update the `LayoutPreviewView.swift` description to "Live preview of the resolved ring; drag pinned apps to set a preferred direction". Under the Services group add two entries:

```
│   ├── StatusItemController.swift # Menu bar status item: icon states, menu, dictation stop command
│   ├── EscapeKeyTap.swift    # CGEvent tap that swallows ESC during a dictation session
```

Line 63: the menu bar status item no longer uses a single fixed symbol. Replace it with this table:

| state        | SF Symbol       | treatment                                                        |
| ------------ | --------------- | ---------------------------------------------------------------- |
| idle         | `circle.dotted` | template, full opacity, static                                   |
| loading      | `circle.dotted` | template, 45% alpha, 1.6 s breathe                               |
| starting     | `waveform`      | template, 45% alpha, static                                      |
| listening    | `waveform`      | `NSColor.controlAccentColor`, 1.2 s breathe between 100% and 55% |
| transcribing | `ellipsis`      | template, full opacity, static                                   |

The `## AppDelegate` section (lines 58-73) must say that the status item is owned by `StatusItemController` and that `AppDelegate` retains only the menu actions.

- [ ] **Step 2: Rewrite the `## RingLayout` section (lines 101-120)**

Replace the description of anchors-at-exact-angles plus proportional gap filling with the slot model: `n` items means `n` slots at `i * 360/n`, slot 0 at twelve o'clock, preferred items ranked by residual and claiming the nearest free slot with an alternating outward search, remaining slots filled by `others` in order. State the new `compute` signature. Keep the existing `nextAnchorAngle` paragraph at line 119 unchanged, since that function is unchanged, but soften "This matters because `compute` has no duplicate handling: two anchors sharing an angle render stacked on the same point" - `compute` now separates duplicate preferences onto adjacent slots, so the stacking failure it describes can no longer happen. Say that instead.

- [ ] **Step 3: Update the `SettingsService` sections**

Lines 223-224: rename the property column entries to `pinnedPreferredAngles` and `dictationPreferredAngle`, leaving the UserDefaults key column as `pinnedAngles` and `dictationAngle`, and add a note that the keys deliberately differ from the property names so existing installs upgrade without migration.

Lines 227, 229: update the property names and change "maps bundle id to a clockwise-from-12-o'clock angle" to describe a preferred direction rather than a position.

Lines 231-235 (`### Layout angles`): rename to `### Layout preferences`, and rename `allAnchorAngles` and `ensureAnchorAngles()` to `allPreferredAngles` and `ensurePreferredAngles()` throughout.

- [ ] **Step 4: Replace the `### Floating indicator` section (lines 333-348)**

Delete it and write a `### Menu bar feedback` section in its place covering: the `DictationState` enum and its five cases, that `.transcribing` covers only the post-stop final flush and never a mid-session VAD flush, the icon treatment per state, that the accent is `NSColor.controlAccentColor` applied as `contentTintColor`, that the breathe is a 30 fps `Timer` on `.common` run loop mode oscillating alpha between the base and 55% of it, and that the menu grows a disabled status line plus a "Stop Dictation" item while a session is live.

- [ ] **Step 5: Document the Escape tap**

Add a `### Escape handling` subsection under `## SpeechRecognitionService`, after the `### Permissions` section (line 315). Cover: that a `CGEvent` tap is installed for the duration of a session and swallows both keyDown and keyUp for keycode 53 so Escape never reaches the frontmost app, that Escape cancels rather than commits (the buffer is discarded, matching macOS Dictation), that the tap re-enables itself on `tapDisabledByTimeout` and `tapDisabledByUserInput`, that it requires Accessibility permission, and that `start()` returning false falls back to an observe-only `NSEvent` global monitor where Escape still cancels but also reaches the target app.

The `### Permissions` section itself must now list Accessibility as required for Escape interception, alongside the existing hotkey and text-injection uses.

- [ ] **Step 6: Update the remaining stale references**

Line 412-421 (`### Ring Contents (show)`): step 1 calls `ensurePreferredAngles()`, step 2 builds a `preferred` list of directions, and a new step describes the slot resolution.

Line 512: the `DictationTileView` note says `isAnchored` exists "so `LayoutPreviewView` can render it unanchored". That is still true but for a new reason - the preview now renders non-pinned apps unanchored too. Update the wording.

Line 549: `SettingsService.ensureAnchorAngles()` becomes `ensurePreferredAngles()`.

Line 567-570 (`### Layout Tab`): rewrite completely. No 15 degree snapping, no 5 degree collision threshold, no outward 15 degree search. Describe the live simulation: all running apps shown, anchors at 44pt full opacity and draggable, non-pinned at 26pt and 35% opacity and not hit-testable, free drag with a preference hairline and a resolved-slot dot, and the same `RingLayout.compute` call the real ring uses.

- [ ] **Step 7: Confirm no stale references remain**

Run: `grep -n "RecordingIndicator\|pinnedAngles\|dictationAngle\|ensureAnchorAngles\|allAnchorAngles\|15°\|snap" SPEC.md`
Expected: the only hits are the two UserDefaults key names in the stored-properties table, which are intentionally unchanged.

- [ ] **Step 8: Add the CHANGELOG entry and bump the version**

At the top of `CHANGELOG.md`, directly below `# Changelog`:

```markdown
## 2.2.0

### Changed

- Dictation feedback moved from a floating panel near the cursor into the menu bar icon. The panel sat exactly where you were working; the icon now carries the whole session through four visible states - a dimmed breathing dotted circle while the model loads, an accent-colored breathing waveform while listening, a static ellipsis while the final utterance is transcribed, and the plain dotted circle at rest. The menu grows a status line and a "Stop Dictation" command while a session is live, replacing the panel's click-to-stop. ESC still cancels and the hotkey still stops and commits, both unchanged.
- Pinned ring positions are now preferred directions rather than fixed angles. The ring is always evenly divided into as many slots as there are items, and each pinned app takes the free slot closest to the direction you dragged it. Clustering three pins in one quadrant no longer crams them together and smears every auto-added app across the rest of the circle. Existing pinned positions are read as preferences, so nothing needs to be set up again.
- The Layout tab now previews the resolved ring with every running app in it, instead of showing the pinned apps alone. Non-pinned apps are drawn small and dimmed, and rearrange live as you drag. Dragging is free - there is no 15 degree snapping and no collision nudging, because the solver quantizes to slots regardless.

### Fixed

- Pressing Escape to cancel dictation no longer leaks the key press into the app you were typing in. It used to cancel the session and then also close your dialog, dismiss your find bar, or drop you out of your editor's insert mode. Escape is now intercepted for the duration of a session and consumed. This needs Accessibility permission, which Orbit already requires; without it, Escape still cancels dictation exactly as before.

### Removed

- `RecordingIndicatorPanel`, the floating "Listening…" panel.
```

In `project.yml`, change `MARKETING_VERSION: "2.1.0"` to `MARKETING_VERSION: "2.2.0"`.

- [ ] **Step 9: Final build and smoke test**

Run: `./build.sh`
Expected: `Copied to ./Orbit.app`, no errors.

Launch it and confirm the whole flow once more end to end: open the ring, switch to an app, open the ring again, run a dictation session and watch the menu bar through it, stop with "Stop Dictation", open Settings → Layout and drag a pinned app, then reopen the ring and confirm it matches.

- [ ] **Step 10: Commit**

```bash
npx prettier --write .
git add SPEC.md CHANGELOG.md project.yml
git commit -m "docs: update SPEC and CHANGELOG for 2.2.0"
```
