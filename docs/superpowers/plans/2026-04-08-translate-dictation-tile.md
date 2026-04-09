# Translate-to-English Dictation Tile + Mic Device Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two bundled Dictation-tab improvements: (1) a new Orbit ring tile that takes audio in a configurable source language (default `sv_SE`) and pastes English text via WhisperKit's `task: .translate`; (2) a new Settings picker that lets the user pin Whisper to a specific microphone device independent of the macOS system default.

**Architecture:** For (1), new `OrbitItem.translate(TranslatePair)` case + new `TranslateTileView` rendering two flags side-by-side. `SpeechRecognitionService.start()` is split into `startDictation` and `startTranslation` so call sites are self-documenting. The translate path threads `task: .translate` through `DecodingOptions`. For (2), a new `AudioInputDeviceService` enum wraps CoreAudio device enumeration, a new `dictationInputDeviceUID: String?` field in `SettingsService` stores the chosen device's persistent UID, and `SpeechRecognitionService.beginCapture` configures `kAudioOutputUnitProperty_CurrentDevice` on the input node's audio unit before starting the engine.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, AVFoundation, CoreAudio, WhisperKit (CoreML on Apple Silicon), xcodegen for project generation.

**Spec:** `docs/superpowers/specs/2026-04-08-translate-dictation-design.md`

**Project conventions you must follow:**

- Orbit uses xcodegen — `project.yml` includes `Orbit/` recursively. **After creating any new `.swift` file you MUST run `xcodegen generate`** before building, or the new file will not be in the Xcode project and the build will silently ignore it.
- Build command: `xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug -destination 'platform=macOS' build` (faster than `./build.sh` which uses Release config and copies the binary). Use `./build.sh` only at the very end of the plan to produce the runnable `.app`.
- Format command (run before every commit): `npx prettier --write .`
- There is **no test target**. Verification of new logic is done by `xcodebuild` (compilation = green) plus the manual smoke test in Task 12.
- Commit after each task. Use Conventional Commits style matching git log: `feat: ...`, `refactor: ...`, `chore: ...`.
- Never amend existing commits — always create new commits.

---

## File map

| File                                            | Action     | Responsibility                                                                                                                                                                                                                                                                                                                                                           |
| ----------------------------------------------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `Orbit/Models/TranslatePair.swift`              | **Create** | `TranslatePair` struct (source + target `DictationLanguage`)                                                                                                                                                                                                                                                                                                             |
| `Orbit/Models/OrbitItem.swift`                  | Modify     | Add `.translate(TranslatePair)` case + update `id` and `displayName`                                                                                                                                                                                                                                                                                                     |
| `Orbit/Services/AudioInputDeviceService.swift`  | **Create** | CoreAudio enumeration of input devices + UID-to-AudioDeviceID lookup                                                                                                                                                                                                                                                                                                     |
| `Orbit/Services/SettingsService.swift`          | Modify     | Add `translateTileEnabled`, `translateSourceLocaleId`, `translateAngle`, `dictationInputDeviceUID` fields, `translatePair` computed property, extend `allAnchorAngles` and `ensureAnchorAngles`                                                                                                                                                                          |
| `Orbit/Services/SpeechRecognitionService.swift` | Modify     | Replace `start(localeId:)` with `startDictation` + `startTranslation` delegating to private `startInternal(localeId:task:targetLocaleIdForDisplay:)`. Add `currentTask` and `currentTranslationTargetId` private state. Use `currentTask` in `flushAndTranscribe` and `stop` final-flush. Reset state in `stop`. Add device-selection step at the top of `beginCapture`. |
| `Orbit/Services/DictationService.swift`         | Modify     | Update inner call to `startDictation`. Add `startTranslation(pair:)` static method.                                                                                                                                                                                                                                                                                      |
| `Orbit/Views/TranslateTileView.swift`           | **Create** | Ring tile rendering two flags + arrow, matching `LanguageTileView`'s visual treatment                                                                                                                                                                                                                                                                                    |
| `Orbit/ViewModels/OrbitViewModel.swift`         | Modify     | `show()` appends translate tile to anchored items when `settings.translatePair` is non-nil. `selectAndSwitch()` adds `.translate` case.                                                                                                                                                                                                                                  |
| `Orbit/Views/OrbitView.swift`                   | Modify     | Add `.translate` case to the tile rendering switch                                                                                                                                                                                                                                                                                                                       |
| `Orbit/Views/RecordingIndicatorPanel.swift`     | Modify     | `show()` gains optional `targetLocaleId`. Model gains `targetLocaleId`. View renders source flag → target flag when present.                                                                                                                                                                                                                                             |
| `Orbit/Views/SettingsView.swift`                | Modify     | Add "Translation" and "Microphone" subsections in Dictation tab.                                                                                                                                                                                                                                                                                                         |
| `SPEC.md`                                       | Modify     | Document all new behavior per the spec's "SPEC.md updates" section                                                                                                                                                                                                                                                                                                       |

---

## Task 1: Create `TranslatePair` model

**Files:**

- Create: `Orbit/Models/TranslatePair.swift`

- [ ] **Step 1: Create the file**

```swift
// Orbit/Models/TranslatePair.swift
import Foundation

/// A configured translate-dictation pair: a source language the user speaks
/// in, and the English target variant Whisper outputs into. Target is purely
/// cosmetic — Whisper's `.translate` task always outputs English regardless
/// of which `en_*` variant we display in the tile.
///
/// `id` is keyed only on `source.id` because there is exactly one translate
/// tile in the ring at a time, and the anchor angle must remain stable when
/// the user switches their enabled `en_*` variant in System Settings
/// (otherwise changing `en_US` → `en_GB` would visually move the tile).
struct TranslatePair: Identifiable, Equatable {
    let source: DictationLanguage
    let target: DictationLanguage

    var id: String { "translate:\(source.id)" }
}
```

- [ ] **Step 2: Regenerate Xcode project**

```bash
xcodegen generate
```

Expected: `Generated project successfully` (or equivalent — no errors).

- [ ] **Step 3: Build**

```bash
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Format and commit**

```bash
npx prettier --write Orbit/Models/TranslatePair.swift Orbit.xcodeproj 2>&1 | tail -3 || true
git add Orbit/Models/TranslatePair.swift Orbit.xcodeproj
git commit -m "feat: add TranslatePair model"
```

---

## Task 2: Add `.translate` case to `OrbitItem`

**Files:**

- Modify: `Orbit/Models/OrbitItem.swift`

- [ ] **Step 1: Replace the entire enum body**

Replace the contents of `Orbit/Models/OrbitItem.swift` with:

```swift
import Foundation

/// A single item rendered around the Orbit ring. Ring positions, angle math,
/// scroll-to-rotate and arrow navigation all operate on `[OrbitItem]` so that
/// apps, dictation languages and the translate tile can coexist in a single ring.
enum OrbitItem: Identifiable, Equatable {
    case app(RunningApp)
    case language(DictationLanguage)
    case translate(TranslatePair)

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

- [ ] **Step 2: Build**

```bash
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -30
```

Expected: a few `switch must be exhaustive` errors in `OrbitView.swift` and `OrbitViewModel.swift` referring to the new `.translate` case. **This is expected** — we will fix them in Tasks 6 and 8. Note the file paths for those tasks.

- [ ] **Step 3: Commit**

```bash
npx prettier --write Orbit/Models/OrbitItem.swift 2>&1 | tail -3 || true
git add Orbit/Models/OrbitItem.swift
git commit -m "feat: add OrbitItem.translate case"
```

(The tree will not build cleanly until Task 6 — that's intentional, each task is small.)

---

## Task 3: Add translate fields & `translatePair` to `SettingsService`

**Files:**

- Modify: `Orbit/Services/SettingsService.swift`

- [ ] **Step 1: Add the four new `@Published` properties**

In `Orbit/Services/SettingsService.swift`, find the existing `@Published` block (lines 19–33) and add four new properties immediately after `@Published var languageAngles: [String: Double]`:

```swift
    @Published var translateTileEnabled: Bool
    @Published var translateSourceLocaleId: String
    @Published var translateAngle: Double?
    @Published var dictationInputDeviceUID: String?
```

- [ ] **Step 2: Initialize the new properties in `init`**

In the `private init()` block, after the existing `languageAngles = ...` line, add:

```swift
        translateTileEnabled = defaults.object(forKey: "translateTileEnabled") != nil
            ? defaults.bool(forKey: "translateTileEnabled")
            : false
        translateSourceLocaleId = defaults.string(forKey: "translateSourceLocaleId") ?? "sv_SE"
        translateAngle = defaults.object(forKey: "translateAngle") as? Double
        dictationInputDeviceUID = defaults.string(forKey: "dictationInputDeviceUID")
```

- [ ] **Step 3: Persist the new properties in `save()`**

In the `save()` method, after the existing `defaults.set(languageAngles, ...)` line, add:

```swift
        defaults.set(translateTileEnabled, forKey: "translateTileEnabled")
        defaults.set(translateSourceLocaleId, forKey: "translateSourceLocaleId")
        if let angle = translateAngle {
            defaults.set(angle, forKey: "translateAngle")
        } else {
            defaults.removeObject(forKey: "translateAngle")
        }
        if let uid = dictationInputDeviceUID {
            defaults.set(uid, forKey: "dictationInputDeviceUID")
        } else {
            defaults.removeObject(forKey: "dictationInputDeviceUID")
        }
```

- [ ] **Step 4: Include `translateAngle` in `allAnchorAngles`**

Replace the existing `allAnchorAngles` computed property:

```swift
    /// All currently known anchored angles in one flat list (pinned + languages + translate).
    /// Used by the default-placement algorithm when adding a new anchor.
    var allAnchorAngles: [Double] {
        var all = Array(pinnedAngles.values) + Array(languageAngles.values)
        if let angle = translateAngle {
            all.append(angle)
        }
        return all
    }
```

- [ ] **Step 5: Extend `ensureAnchorAngles` to manage `translateAngle`**

At the end of the existing for-loop block in `ensureAnchorAngles(for:)`, immediately before the pruning section that starts with `let pinnedSet = ...`, add:

```swift
        // Translate tile gets an angle the first time it becomes enabled,
        // using the same next-empty-arc algorithm as language tiles.
        if translatePair != nil, translateAngle == nil {
            translateAngle = RingLayout.nextAnchorAngle(existingAngles: allAnchorAngles)
            changed = true
        }
```

**Note:** We do NOT clear `translateAngle` when `translatePair == nil` — preserving the angle is the correct behavior so that disabling and re-enabling the toggle restores the same slot. The pruning logic for `pinnedAngles` and `languageAngles` exists because users add and remove items from those sets over time; the translate tile is conceptually one slot that the user might toggle on and off.

- [ ] **Step 6: Add the `translatePair` computed property**

After the existing `dictationLanguages` computed property (around line 178), add:

```swift
    /// The currently configured translate pair, or nil when the toggle is
    /// off, no source has been chosen, or the chosen source is no longer
    /// enabled in System Settings → Keyboard → Dictation. Target is the
    /// user's preferred enabled `en_*` variant, falling back to a hardcoded
    /// `en_US` so the tile still has a flag to render even if no English
    /// locale is enabled (Whisper does not consult system prefs).
    var translatePair: TranslatePair? {
        guard translateTileEnabled else { return nil }
        let enabled = DictationService.enabledLocales()
        guard let source = enabled.first(where: { $0.id == translateSourceLocaleId }) else {
            return nil
        }
        let target = enabled.first(where: { $0.id.hasPrefix("en") })
            ?? DictationLanguage.from(localeId: "en_US")
        return TranslatePair(source: source, target: target)
    }
```

- [ ] **Step 7: Build**

```bash
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -30
```

Expected: still the same exhaustive-switch errors from Task 2. No new errors.

- [ ] **Step 8: Commit**

```bash
npx prettier --write Orbit/Services/SettingsService.swift 2>&1 | tail -3 || true
git add Orbit/Services/SettingsService.swift
git commit -m "feat: add translate tile settings to SettingsService"
```

---

## Task 4: Refactor `SpeechRecognitionService` — split start into dictation/translation

**Files:**

- Modify: `Orbit/Services/SpeechRecognitionService.swift`

This is the biggest refactor in the plan. Read it carefully — every change is small but they interact.

- [ ] **Step 1: Add the import for `WhisperKit`'s `DecodingTask`**

`DecodingTask` is already exported by the existing `import WhisperKit` at the top of the file. No new import needed. Verify by searching the file:

```bash
grep -n "import WhisperKit" Orbit/Services/SpeechRecognitionService.swift
```

Expected output: `6:import WhisperKit`.

- [ ] **Step 2: Add the two new private state fields**

Find the existing `private var currentLocaleId: String = "en_US"` line (around line 108). Replace it with:

```swift
    private var currentLocaleId: String = "en_US"
    private var currentTask: DecodingTask = .transcribe
    private var currentTranslationTargetId: String?
```

- [ ] **Step 3: Replace the public `start(localeId:onError:)` method with two new public methods + a private `startInternal`**

Find the existing `func start(localeId: String, onError: @escaping (String) -> Void = { _ in })` (around line 130). The entire method body, from the `func start(...)` line down to its closing `}` (around line 194), is replaced with the following three methods:

```swift
    /// Start a regular (non-translating) dictation session in `localeId`.
    /// Whisper transcribes audio in the same language and pastes the
    /// transcript into the frontmost app.
    func startDictation(localeId: String, onError: @escaping (String) -> Void = { _ in }) {
        startInternal(
            localeId: localeId,
            task: .transcribe,
            targetLocaleIdForDisplay: nil,
            onError: onError
        )
    }

    /// Start a translation session: Whisper takes audio in `sourceLocaleId`
    /// and pastes English text into the frontmost app. The `targetLocaleId`
    /// is purely cosmetic — it controls which `en_*` flag the recording
    /// indicator displays. Whisper itself ignores it (its `.translate` task
    /// always outputs English).
    func startTranslation(
        sourceLocaleId: String,
        targetLocaleId: String,
        onError: @escaping (String) -> Void = { _ in }
    ) {
        startInternal(
            localeId: sourceLocaleId,
            task: .translate,
            targetLocaleIdForDisplay: targetLocaleId,
            onError: onError
        )
    }

    private func startInternal(
        localeId: String,
        task: DecodingTask,
        targetLocaleIdForDisplay: String?,
        onError: @escaping (String) -> Void
    ) {
        let now = CACurrentMediaTime()
        if starting || (now - lastStartTime) < startLockout {
            NSLog("[Orbit.speech] start() suppressed (starting=\(starting), since-last=\(Int((now - lastStartTime) * 1000))ms)")
            return
        }
        starting = true
        lastStartTime = now

        if isRunning {
            stop()
        }

        currentLocaleId = localeId
        currentTask = task
        currentTranslationTargetId = targetLocaleIdForDisplay

        // Hard pre-flight: if the model isn't downloaded yet, refuse to
        // start and tell the user where to set it up. We never trigger
        // automatic downloads from a tile click — downloads happen only
        // from Settings → Dictation so the user is aware of the network
        // activity and disk usage.
        let modelName = SettingsService.shared.dictationModelName
        guard isModelDownloaded(modelName) else {
            NSLog("[Orbit.speech] start aborted — model \(modelName) not downloaded")
            starting = false
            currentTask = .transcribe
            currentTranslationTargetId = nil
            onError("Speech model not downloaded. Set it up in Settings → Dictation.")
            showSetupReminderNotification()
            return
        }

        // Replace any existing indicator so we anchor near the user's
        // current cursor and use the right locale.
        if indicatorPanel != nil {
            indicatorPanel?.hideIndicator()
            indicatorPanel = nil
        }

        // Show the indicator immediately so the user gets feedback. The
        // model is downloaded but might still be loading into RAM.
        let initialState: RecordingIndicatorPanel.State =
            (whisperKit == nil) ? .loading(message: "Loading model\u{2026}") : .listening
        showIndicator(localeId: localeId, state: initialState)

        ensurePermissions { [weak self] granted in
            guard let self else { return }
            guard granted else {
                NSLog("[Orbit.speech] permission denied")
                self.starting = false
                DispatchQueue.main.async {
                    self.indicatorPanel?.hideIndicator()
                    self.indicatorPanel = nil
                    onError("Microphone permission denied")
                    self.showMicPermissionAlert()
                }
                return
            }
            Task { @MainActor in
                await self.ensureWhisperKitLoaded(onError: onError)
                if self.whisperKit != nil {
                    self.indicatorPanel?.updateState(.listening)
                    self.beginCapture(localeId: localeId, onError: onError)
                }
                self.starting = false
            }
        }
    }
```

- [ ] **Step 4: Update `stop` to reset `currentTask` and `currentTranslationTargetId`**

Find the `stop(reason:flushBuffer:)` method. Inside it, find the line `injectedSoFar = ""` near the end of the `else` branch (around line 326). Add the resets to **both** branches that finish the stop sequence — this is easiest by adding them right after `isRunning = false` (around line 278) so they fire on every `stop()`:

Locate this block:

```swift
        hasSpeechInBuffer = false
        silentSamplesAfterSpeech = 0
        isRunning = false
```

Replace it with:

```swift
        hasSpeechInBuffer = false
        silentSamplesAfterSpeech = 0
        isRunning = false
        currentTask = .transcribe
        currentTranslationTargetId = nil
```

- [ ] **Step 5: Use `currentTask` in `flushAndTranscribe`'s `DecodingOptions`**

Find `flushAndTranscribe()` (around line 564). Inside the `Task { ... }` block, find the `DecodingOptions(...)` initializer (around line 588). Replace `task: .transcribe` with `task: currentTask`:

```swift
                let options = DecodingOptions(
                    verbose: false,
                    task: currentTask,
                    language: language,
                    temperature: 0,
                    temperatureFallbackCount: 5,
                    skipSpecialTokens: true,
                    withoutTimestamps: true,
                    noSpeechThreshold: 0.5
                )
```

- [ ] **Step 6: Use `currentTask` in `stop`'s final-flush `DecodingOptions`**

Find the final-flush block in `stop()` — the one that starts with `if flushBuffer, hadSpeech, ...` (around line 287). Inside its `Task { ... }`, find the `DecodingOptions(...)` (around line 297). Replace `task: .transcribe` with `task: currentTask`. **Capture `currentTask` into a local before the Task block** so the value at stop time is what gets used (otherwise the reset in Step 4 would race the async task):

Replace the final-flush block (from `if flushBuffer, hadSpeech, finalSnapshot.count > minSamples, let kit = whisperKit, !transcribing {` down to its matching `} else { injectedSoFar = "" }`) with:

```swift
        if flushBuffer, hadSpeech, finalSnapshot.count > minSamples, let kit = whisperKit, !transcribing {
            let bcp47 = currentLocaleId
                .replacingOccurrences(of: "_", with: "-")
                .lowercased()
            let language = String(bcp47.split(separator: "-").first ?? "en")
            let capturedTask = currentTask  // Snapshot before reset below races the async task.
            NSLog("[Orbit.speech] stop: final flush \(String(format: "%.2f", Double(finalSnapshot.count) / targetSampleRate))s audio (\(language), task=\(capturedTask))")
            transcribing = true
            Task { [weak self] in
                guard let self else { return }
                do {
                    let options = DecodingOptions(
                        verbose: false,
                        task: capturedTask,
                        language: language,
                        temperature: 0,
                        temperatureFallbackCount: 5,
                        skipSpecialTokens: true,
                        withoutTimestamps: true,
                        noSpeechThreshold: 0.5
                    )
                    let results = try await kit.transcribe(audioArray: finalSnapshot, decodeOptions: options)
                    let text = results
                        .map(\.text)
                        .joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run {
                        self.handleFlushedTranscript(text)
                        self.injectedSoFar = ""
                        self.transcribing = false
                    }
                } catch {
                    NSLog("[Orbit.speech] final flush transcribe error: \(error.localizedDescription)")
                    await MainActor.run {
                        self.injectedSoFar = ""
                        self.transcribing = false
                    }
                }
            }
        } else {
            injectedSoFar = ""
        }
```

**Important:** Step 4 added the reset `currentTask = .transcribe` and `currentTranslationTargetId = nil` to fire on every `stop()`. The `capturedTask` local variable in this step is essential — it captures the task value **before** the reset wipes it, so the async transcription task uses the right mode even though `currentTask` has been reset by the time the `Task` block runs.

- [ ] **Step 7: Build**

```bash
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -30
```

Expected errors: still the exhaustive-switch errors in `OrbitView`/`OrbitViewModel` from Task 2, **plus** a new error in `DictationService.swift` because it still calls `.start(localeId:)` which no longer exists. We will fix `DictationService` in Task 5.

- [ ] **Step 8: Commit**

```bash
npx prettier --write Orbit/Services/SpeechRecognitionService.swift 2>&1 | tail -3 || true
git add Orbit/Services/SpeechRecognitionService.swift
git commit -m "refactor: split SpeechRecognitionService.start into startDictation/startTranslation"
```

---

## Task 5: Update `DictationService`

**Files:**

- Modify: `Orbit/Services/DictationService.swift`

- [ ] **Step 1: Update the inner call in `switchLanguageAndStart`**

Find `switchLanguageAndStart` (around line 83). Replace its body with:

```swift
    static func switchLanguageAndStart(_ localeId: String) {
        setLanguage(localeId)
        SpeechRecognitionService.shared.startDictation(localeId: localeId) { errorMessage in
            NSLog("[Orbit.dictation] speech start failed: \(errorMessage)")
        }
    }
```

(Only one line changed: `.start(localeId:` → `.startDictation(localeId:`. Everything else is identical.)

- [ ] **Step 2: Add `startTranslation(pair:)` static method**

Immediately after `switchLanguageAndStart`, add:

```swift
    /// Starts a translate-dictation session: Whisper takes audio in
    /// `pair.source.id` and pastes English text into the frontmost app.
    ///
    /// Deliberately does NOT call `setLanguage()` — system Dictation cannot
    /// translate, so writing the source locale to AppleSpeechRecognition.prefs
    /// would misconfigure the user's physical (macOS) dictation shortcut.
    /// Translation runs entirely inside Orbit via WhisperKit.
    static func startTranslation(pair: TranslatePair) {
        SpeechRecognitionService.shared.startTranslation(
            sourceLocaleId: pair.source.id,
            targetLocaleId: pair.target.id
        ) { errorMessage in
            NSLog("[Orbit.dictation] translation start failed: \(errorMessage)")
        }
    }
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -30
```

Expected: only the original exhaustive-switch errors from Task 2 remain. `DictationService` and `SpeechRecognitionService` are now consistent.

- [ ] **Step 4: Commit**

```bash
npx prettier --write Orbit/Services/DictationService.swift 2>&1 | tail -3 || true
git add Orbit/Services/DictationService.swift
git commit -m "feat: add DictationService.startTranslation"
```

---

## Task 6: Wire `.translate` into `OrbitViewModel`

**Files:**

- Modify: `Orbit/ViewModels/OrbitViewModel.swift`

- [ ] **Step 1: Append translate tile in `show()`**

Find the `show()` method. Locate the existing language-anchor loop (around lines 72–76):

```swift
        for language in languages {
            if let angle = settings.languageAngles[language.id] {
                anchored.append((.language(language), angle))
            }
        }
```

Immediately after this loop (and before the `for app in anchoredApps` loop), add:

```swift
        if let pair = settings.translatePair, let angle = settings.translateAngle {
            anchored.append((.translate(pair), angle))
        }
```

- [ ] **Step 2: Add `.translate` case to `selectAndSwitch()`**

Find `selectAndSwitch()` (around line 106). Locate the `switch item` block:

```swift
            switch item {
            case .app(let app):
                app.app.activate()
            case .language(let language):
                DictationService.switchLanguageAndStart(language.id)
            }
```

Replace with:

```swift
            switch item {
            case .app(let app):
                app.app.activate()
            case .language(let language):
                DictationService.switchLanguageAndStart(language.id)
            case .translate(let pair):
                DictationService.startTranslation(pair: pair)
            }
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -30
```

Expected: one remaining exhaustive-switch error in `OrbitView.swift`. We fix it in Task 8.

- [ ] **Step 4: Commit**

```bash
npx prettier --write Orbit/ViewModels/OrbitViewModel.swift 2>&1 | tail -3 || true
git add Orbit/ViewModels/OrbitViewModel.swift
git commit -m "feat: render translate tile in OrbitViewModel"
```

---

## Task 7: Create `TranslateTileView`

**Files:**

- Create: `Orbit/Views/TranslateTileView.swift`

- [ ] **Step 1: Create the file**

```swift
// Orbit/Views/TranslateTileView.swift
import SwiftUI

/// Ring tile representing a translate-dictation pair. Visually mirrors
/// `LanguageTileView` (same RoundedRectangle, ultraThinMaterial, selection
/// glow, stroke, scale) but renders TWO flags side-by-side with an arrow
/// between them so the source → target direction is unmistakable.
struct TranslateTileView: View {
    let pair: TranslatePair
    let isSelected: Bool
    let size: CGFloat
    var isAnchored: Bool = true

    /// Anchored translate tiles get the same 1.2x size boost as anchored
    /// language tiles for visual consistency in the ring.
    private var effectiveSize: CGFloat {
        isAnchored ? size * 1.2 : size
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.ultraThinMaterial)
            .overlay(
                HStack(spacing: effectiveSize * 0.06) {
                    Text(pair.source.flagEmoji)
                        .font(.system(size: effectiveSize * 0.42))
                    Image(systemName: "arrow.right")
                        .font(.system(size: effectiveSize * 0.22, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(pair.target.flagEmoji)
                        .font(.system(size: effectiveSize * 0.42))
                }
            )
            .frame(width: effectiveSize, height: effectiveSize)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(
                color: isSelected ? Color.accentColor.opacity(0.8) : .clear,
                radius: isSelected ? 12 : 0
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
            )
            .scaleEffect(isSelected ? 1.25 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: isSelected)
    }
}
```

- [ ] **Step 2: Regenerate Xcode project**

```bash
xcodegen generate
```

Expected: success.

- [ ] **Step 3: Build**

```bash
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: still one exhaustive-switch error in `OrbitView`. The new view itself compiles.

- [ ] **Step 4: Commit**

```bash
npx prettier --write Orbit/Views/TranslateTileView.swift Orbit.xcodeproj 2>&1 | tail -3 || true
git add Orbit/Views/TranslateTileView.swift Orbit.xcodeproj
git commit -m "feat: add TranslateTileView"
```

---

## Task 8: Render `TranslateTileView` in `OrbitView`

**Files:**

- Modify: `Orbit/Views/OrbitView.swift`

- [ ] **Step 1: Add the `.translate` case to the tile rendering switch**

Find the `switch positioned.item` block (around lines 48–63). Replace it with:

```swift
                        switch positioned.item {
                        case .app(let app):
                            AppIconView(
                                app: app,
                                isSelected: isSelected,
                                size: viewModel.iconSize,
                                isAnchored: positioned.isAnchored
                            )
                        case .language(let language):
                            LanguageTileView(
                                language: language,
                                isSelected: isSelected,
                                size: viewModel.iconSize,
                                isAnchored: positioned.isAnchored
                            )
                        case .translate(let pair):
                            TranslateTileView(
                                pair: pair,
                                isSelected: isSelected,
                                size: viewModel.iconSize,
                                isAnchored: positioned.isAnchored
                            )
                        }
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`. The tree is now exhaustively switched and compiles end-to-end. The translate tile is wired but invisible in the UI because the toggle defaults to `false`.

- [ ] **Step 3: Commit**

```bash
npx prettier --write Orbit/Views/OrbitView.swift 2>&1 | tail -3 || true
git add Orbit/Views/OrbitView.swift
git commit -m "feat: render TranslateTileView in OrbitView"
```

---

## Task 9: Two-flag recording indicator

**Files:**

- Modify: `Orbit/Views/RecordingIndicatorPanel.swift`

- [ ] **Step 1: Extend `show()` and `RecordingIndicatorModel` with optional target locale**

Find the `show()` method (around line 39). Replace it with:

```swift
    func show(
        localeId: String,
        state: State,
        targetLocaleId: String? = nil,
        onStopTapped: @escaping () -> Void
    ) {
        let model = RecordingIndicatorModel(
            localeId: localeId,
            targetLocaleId: targetLocaleId,
            state: state
        )
        self.model = model
        let view = RecordingIndicatorView(model: model, onStop: onStopTapped)
        let host = NSHostingView(rootView: view)
        contentView = host
        hostingView = host

        let mouse = NSEvent.mouseLocation
        let size = NSSize(width: 220, height: 64)
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 16)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
            origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - size.height - 8))
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
        orderFrontRegardless()
    }
```

- [ ] **Step 2: Add `targetLocaleId` to `RecordingIndicatorModel`**

Find `RecordingIndicatorModel` (around line 75). Replace it with:

```swift
final class RecordingIndicatorModel: ObservableObject {
    let localeId: String
    let targetLocaleId: String?
    @Published var state: RecordingIndicatorPanel.State

    init(localeId: String, targetLocaleId: String?, state: RecordingIndicatorPanel.State) {
        self.localeId = localeId
        self.targetLocaleId = targetLocaleId
        self.state = state
    }
}
```

- [ ] **Step 3: Render the target flag in `RecordingIndicatorView`**

Find the `RecordingIndicatorView` private struct (around line 85). Add a helper for the target flag, mirroring the existing `flagEmoji` computed property. Insert this immediately below the existing `flagEmoji` computed property:

```swift
    private var targetFlagEmoji: String? {
        guard let targetLocaleId = model.targetLocaleId,
              let region = targetLocaleId.split(separator: "_").last,
              region.count == 2
        else { return nil }
        let base: UInt32 = 127397
        var scalar = ""
        for ch in region.uppercased().unicodeScalars {
            if let combined = UnicodeScalar(base + ch.value) {
                scalar.unicodeScalars.append(combined)
            }
        }
        return scalar.isEmpty ? nil : scalar
    }
```

- [ ] **Step 4: Render both flags in the view body when target is present**

Find the `HStack(spacing: 4)` inside the `VStack(alignment: .leading, spacing: 2)` (around line 151). It currently contains `Text(flagEmoji)`, `Text(localeBadge)`, `Text(statusText)`. Replace that `HStack` with:

```swift
                HStack(spacing: 4) {
                    Text(flagEmoji)
                        .font(.system(size: 16))
                    if let targetFlag = targetFlagEmoji {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(targetFlag)
                            .font(.system(size: 16))
                    } else {
                        Text(localeBadge)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
```

This preserves the existing `flag + locale-badge + status` layout for regular dictation, and switches to `flag → flag + status` (no locale badge) for translation. The locale badge would just clutter the two-flag layout — the flags themselves carry the meaning.

- [ ] **Step 5: Pass `targetLocaleId` from `SpeechRecognitionService.showIndicator`**

Switch back to `Orbit/Services/SpeechRecognitionService.swift`. Find `showIndicator` (the very last method in the file, around line 772). Replace it with:

```swift
    private func showIndicator(localeId: String, state: RecordingIndicatorPanel.State) {
        let panel = RecordingIndicatorPanel()
        panel.show(
            localeId: localeId,
            state: state,
            targetLocaleId: currentTranslationTargetId
        ) { [weak self] in
            DispatchQueue.main.async { self?.stop(reason: "indicator click") }
        }
        indicatorPanel = panel
    }
```

- [ ] **Step 6: Build**

```bash
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
npx prettier --write Orbit/Views/RecordingIndicatorPanel.swift Orbit/Services/SpeechRecognitionService.swift 2>&1 | tail -3 || true
git add Orbit/Views/RecordingIndicatorPanel.swift Orbit/Services/SpeechRecognitionService.swift
git commit -m "feat: render target flag in recording indicator during translation"
```

---

## Task 10: Create `AudioInputDeviceService`

**Files:**

- Create: `Orbit/Services/AudioInputDeviceService.swift`

This task introduces a small CoreAudio wrapper that enumerates input devices and resolves a stored UID back to a runtime AudioDeviceID. Pure CoreAudio — no permissions needed because enumeration does not count as microphone access.

- [ ] **Step 1: Create the file**

```swift
// Orbit/Services/AudioInputDeviceService.swift
import CoreAudio
import Foundation

/// Stateless CoreAudio wrapper for input device enumeration.
///
/// Used by `SettingsView` to populate the microphone picker and by
/// `SpeechRecognitionService.beginCapture` to resolve the user's stored
/// device UID back to an `AudioDeviceID` that can be assigned to the
/// engine's input audio unit before starting capture.
///
/// Why CoreAudio rather than `AVCaptureDevice`: setting a specific input
/// device on `AVAudioEngine.inputNode` requires `AudioDeviceID` (CoreAudio's
/// runtime handle), and the cleanest way to get one for a given persistent
/// UID is to walk `kAudioHardwarePropertyDevices` ourselves. Going through
/// `AVCaptureDevice` adds an indirection without saving any code.
enum AudioInputDeviceService {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    /// Enumerate every CoreAudio device that has at least one input stream.
    /// Output-only devices (speakers, HDMI displays) are filtered out.
    /// Sorted alphabetically by name. Synchronous, takes <1ms.
    static func listInputDevices() -> [Device] {
        let deviceIDs = allAudioDeviceIDs()
        var result: [Device] = []
        for deviceID in deviceIDs {
            guard hasInputStreams(deviceID) else { continue }
            guard let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID) else { continue }
            let name = stringProperty(deviceID, kAudioDevicePropertyDeviceNameCFString) ?? uid
            result.append(Device(id: deviceID, uid: uid, name: name))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Resolve a persistent UID back to its current AudioDeviceID.
    /// Returns nil if no connected device has that UID (e.g. unplugged).
    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        return listInputDevices().first(where: { $0.uid == uid })?.id
    }

    // MARK: - CoreAudio plumbing

    private static func allAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }
        return deviceIDs
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        return status == noErr && dataSize > 0
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = UInt32(MemoryLayout<CFString?>.size)
        var cfString: CFString? = nil
        let status = withUnsafeMutablePointer(to: &cfString) { ptr -> OSStatus in
            return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr, let cf = cfString else { return nil }
        return cf as String
    }
}
```

- [ ] **Step 2: Regenerate Xcode project**

```bash
xcodegen generate
```

Expected: success.

- [ ] **Step 3: Build**

```bash
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`. (No call sites yet.)

- [ ] **Step 4: Commit**

```bash
npx prettier --write Orbit/Services/AudioInputDeviceService.swift Orbit.xcodeproj 2>&1 | tail -3 || true
git add Orbit/Services/AudioInputDeviceService.swift Orbit.xcodeproj
git commit -m "feat: add AudioInputDeviceService for CoreAudio input enumeration"
```

---

## Task 11: Wire input device into `SpeechRecognitionService.beginCapture`

**Files:**

- Modify: `Orbit/Services/SpeechRecognitionService.swift`

- [ ] **Step 1: Add the import for `CoreAudio`**

At the top of `Orbit/Services/SpeechRecognitionService.swift`, after `import CoreGraphics`, add:

```swift
import CoreAudio
```

- [ ] **Step 2: Insert the device-selection block at the top of `beginCapture`**

Find `beginCapture(localeId:onError:)` (around line 447). Locate the very first line of its body, which is currently:

```swift
        let inputNode = audioEngine.inputNode
```

Replace it with:

```swift
        // Configure input device BEFORE reading inputNode.outputFormat — the
        // format depends on whichever device the input unit is bound to, and
        // the tap install below uses that format. The user's stored UID is
        // resolved to a current AudioDeviceID; if the device is no longer
        // connected (UID not found), we fall through silently and the engine
        // uses the system default. We do not show an alert because unplugging
        // a mic is a normal, expected user action.
        if let uid = SettingsService.shared.dictationInputDeviceUID {
            if let deviceID = AudioInputDeviceService.audioDeviceID(forUID: uid) {
                var mutableID = deviceID
                if let audioUnit = audioEngine.inputNode.audioUnit {
                    let status = AudioUnitSetProperty(
                        audioUnit,
                        kAudioOutputUnitProperty_CurrentDevice,
                        kAudioUnitScope_Global,
                        0,
                        &mutableID,
                        UInt32(MemoryLayout<AudioDeviceID>.size)
                    )
                    if status == noErr {
                        NSLog("[Orbit.speech] input device set to \(uid)")
                    } else {
                        NSLog("[Orbit.speech] failed to set input device \(uid): OSStatus=\(status) — falling back to system default")
                    }
                } else {
                    NSLog("[Orbit.speech] inputNode.audioUnit is nil — cannot set device, using system default")
                }
            } else {
                NSLog("[Orbit.speech] stored input device \(uid) is not connected — falling back to system default")
            }
        }

        let inputNode = audioEngine.inputNode
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`. The behavior change is invisible at runtime until the user actually picks a device in Settings (Task 12).

- [ ] **Step 4: Commit**

```bash
npx prettier --write Orbit/Services/SpeechRecognitionService.swift 2>&1 | tail -3 || true
git add Orbit/Services/SpeechRecognitionService.swift
git commit -m "feat: honor SettingsService.dictationInputDeviceUID in beginCapture"
```

---

## Task 12: Settings UI for translate tile and microphone picker

**Files:**

- Modify: `Orbit/Views/SettingsView.swift`

This task adds two new sections to the Dictation tab in a single commit (they share the same file). The Microphone section is added first because it appears above the Translation section in the UI.

- [ ] **Step 1: Add the Translation subsection inside `dictationTab`**

Find the `dictationTab` computed property. Locate the closing brace of the `Section("Status") { ... }` block — the one at the end of the `if settings.dictationEnabled { ... }` block (around line 369). Immediately **after** that closing `}`, but **inside** the `if settings.dictationEnabled {` block's outer braces — wait, the translate tile should NOT require `dictationEnabled` to be on. Reconsider the placement.

Actually, place the new sections **outside** the `if settings.dictationEnabled` block, so the user can enable translation independently of the regular language tiles. Find the `if settings.dictationEnabled { ... }` block and locate its closing brace (around line 370, immediately before `}` of the outer `Form`). After that closing brace, add:

```swift
            Section("Translation") {
                Toggle("Show translate-to-English tile in Orbit ring", isOn: $settings.translateTileEnabled)
                    .onChange(of: settings.translateTileEnabled) {
                        settings.save()
                        if settings.translateTileEnabled {
                            // Assign an angle now so the tile appears at a
                            // sensible spot the next time the ring opens,
                            // not at 0° / overlapping an existing item.
                            settings.ensureAnchorAngles(for: settings.dictationLanguages)
                        }
                    }

                if translateSourceCandidates.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Enable a non-English dictation language in System Settings → Keyboard → Dictation first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Open Dictation Settings\u{2026}") {
                            openDictationSystemSettings()
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    Picker("Source language", selection: $settings.translateSourceLocaleId) {
                        ForEach(translateSourceCandidates) { language in
                            Text("\(language.flagEmoji)  \(language.displayName)")
                                .tag(language.id)
                        }
                    }
                    .disabled(!settings.translateTileEnabled)
                    .onChange(of: settings.translateSourceLocaleId) { settings.save() }
                }

                Text("Speak in the selected language. Orbit transcribes and translates to English in real time using Whisper. The macOS system Dictation language is not affected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

- [ ] **Step 2: Add the `translateSourceCandidates` helper**

Inside `SettingsView`, add a new computed property near the other helpers (e.g. immediately above `private func refreshDictationLocales()` around line 469):

```swift
    /// Non-English locales the user has enabled in System Settings, used to
    /// populate the translate-source picker. The translate tile cannot have
    /// English as its source — Whisper would just produce identical English
    /// output, which is degenerate.
    private var translateSourceCandidates: [DictationLanguage] {
        enabledDictationLocales.filter { !$0.id.hasPrefix("en") }
    }
```

- [ ] **Step 3: Add the Microphone subsection above the Translation subsection**

Find the `Section("Translation") { ... }` block you just added in Step 1. **Above** it, add:

```swift
            Section("Microphone") {
                Picker("Input device", selection: $settings.dictationInputDeviceUID) {
                    Text("System Default").tag(String?.none)
                    ForEach(availableInputDevices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                    // If the stored UID is not in the enumerated list, show
                    // a "Not connected" placeholder so the user understands
                    // why the picker would otherwise look like it had reset.
                    if let storedUID = settings.dictationInputDeviceUID,
                       !availableInputDevices.contains(where: { $0.uid == storedUID })
                    {
                        Text("\u{26A0}\u{FE0E} Not connected (\(storedUID))")
                            .tag(Optional(storedUID))
                    }
                }
                .onChange(of: settings.dictationInputDeviceUID) { settings.save() }

                Button("Refresh list") { refreshInputDevices() }
                    .buttonStyle(.borderless)

                Text("Orbit uses this microphone for all dictation and translation. \"System Default\" follows your macOS audio input setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

```

(Note the trailing blank line — keeps Forms visually separated from the Translation section that follows.)

- [ ] **Step 4: Add `availableInputDevices` `@State` and the `refreshInputDevices()` helper**

Near the existing `@State private var enabledDictationLocales: [DictationLanguage] = []` (around line 51), add a parallel state property:

```swift
    @State private var availableInputDevices: [AudioInputDeviceService.Device] = []
```

Then in `.onAppear` of the outer `TabView` (around line 67), where `refreshDictationLocales()` is currently called, add a parallel call:

```swift
        .onAppear {
            refreshApps()
            refreshDictationLocales()
            refreshInputDevices()
        }
```

And add the helper next to `refreshDictationLocales()` (around line 469):

```swift
    private func refreshInputDevices() {
        availableInputDevices = AudioInputDeviceService.listInputDevices()
    }
```

- [ ] **Step 5: Build**

```bash
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
npx prettier --write Orbit/Views/SettingsView.swift 2>&1 | tail -3 || true
git add Orbit/Views/SettingsView.swift
git commit -m "feat: add Translation and Microphone sections to Dictation settings"
```

---

## Task 13: Update `SPEC.md`

**Files:**

- Modify: `SPEC.md`

The `CLAUDE.md` rule says: "After making changes to the codebase, update `SPEC.md` to reflect the current state of the app."

- [ ] **Step 1: Read the current SPEC.md**

```bash
wc -l SPEC.md
```

Then read it to understand the existing section structure:

Use the Read tool on `SPEC.md` and identify the sections that match the spec doc's "SPEC.md updates" list:

- Models section → add `OrbitItem.translate` and `TranslatePair`
- Services section → add `startDictation`/`startTranslation` split, `currentTask`, `DictationService.startTranslation`, `AudioInputDeviceService`, and the device-selection step in `beginCapture`
- Views section → add `TranslateTileView`
- Settings section → add `translateTileEnabled`, `translateSourceLocaleId`, `translateAngle`, `dictationInputDeviceUID`
- SettingsView → Dictation Tab section → describe the new "Microphone" and "Translation" subsections
- Ring layout section → note that translate tiles use the same anchor mechanism

- [ ] **Step 2: Update each section**

For each of the sections above, add a paragraph describing the new behavior. Match the existing prose style and depth (do not write more detail than other sections of similar weight). The spec doc at `docs/superpowers/specs/2026-04-08-translate-dictation-design.md` is the source of truth — paraphrase from it, do not copy verbatim. Key points to include:

**Translate tile:**

- `OrbitItem.translate(TranslatePair)` is a third ring item type alongside apps and language tiles
- `TranslatePair` carries source + target `DictationLanguage`; target is purely cosmetic (Whisper always outputs English regardless)
- `SpeechRecognitionService` exposes `startDictation` and `startTranslation`; both delegate to a private `startInternal(localeId:task:targetLocaleIdForDisplay:)` that captures the WhisperKit `DecodingTask` in `currentTask`. `flushAndTranscribe` and the final-flush in `stop` use `currentTask` in their `DecodingOptions`
- `DictationService.startTranslation(pair:)` deliberately does NOT call `setLanguage` because system Dictation cannot translate
- `TranslateTileView` matches `LanguageTileView`'s visual treatment but renders source flag → target flag with an `arrow.right` SF Symbol between
- `RecordingIndicatorPanel.show` now takes optional `targetLocaleId`; when set, the indicator renders both flags in the status row instead of flag + locale badge
- Settings adds `translateTileEnabled` (default false, opt-in), `translateSourceLocaleId` (default `sv_SE`), `translateAngle: Double?`
- Settings UI adds a "Translation" section in the Dictation tab with a toggle, source picker (filtered to non-English enabled locales), and an empty-state warning when no non-English locale is enabled
- Anchor angle: `translateAngle` is assigned the first time the tile is enabled via the same `nextAnchorAngle` mechanism as language tiles, and is **preserved** across enable/disable cycles
- Translation is **independent** of the `dictationEnabled` toggle

**Microphone device picker:**

- New `AudioInputDeviceService` enum (file: `Orbit/Services/AudioInputDeviceService.swift`) wraps CoreAudio. `listInputDevices()` walks `kAudioHardwarePropertyDevices`, keeps only devices with at least one input stream (`kAudioDevicePropertyStreams` on `kAudioObjectPropertyScopeInput`), and reads `kAudioDevicePropertyDeviceUID` + `kAudioDevicePropertyDeviceNameCFString` for each. `audioDeviceID(forUID:)` resolves a stored UID back to a runtime AudioDeviceID, returning nil for disconnected devices. Synchronous, no permissions required (enumeration ≠ microphone access).
- New `dictationInputDeviceUID: String?` field in `SettingsService`. `nil` means "follow system default input". Stores the CoreAudio persistent UID (e.g. `"BuiltInMicrophoneDevice"`).
- `SpeechRecognitionService.beginCapture` reads `SettingsService.shared.dictationInputDeviceUID` at the very top, before reading `inputNode.outputFormat`. If non-nil and the device is connected, sets `kAudioOutputUnitProperty_CurrentDevice` on `audioEngine.inputNode.audioUnit`. If the device is disconnected, logs a fallback line and proceeds with the system default — no alert, because unplugging is a normal user action.
- Settings UI adds a "Microphone" section in the Dictation tab with a picker (first option = "System Default" tagged `nil`, then enumerated devices) and a "Refresh list" button. If the stored UID is no longer in the enumerated list, the picker shows an extra "⚠︎ Not connected (UID)" option so the user is not confused by an apparent reset.

- [ ] **Step 3: Format and commit**

```bash
npx prettier --write SPEC.md 2>&1 | tail -3 || true
git add SPEC.md
git commit -m "docs: document translate tile and microphone picker in SPEC.md"
```

---

## Task 14: End-to-end manual smoke test

**Files:** none modified — verification only.

Orbit has no test target, so this is the validation gate. Each step is a real user action plus a `pass / fail` checkbox.

- [ ] **Step 1: Build the release `.app`**

```bash
./build.sh 2>&1 | tail -10
```

Expected: `Copied to ./Orbit.app`.

- [ ] **Step 2: Quit any running Orbit, launch the new build**

```bash
pkill -x Orbit 2>/dev/null || true
open ./Orbit.app
```

Expected: Orbit menu bar icon appears.

- [ ] **Step 3: Verify the new Translation section in Settings**

Open Orbit Settings → Dictation tab. Expected:

- A new "Translation" section is visible at the bottom of the tab.
- Toggle "Show translate-to-English tile in Orbit ring" is **off** by default.
- Source language picker is disabled (greyed out) while toggle is off.
- Help text below mentions Whisper and "macOS system Dictation language is not affected".

- [ ] **Step 4: Enable the toggle and pick a source**

Toggle "Show translate-to-English tile in Orbit ring" on. Expected:

- Source language picker becomes enabled.
- Picker is populated with all non-English locales currently enabled in System Settings → Keyboard → Dictation.
- If `sv_SE` is enabled, it is selected by default.

Pick `sv_SE` (or whichever non-English locale you have enabled).

- [ ] **Step 5: Open the Orbit ring and verify the new tile appears**

Trigger Orbit (hotkey or mouse button). Expected:

- A new tile is in the ring showing **two flags side-by-side with an arrow between them**: 🇸🇪 → 🇺🇸 (or whichever en\_\* you have enabled, falling back to 🇺🇸).
- The tile is at a sensible angle, not overlapping any existing item.
- Hovering selects it; the center label reads "Swedish → English (United States)" (or similar).

- [ ] **Step 6: Click the tile, dictate in Swedish**

Click the translate tile. Expected:

- The recording indicator appears near the cursor showing **both flags** (🇸🇪 → 🇺🇸) with "Listening…" status.
- No locale badge ("SV") next to the flags.

Open a text field (e.g. Notes app, browser address bar). Say in Swedish:

> "Hej, hur mår du idag?"

Expected:

- An English translation (e.g. _"Hi, how are you today?"_) is pasted into the text field.
- Swedish text does NOT appear.

- [ ] **Step 7: ESC cancels mid-session**

Trigger the translate tile again, start saying something in Swedish, then press **ESC** before pausing. Expected:

- Recording indicator disappears.
- No text is pasted.

- [ ] **Step 8: Re-trigger Orbit mid-session flushes the buffer**

Trigger the translate tile, say a Swedish utterance, then re-trigger Orbit (hotkey or mouse button) before pausing. Expected:

- Final flush translates and pastes the utterance as English.
- Recording indicator disappears.

- [ ] **Step 9: Regular dictation tiles still work (regression check)**

Enable a regular dictation language tile in Settings → Dictation. Open the ring, click the regular language tile, dictate in that language. Expected:

- Regular dictation still produces same-language text (no translation).
- Recording indicator shows the single flag + locale badge (not the two-flag layout).

- [ ] **Step 10: Source removed from System Settings hides the tile**

Open System Settings → Keyboard → Dictation. Disable `sv_SE`. Return to Orbit, open the ring. Expected:

- The translate tile is **gone** from the ring (because `translatePair` returns nil).
- Orbit Settings → Dictation → Translation still shows the toggle as on, but the source picker now shows the empty-state warning ("Enable a non-English dictation language…").

Re-enable `sv_SE` in System Settings. Open Orbit Settings → Dictation, click "Refresh list" (the existing button in the Languages section). The picker repopulates. Open the ring again. Expected:

- The translate tile is back **at the same angle** as before.

- [ ] **Step 11: Toggle off preserves angle**

Toggle "Show translate-to-English tile in Orbit ring" off. Open the ring → tile is gone. Toggle back on. Open the ring → tile reappears at the same angle.

- [ ] **Step 12: Microphone picker — System Default works**

Open Settings → Dictation → Microphone subsection. Expected:

- Picker is populated with at least one device.
- "System Default" is selected by default (because `dictationInputDeviceUID == nil`).

Click "Refresh list". Expected: the picker repopulates without crashing or duplicating entries.

With System Default selected, dictate from a regular language tile (or the translate tile). Expected: dictation works exactly as before. **This is a regression check** — it confirms the new beginCapture branch does not break the default code path.

- [ ] **Step 13: Microphone picker — explicit device selection**

Plug in an external mic if you have one (USB, AirPods, audio interface). In Settings → Dictation → Microphone, click "Refresh list". Expected: the new device appears in the picker.

Select the external mic from the picker. Expected:

- The selection is persisted immediately (verify by quitting and relaunching Orbit — picker remembers the selection).
- The Orbit log shows `[Orbit.speech] input device set to <UID>` on the next dictation start (check via `log show --predicate 'process == "Orbit"' --last 1m | grep "input device"` or Console.app filtered to "Orbit").

Dictate using the selected device. Expected: Whisper picks up audio from the external mic, not the built-in. Verify by speaking close to the external mic and far from the built-in — the transcript should be clear and accurate.

- [ ] **Step 14: Microphone picker — disconnected device fallback**

Without changing the picker selection, unplug the external mic. Trigger dictation. Expected:

- The session still works (silent fallback to system default).
- The Orbit log contains `stored input device <UID> is not connected — falling back to system default`.
- **No alert** is shown to the user.

Re-open Settings → Dictation → Microphone. Expected:

- The picker now shows the disconnected device as `⚠︎ Not connected (UID)` with the stored UID, still selected.
- Selecting "System Default" clears the warning. The next dictation session uses the system default with no log line about a stored UID.

- [ ] **Step 15: Commit any fixes from the smoke test**

If the smoke test surfaces bugs, fix them with focused commits (one bug per commit). Re-run the affected smoke test steps after each fix. Do **not** mark this task complete until every step above passes.

```bash
git status
git log --oneline -20
```

Expected: a clean working tree, the feature commits visible in the log.

---

## Self-review checklist (run after smoke test passes)

- [ ] All 14 tasks committed individually
- [ ] `xcodebuild ... build` is green
- [ ] `./build.sh` produces a runnable `Orbit.app`
- [ ] No `task: .transcribe` literals remain in `SpeechRecognitionService.swift` — both call sites use `currentTask` / `capturedTask`
- [ ] `SpeechRecognitionService.start(localeId:)` is gone — only `startDictation` and `startTranslation` remain on the public surface
- [ ] `SPEC.md` reflects the new behavior (translate tile + mic picker)
- [ ] `Orbit/Services/AudioInputDeviceService.swift` exists and is referenced from `SpeechRecognitionService.beginCapture` and `SettingsView.swift`
- [ ] `dictationInputDeviceUID` is persisted across app restarts (smoke step 13 verifies)
- [ ] `npx prettier --write .` reports no further changes
- [ ] Smoke test step 6 (the actual translation) actually pasted English text
- [ ] Smoke test step 13 (external mic) actually used the external mic, not the built-in
