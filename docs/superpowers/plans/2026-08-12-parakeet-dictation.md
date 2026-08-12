# Parakeet Dictation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace WhisperKit with Parakeet TDT 0.6B v3 (via FluidAudio) as Orbit's speech engine, removing the translate tile and collapsing the per-language dictation tiles into a single dictation tile.

**Architecture:** The audio capture path in `SpeechRecognitionService` (AVAudioEngine tap → 16 kHz mono Float32 → preroll warmup → RMS VAD → clipboard paste) is untouched; only the transcription call is swapped. Parakeet v3 auto-detects language and cannot translate, so every locale-carrying parameter, model, view and settings key downstream of it is deleted. Work proceeds engine-first so the riskiest change is verified in isolation, then peels away the dead UI in compile-green steps.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, AVFoundation, CoreML via [FluidAudio](https://github.com/FluidInference/FluidAudio), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-12-parakeet-dictation-design.md`

## Global Constraints

- Deployment target macOS 14.0, Swift 5.9. Do not change either.
- Dependency: `https://github.com/FluidInference/FluidAudio` pinned with `exactVersion: 0.15.5`. It is a pre-1.0 package; do not use `from:`, which would allow breaking 0.x bumps.
- `project.yml` is the source of truth for the Xcode project. After editing it, always run `xcodegen generate` and commit the regenerated `Orbit.xcodeproj/project.pbxproj` and `Orbit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` together with the change.
- There is no test target. The verification cycle for every task is `./build.sh` (must succeed) plus the task's stated manual check.
- Run `npx prettier --write .` before every commit (it formats the Markdown files; it ignores Swift).
- The single supported model is Parakeet TDT 0.6B v3, referred to in UI copy as **Parakeet TDT 0.6B v3**. There is no model picker after Task 4.
- Do not touch: the AVAudioEngine tap, `AVAudioConverter` setup, `processAudioBuffer`, preroll/warmup logic, RMS VAD constants, `maxBufferSeconds`, the 60s hard cap, the ESC monitor, or `injectText`/pasteboard handling.

---

### Task 1: Swap the engine to Parakeet

Replaces WhisperKit with FluidAudio inside `SpeechRecognitionService` only. Public method signatures are kept temporarily (locale arguments accepted and ignored, `startTranslation` delegating to `startDictation`) so the rest of the app still compiles; Tasks 2-4 remove them. After this task Orbit dictates through Parakeet and is fully usable.

**Files:**

- Modify: `project.yml:8-22`
- Modify: `Orbit/Services/SpeechRecognitionService.swift` (imports, model lifecycle, transcription calls)
- Regenerate: `Orbit.xcodeproj/project.pbxproj`

**Interfaces:**

- Consumes: nothing from earlier tasks.
- Produces (used by Tasks 2-4):
  - `SpeechRecognitionService.startDictation(localeId: String, onError: @escaping (String) -> Void)` - `localeId` ignored, removed in Task 3.
  - `SpeechRecognitionService.startTranslation(sourceLocaleId: String, targetLocaleId: String, onError: @escaping (String) -> Void)` - delegates to `startDictation`, removed in Task 2.
  - `SpeechRecognitionService.isModelDownloaded(_ modelName: String) -> Bool` - argument ignored, simplified in Task 4.
  - `SpeechRecognitionService.downloadAndLoadModel(_ modelName: String) async` - argument ignored, simplified in Task 4.
  - `SpeechRecognitionService.ModelStatus` keeps its `modelName` associated values in this task; they carry the constant `SpeechRecognitionService.modelDisplayName`. Simplified in Task 4.
  - `static let SpeechRecognitionService.modelDisplayName = "Parakeet TDT 0.6B v3"`

- [ ] **Step 1: Swap the package in `project.yml`**

Replace the `packages:` block and the target dependency:

```yaml
packages:
  FluidAudio:
    url: https://github.com/FluidInference/FluidAudio
    exactVersion: 0.15.5
targets:
  Orbit:
    type: application
    platform: macOS
    sources:
      - path: Orbit
        excludes:
          - "**/*.entitlements"
    dependencies:
      - package: FluidAudio
        product: FluidAudio
```

Leave everything below `settings:` unchanged.

- [ ] **Step 2: Regenerate the project and resolve the package**

Run:

```bash
xcodegen generate
xcodebuild -project Orbit.xcodeproj -scheme Orbit -resolvePackageDependencies
```

Expected: package resolution succeeds and prints `FluidAudio`. The build will still fail at this point because `SpeechRecognitionService.swift` imports WhisperKit - that is expected and fixed in Step 4.

- [ ] **Step 3: Read the resolved FluidAudio API before writing code**

The exact signatures below were taken from FluidAudio's published documentation and MUST be confirmed against the pinned source before use. Run:

```bash
CHECKOUT=$(find ~/Library/Developer/Xcode/DerivedData -type d -path '*SourcePackages/checkouts/FluidAudio' | head -1)
echo "$CHECKOUT"
grep -rn "public static func downloadAndLoad\|public static func modelsExist\|public static func defaultCacheDirectory\|public func loadModels\|public func transcribe\|public enum AudioSource\|public typealias ProgressHandler" "$CHECKOUT/Sources/FluidAudio" | head -40
```

Record the answers to these three questions; they decide the code in Step 4:

1. Does `AsrModels.downloadAndLoad` accept a progress handler? If **yes**, wire it to `ModelStatus.downloading(progress:modelName:)` as written below. If **no**, keep the `.downloading` case but always publish `progress: 0` and render it as an indeterminate spinner in Task 4 - do not invent a progress API.
2. What is the default models directory helper called (expected `AsrModels.defaultCacheDirectory()`)? Use the real name in `isModelDownloaded`.
3. What is the `AudioSource` case for live microphone input (expected `.microphone`)? If the enum only has `.file`/`.system`, call `transcribe(samples)` with the default argument.

- [ ] **Step 4: Rewrite the engine sections of `SpeechRecognitionService.swift`**

Change the import:

```swift
import FluidAudio
```

(remove `import WhisperKit`)

Replace the header doc comment's first paragraph:

```swift
/// In-process speech recognition powered by Parakeet TDT 0.6B v3 (NVIDIA's
/// transducer ASR running on Apple Silicon via CoreML, through the
/// FluidAudio package).
///
/// Replaces the previous WhisperKit implementation. Parakeet reaches
/// comparable transcription quality at 600M parameters instead of 1.55B,
/// auto-detects language across 25 European languages, and emits
/// punctuation and capitalization. It has no translation mode and takes no
/// language parameter - both of which the surrounding UI used to expose.
```

Replace the stored properties (currently lines 47-51):

```swift
    // MARK: - Parakeet setup

    /// Display name for the one and only supported model. Shown in Settings.
    static let modelDisplayName = "Parakeet TDT 0.6B v3"

    private var asrManager: AsrManager?
    private var modelsLoading: Bool = false
```

Delete `private var whisperKit`, `private var whisperKitLoading`, `private var loadedModelName`.

Replace `isModelDownloaded` and delete `modelFolderURL(for:)` entirely:

```swift
    /// Returns true if the Parakeet model files are present in FluidAudio's
    /// cache. Doesn't trigger any network or load. The `modelName` argument
    /// is ignored - there is exactly one supported model.
    /// TEMPORARY signature (Task 1): the argument is removed in Task 4.
    func isModelDownloaded(_ modelName: String = SpeechRecognitionService.modelDisplayName) -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(), version: .v3)
    }
```

Replace the body of `downloadAndLoadModel`:

```swift
    /// Public entry point used by the Settings UI. Downloads the model if
    /// needed (with progress) and loads it into memory. Updates
    /// `modelStatus` throughout the lifecycle. Idempotent - calling while a
    /// download is already in flight is a no-op.
    /// TEMPORARY signature (Task 1): the argument is removed in Task 4.
    @MainActor
    func downloadAndLoadModel(_ modelName: String = SpeechRecognitionService.modelDisplayName) async {
        if modelsLoading { return }
        if asrManager != nil {
            modelStatus = .ready(modelName: Self.modelDisplayName)
            return
        }
        modelsLoading = true
        defer { modelsLoading = false }

        do {
            modelStatus = .downloading(progress: 0, modelName: Self.modelDisplayName)
            NSLog("[Orbit.speech] downloading/loading \(Self.modelDisplayName)…")
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            modelStatus = .loading(modelName: Self.modelDisplayName)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asrManager = manager
            modelStatus = .ready(modelName: Self.modelDisplayName)
            NSLog("[Orbit.speech] Parakeet ready")
        } catch {
            NSLog("[Orbit.speech] downloadAndLoadModel failed: \(error)")
            asrManager = nil
            modelStatus = .error(error.localizedDescription)
        }
    }
```

If Step 3 established that `downloadAndLoad` takes a progress handler, pass it and publish real progress instead of the fixed `0`:

```swift
            let models = try await AsrModels.downloadAndLoad(version: .v3) { progress in
                Task { @MainActor in
                    self.modelStatus = .downloading(
                        progress: progress.fractionCompleted,
                        modelName: Self.modelDisplayName
                    )
                }
            }
```

Rename and rewrite `ensureWhisperKitLoaded`:

```swift
    @MainActor
    private func ensureModelsLoaded(onError: @escaping (String) -> Void) async {
        if asrManager != nil { return }
        await downloadAndLoadModel()
        if asrManager == nil {
            onError("Failed to load the Parakeet model. Set up dictation in Settings → Dictation.")
            indicatorPanel?.hideIndicator()
            indicatorPanel = nil
        }
    }
```

In `prewarm()`, replace the model-name lookup with the constant:

```swift
    func prewarm() {
        guard isModelDownloaded() else {
            NSLog("[Orbit.speech] prewarm skipped - Parakeet model not downloaded")
            modelStatus = .notDownloaded
            return
        }
        Task { @MainActor in
            await downloadAndLoadModel()
        }
    }
```

In `startInternal`, replace the pre-flight guard and the `whisperKit` references:

```swift
        guard isModelDownloaded() else {
            NSLog("[Orbit.speech] start aborted - Parakeet model not downloaded")
            starting = false
            currentTask = .transcribe
            currentTranslationTargetId = nil
            onError("Speech model not downloaded. Set it up in Settings → Dictation.")
            showSetupReminderNotification()
            return
        }
```

and

```swift
        let initialState: RecordingIndicatorPanel.State =
            (asrManager == nil) ? .loading(message: "Loading model\u{2026}") : .listening
```

and inside the `ensurePermissions` closure:

```swift
            Task { @MainActor in
                await self.ensureModelsLoaded(onError: onError)
                if self.asrManager != nil {
                    if self.warmupActive {
                        self.promoteWarmupToSession(localeId: localeId)
                    } else {
                        self.indicatorPanel?.updateState(.starting)
                        self.beginCapture(localeId: localeId, onError: onError)
                    }
                }
                self.starting = false
            }
```

Replace the transcription call in `flushAndTranscribe` (currently the `DecodingOptions` block plus `kit.transcribe`):

```swift
        transcribing = true
        NSLog("[Orbit.speech] flushing \(Double(snapshot.count) / targetSampleRate)s of audio for transcription")

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await manager.transcribe(snapshot, source: .microphone)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    self.handleFlushedTranscript(text)
                    self.transcribing = false
                }
            } catch {
                NSLog("[Orbit.speech] transcribe error: \(error.localizedDescription)")
                await MainActor.run { self.transcribing = false }
            }
        }
```

with the guard at the top of the function changed to bind the manager:

```swift
        guard isRunning, !transcribing, let manager = asrManager else { return }
```

Also delete the now-unused `bcp47`/`language` locals in that function.

Replace the final-flush block in `stop(reason:flushBuffer:)` the same way:

```swift
        let minSamples = Int(targetSampleRate * minSpeechSeconds)
        if flushBuffer, hadSpeech, finalSnapshot.count > minSamples, let manager = asrManager, !transcribing {
            NSLog("[Orbit.speech] stop: final flush \(String(format: "%.2f", Double(finalSnapshot.count) / targetSampleRate))s audio")
            transcribing = true
            Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await manager.transcribe(finalSnapshot, source: .microphone)
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
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

Keep `currentTask`/`currentTranslationTargetId` declared for now (Task 2 deletes them), but change their type so nothing references WhisperKit's `DecodingTask`:

```swift
    /// TEMPORARY (Task 1): retained only so `startTranslation` and the
    /// indicator keep compiling until Task 2 deletes the translate feature.
    private enum SessionTask { case transcribe, translate }
    private var currentTask: SessionTask = .transcribe
```

`DecodingTask` was a WhisperKit type, so every signature that named it must switch to `SessionTask` in this task or the file will not compile: `startInternal(localeId:task:targetLocaleIdForDisplay:onError:)` takes `task: SessionTask`, `startDictation` passes `.transcribe`, and the `let capturedTask = currentTask` snapshot in `stop()` is deleted along with the `task:` argument it fed into `DecodingOptions`.

Make `startTranslation` delegate, since Parakeet cannot translate:

```swift
    /// TEMPORARY (Task 1): Parakeet has no translation mode. Delegates to a
    /// normal dictation session so the app keeps working until Task 2
    /// removes the translate feature entirely.
    func startTranslation(
        sourceLocaleId: String,
        targetLocaleId: String,
        onError: @escaping (String) -> Void = { _ in }
    ) {
        NSLog("[Orbit.speech] startTranslation called but Parakeet cannot translate - running plain dictation")
        startDictation(localeId: sourceLocaleId, onError: onError)
    }
```

Finally, delete the `boilerplateBlocklist` static set and its use in `handleFlushedTranscript`. Keep the bracket/parenthesis guards and the ellipsis stripping. The two lines to delete from `handleFlushedTranscript` are:

```swift
        let lower = trimmed.lowercased()
        if SpeechRecognitionService.boilerplateBlocklist.contains(lower) { return }
```

- [ ] **Step 5: Build**

Run: `./build.sh`
Expected: `Copied to ./Orbit.app` with no errors. If the build fails on a FluidAudio symbol, correct it against the real signature found in Step 3 rather than guessing again.

- [ ] **Step 6: Manual verification**

Launch `./Orbit.app`, then:

1. Settings → Dictation shows the speech model as not downloaded (the old Whisper state does not carry over). Click Download; it reaches Ready.
2. Open the ring, click a language tile, speak a Swedish sentence. Expect Swedish text with punctuation and capitalization pasted into the frontmost app - regardless of which language tile you clicked, since the locale is now ignored.
3. Speak an English sentence in a new session. Expect English text.
4. Press ESC mid-session: nothing is pasted. Re-trigger Orbit while dictating: the last utterance is pasted.

- [ ] **Step 7: Commit**

```bash
npx prettier --write .
git add project.yml Orbit.xcodeproj Orbit/Services/SpeechRecognitionService.swift
git commit -m "feat: replace WhisperKit with Parakeet TDT 0.6B v3 via FluidAudio"
```

---

### Task 2: Remove the translate feature

Parakeet cannot translate, so the tile and everything behind it goes.

**Files:**

- Delete: `Orbit/Models/TranslatePair.swift`, `Orbit/Views/TranslateTileView.swift`
- Modify: `Orbit/Models/OrbitItem.swift`, `Orbit/Views/OrbitView.swift:63-69`, `Orbit/ViewModels/OrbitViewModel.swift:77-79,103,130-131`, `Orbit/Services/SettingsService.swift`, `Orbit/Services/DictationService.swift:90-104`, `Orbit/Services/SpeechRecognitionService.swift`, `Orbit/Views/SettingsView.swift:428-481,585-587`

**Interfaces:**

- Consumes: `SpeechRecognitionService.startTranslation(...)` from Task 1 (deleted here).
- Produces: `OrbitItem` with cases `.app(RunningApp)` and `.language(DictationLanguage)` only; `SettingsService` without any `translate*` member.

- [ ] **Step 1: Delete the translate files**

```bash
git rm Orbit/Models/TranslatePair.swift Orbit/Views/TranslateTileView.swift
```

- [ ] **Step 2: Remove the `.translate` case from `OrbitItem`**

```swift
enum OrbitItem: Identifiable, Equatable {
    case app(RunningApp)
    case language(DictationLanguage)

    var id: String {
        switch self {
        case .app(let app): return "app:\(app.id)"
        case .language(let language): return "lang:\(language.id)"
        }
    }

    var displayName: String {
        switch self {
        case .app(let app): return app.name
        case .language(let language): return language.displayName
        }
    }
}
```

- [ ] **Step 3: Remove the translate branches from the ring**

In `Orbit/Views/OrbitView.swift`, delete the `case .translate(let pair):` branch and its `TranslateTileView(...)` body.

In `Orbit/ViewModels/OrbitViewModel.swift`:

- delete the `if let pair = settings.translatePair, let angle = settings.translateAngle { ... }` block in `show()`,
- change the warmup guard to `if SettingsService.shared.dictationEnabled {`,
- delete `case .translate(let pair): DictationService.startTranslation(pair: pair)` from `selectAndSwitch()`.

- [ ] **Step 4: Remove translate state from `SettingsService`**

Delete the properties `translateTileEnabled`, `translateSourceLocaleId`, `translateAngle`; their reads in `init()`; their writes in `save()`; the `translatePair` computed property; the `if let angle = translateAngle { all.append(angle) }` lines in `allAnchorAngles`; and the `if translatePair != nil, translateAngle == nil { ... }` block in `ensureAnchorAngles(for:)`.

- [ ] **Step 5: Remove translate entry points from the services**

In `Orbit/Services/DictationService.swift`, delete `startTranslation(pair:)` and its doc comment.

In `Orbit/Services/SpeechRecognitionService.swift`, delete `startTranslation(sourceLocaleId:targetLocaleId:onError:)`, the `SessionTask` enum, the `currentTask` and `currentTranslationTargetId` properties, and every remaining reference to them (the resets in `stop()`, the assignments in `startInternal`, and the `targetLocaleId:` argument in `showIndicator`). `startInternal` then takes only `localeId` and `onError`, and `startDictation` calls it directly.

In `Orbit/Views/RecordingIndicatorPanel.swift`, drop the `targetLocaleId` parameter from `show(localeId:state:targetLocaleId:onStopTapped:)` and from `RecordingIndicatorModel.init`, delete the `targetLocaleId` stored property and the `targetFlagEmoji` computed property, and replace the `if let targetFlag = targetFlagEmoji { ... } else { ... }` block in the body with just the `else` branch content:

```swift
                    Text(localeBadge)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)
```

- [ ] **Step 6: Remove the Translation section from Settings**

In `Orbit/Views/SettingsView.swift`, delete the entire `Section("Translation") { ... }` block (lines 428-481) and the `translateSourceCandidates` computed property (lines 585-587). In `WhisperModelOption`, delete the `supportsTranslation` property and its five initializer arguments, and remove the translation sentences from the `openai_whisper-large-v3-v20240930` and `openai_whisper-large-v3` descriptions. (The whole struct disappears in Task 4; this keeps the build green until then.)

Also update the microphone help text on line 406 to drop "and translation":

```swift
                Text("Orbit uses this microphone for dictation. \"System Default\" follows your macOS audio input setting.")
```

- [ ] **Step 7: Build**

Run: `./build.sh`
Expected: success, no warnings about unused translate symbols.

- [ ] **Step 8: Manual verification**

Launch `./Orbit.app`. Settings → Dictation no longer has a Translation section. Open the ring: no translate tile appears even though `translateTileEnabled` was true in defaults. Dictation from a language tile still works.

- [ ] **Step 9: Commit**

```bash
npx prettier --write .
git add -A
git commit -m "feat: remove translate tile (Parakeet has no translation mode)"
```

---

### Task 3: Collapse language tiles into one dictation tile

Parakeet auto-detects language, so a language selector cannot influence recognition. One `mic.fill` tile replaces the per-locale tiles, and the macOS Dictation preference sync loses its reason to exist.

**Files:**

- Create: `Orbit/Views/DictationTileView.swift`
- Delete: `Orbit/Models/DictationLanguage.swift`, `Orbit/Views/LanguageTileView.swift`, `Orbit/Services/DictationService.swift`
- Modify: `Orbit/Models/OrbitItem.swift`, `Orbit/Views/OrbitView.swift`, `Orbit/ViewModels/OrbitViewModel.swift`, `Orbit/Services/SettingsService.swift`, `Orbit/Services/SpeechRecognitionService.swift`, `Orbit/Views/RecordingIndicatorPanel.swift`, `Orbit/Views/LayoutPreviewView.swift`, `Orbit/Views/SettingsView.swift`

**Interfaces:**

- Consumes: `OrbitItem` from Task 2.
- Produces:
  - `enum OrbitItem { case app(RunningApp); case dictation }` with `id == "dictation"` and `displayName == "Dictation"`.
  - `SettingsService.dictationAngle: Double?` persisted under key `"dictationAngle"`.
  - `SettingsService.ensureAnchorAngles()` - no arguments.
  - `SpeechRecognitionService.startDictation(onError:)` - no locale.
  - `RecordingIndicatorPanel.show(state:onStopTapped:)` - no locale.
  - `DictationTileView(isSelected: Bool, size: CGFloat, isAnchored: Bool)`.

- [ ] **Step 1: Create `Orbit/Views/DictationTileView.swift`**

```swift
import SwiftUI

/// Ring tile that starts dictation. Visually mirrors `AppIconView` so app
/// and dictation tiles feel consistent in the ring: same rounded-rect shape,
/// selection glow, stroke, and scale.
struct DictationTileView: View {
    let isSelected: Bool
    let size: CGFloat
    var isAnchored: Bool = true

    /// The dictation tile is always anchored (that is how it gets into the
    /// ring). The flag is threaded through for consistency with
    /// `AppIconView` and so the layout preview can render mock tiles.
    private var effectiveSize: CGFloat {
        isAnchored ? size * 1.2 : size
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.ultraThinMaterial)
            .overlay(
                Image(systemName: "mic.fill")
                    .font(.system(size: effectiveSize * 0.5, weight: .medium))
                    .foregroundStyle(.primary)
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

- [ ] **Step 2: Replace the `.language` case in `OrbitItem`**

```swift
import Foundation

/// A single item rendered around the Orbit ring. Ring positions, angle math,
/// scroll-to-rotate and arrow navigation all operate on `[OrbitItem]` so that
/// apps and the dictation tile can coexist in a single ring.
enum OrbitItem: Identifiable, Equatable {
    case app(RunningApp)
    case dictation

    var id: String {
        switch self {
        case .app(let app): return "app:\(app.id)"
        case .dictation: return "dictation"
        }
    }

    var displayName: String {
        switch self {
        case .app(let app): return app.name
        case .dictation: return "Dictation"
        }
    }
}
```

- [ ] **Step 3: Update `SettingsService`**

Replace the property declarations `dictationLanguage1Id`, `dictationLanguage2Id` and `languageAngles` with a single:

```swift
    @Published var dictationAngle: Double?
```

In `init()`, replace their three reads with:

```swift
        dictationAngle = defaults.object(forKey: "dictationAngle") as? Double
```

In `save()`, replace their three writes with:

```swift
        if let angle = dictationAngle {
            defaults.set(angle, forKey: "dictationAngle")
        } else {
            defaults.removeObject(forKey: "dictationAngle")
        }
```

Replace `allAnchorAngles`, `ensureAnchorAngles`, `resetLayoutAngles` and delete `dictationLanguages`:

```swift
    /// All currently known anchored angles in one flat list (pinned apps +
    /// the dictation tile). Used by the default-placement algorithm when
    /// adding a new anchor.
    var allAnchorAngles: [Double] {
        var all = Array(pinnedAngles.values)
        if let angle = dictationAngle {
            all.append(angle)
        }
        return all
    }

    /// Ensures every currently-pinned bundle id, and the dictation tile when
    /// enabled, has a stored angle. Newly seen items are placed at the center
    /// of the largest currently-empty arc (Hitman weapon-wheel style), then
    /// auto-saved. Called on every ring show so the storage is always in sync
    /// with the user's pin/dictation selections.
    func ensureAnchorAngles() {
        var changed = false

        for bundleId in pinnedBundleIds where pinnedAngles[bundleId] == nil {
            let angle = RingLayout.nextAnchorAngle(existingAngles: allAnchorAngles)
            pinnedAngles[bundleId] = angle
            changed = true
        }

        if dictationEnabled, dictationAngle == nil {
            dictationAngle = RingLayout.nextAnchorAngle(existingAngles: allAnchorAngles)
            changed = true
        }

        // Prune angles for bundles that are no longer pinned so the
        // dictionary doesn't grow unbounded over time.
        let pinnedSet = Set(pinnedBundleIds)
        for key in pinnedAngles.keys where !pinnedSet.contains(key) {
            pinnedAngles.removeValue(forKey: key)
            changed = true
        }

        if changed { save() }
    }

    /// Wipes all stored angles; next `ensureAnchorAngles` call reassigns
    /// defaults for the current pinned set and the dictation tile.
    func resetLayoutAngles() {
        pinnedAngles = [:]
        dictationAngle = nil
        save()
    }
```

Leave `dictationModelName` and `sanitizeModelName` alone in this task - Task 4 removes them.

- [ ] **Step 4: Update `OrbitViewModel`**

In `show()`, replace the language block:

```swift
        let settings = SettingsService.shared
        let excluded = settings.excludedBundleIds
        let pinned = settings.pinnedBundleIds

        // Prune/assign angles for current anchored items before layout.
        settings.ensureAnchorAngles()
```

and the anchored-items construction:

```swift
        var anchored: [(OrbitItem, Double)] = []
        if settings.dictationEnabled, let angle = settings.dictationAngle {
            anchored.append((.dictation, angle))
        }
```

(keep the existing `for app in anchoredApps` loop below it)

Update the log line that referenced `languageAngles`:

```swift
        NSLog("[Orbit.layout] show() dictationAngle=\(String(describing: settings.dictationAngle)) pinAngles=\(settings.pinnedAngles)")
```

In `selectAndSwitch()`:

```swift
            switch item {
            case .app(let app):
                app.app.activate()
            case .dictation:
                SpeechRecognitionService.shared.startDictation { errorMessage in
                    NSLog("[Orbit.dictation] speech start failed: \(errorMessage)")
                }
            }
```

- [ ] **Step 5: Update `OrbitView`**

Replace the `case .language(let language):` branch with:

```swift
                        case .dictation:
                            DictationTileView(
                                isSelected: isSelected,
                                size: viewModel.iconSize,
                                isAnchored: positioned.isAnchored
                            )
```

- [ ] **Step 6: Drop the locale from `SpeechRecognitionService`**

Delete the `currentLocaleId` property. Change the public entry point and internal start:

```swift
    /// Start a dictation session. Parakeet detects the spoken language on
    /// its own, so there is nothing to configure per session.
    func startDictation(onError: @escaping (String) -> Void = { _ in }) {
        startInternal(onError: onError)
    }

    private func startInternal(onError: @escaping (String) -> Void) {
```

Remove every `localeId` argument and log interpolation inside `startInternal`, `beginCapture`, `promoteWarmupToSession` and `showIndicator`; their signatures become `beginCapture(onError:)`, `promoteWarmupToSession()` and `showIndicator(state:)`. The two log lines that named the locale become:

```swift
        NSLog("[Orbit.speech] promoted warmup to session, preroll=\(audioBuffer.count) samples")
```

```swift
        NSLog("[Orbit.speech] capture started")
```

- [ ] **Step 7: Drop the locale from `RecordingIndicatorPanel`**

`show` becomes:

```swift
    func show(
        state: State,
        onStopTapped: @escaping () -> Void
    ) {
        let model = RecordingIndicatorModel(state: state)
```

`RecordingIndicatorModel` keeps only `@Published var state` and `init(state:)`. In `RecordingIndicatorView`, delete `flagEmoji` and `localeBadge`, and replace the flag/badge row so only the status text remains:

```swift
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(hintText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
```

The `mic.fill` glyph already in the pulsing circle stays as-is.

- [ ] **Step 8: Update `LayoutPreviewView`**

Rename the anchor kind and icon:

```swift
    private struct Anchor: Identifiable, Equatable {
        enum Kind: Equatable { case pinnedApp, dictation }
        let id: String
        let kind: Kind
        var angleDegrees: Double
        let displayName: String
        let icon: AnchorIcon

        enum AnchorIcon: Equatable {
            case app(NSImage)
            case dictation
        }
    }
```

Replace the `case .language(let flag, let badge):` rendering branch:

```swift
            case .dictation:
                RoundedRectangle(cornerRadius: 8)
                    .fill(.ultraThinMaterial)
                    .frame(width: iconSize, height: iconSize)
                    .overlay(
                        Image(systemName: "mic.fill")
                            .font(.system(size: iconSize * 0.5, weight: .medium))
                            .foregroundStyle(.primary)
                    )
```

Replace the language loop in `loadAnchors()`:

```swift
    private func loadAnchors() {
        var result: [Anchor] = []
        settings.ensureAnchorAngles()

        if settings.dictationEnabled {
            result.append(
                Anchor(
                    id: "dictation",
                    kind: .dictation,
                    angleDegrees: settings.dictationAngle ?? 0,
                    displayName: "Dictation",
                    icon: .dictation
                )
            )
        }
```

(keep the `for bundleId in settings.pinnedBundleIds` loop and `anchors = result` unchanged)

Replace the `commit` switch and delete `localeBadge(for:)`:

```swift
    private func commit(anchor: Anchor, angle: Double) {
        switch anchor.kind {
        case .dictation:
            settings.dictationAngle = angle
        case .pinnedApp:
            let bundleId = String(anchor.id.dropFirst("app:".count))
            settings.pinnedAngles[bundleId] = angle
        }
        settings.save()
        loadAnchors()
    }
```

Delete the two stale `onChange` modifiers (`onChange(of: settings.dictationLanguage1Id)` and `onChange(of: settings.dictationLanguage2Id)`); `onChange(of: settings.dictationEnabled)` already covers the dictation tile. The empty-state copy ("No anchored items yet. / Pin an app or enable dictation to see them here.") still reads correctly and needs no change.

- [ ] **Step 9: Remove the language UI from Settings**

In `Orbit/Views/SettingsView.swift`:

- delete the `@State private var enabledDictationLocales: [DictationLanguage] = []` declaration and every use,
- delete the whole `Section("Languages") { ... }` block,
- delete the whole `Section("Status") { ... }` block that shows "Current dictation language" (keep `dictationShortcutStatusRow` itself and move it into the Speech model section),
- delete `dictationLanguagePicker(title:selection:)` and `refreshDictationLocales()`,
- delete any `.onAppear`/`.task` call to `refreshDictationLocales()`,
- change the enable toggle and its help text:

```swift
                Toggle("Show the dictation tile in the ring", isOn: $settings.dictationEnabled)
                    .onChange(of: settings.dictationEnabled) {
                        settings.save()
                        if settings.dictationEnabled {
                            // Assign an angle now so the tile appears at a
                            // sensible spot the next time the ring opens.
                            settings.ensureAnchorAngles()
                        }
                    }

                Text("When on, a dictation tile appears in the Orbit ring. Selecting it starts on-device dictation. The spoken language is detected automatically. Recognition runs entirely inside Orbit - no audio leaves your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
```

Keep the `openDictationSystemSettings()` helper only if something still calls it; otherwise delete it too.

- [ ] **Step 10: Delete the obsolete files**

```bash
git rm Orbit/Models/DictationLanguage.swift Orbit/Views/LanguageTileView.swift Orbit/Services/DictationService.swift
```

In `Orbit/AppDelegate.swift`, update the prewarm comment to say Parakeet instead of WhisperKit and "dictation tile click" instead of "language-tile click". No code change is needed there.

- [ ] **Step 11: Build**

Run: `./build.sh`
Expected: success. Any remaining reference to `DictationLanguage`, `languageAngles` or `DictationService` will surface here as a compile error - fix it rather than reintroducing the type.

- [ ] **Step 12: Manual verification**

Launch `./Orbit.app`:

1. Settings → Dictation has no language pickers and no "Current dictation language" row.
2. With dictation enabled, the ring shows exactly one `mic.fill` tile; the center label reads "Dictation".
3. Clicking it starts a session; the indicator shows the mic glyph and "Listening…" with no flag.
4. Swedish and English speech both transcribe correctly.
5. Settings → Layout preview shows the dictation tile as a mic square; dragging it and reopening the ring keeps the new angle.

- [ ] **Step 13: Commit**

```bash
npx prettier --write .
git add -A
git commit -m "feat: collapse dictation language tiles into a single dictation tile"
```

---

### Task 4: Simplify the model UI to a single Parakeet model

Removes the last WhisperKit-era abstraction: a five-model picker for an engine that has one model.

**Files:**

- Modify: `Orbit/Views/SettingsView.swift:1-58,342-372,487-547,566-573`, `Orbit/Services/SettingsService.swift`, `Orbit/Services/SpeechRecognitionService.swift`

**Interfaces:**

- Consumes: `SpeechRecognitionService.modelDisplayName`, `isModelDownloaded(_:)`, `downloadAndLoadModel(_:)` from Task 1.
- Produces:
  - `SpeechRecognitionService.ModelStatus` with cases `.notDownloaded`, `.downloading(progress: Double)`, `.loading`, `.ready`, `.error(String)`.
  - `SpeechRecognitionService.isModelDownloaded() -> Bool` and `downloadAndLoadModel() async`, both without arguments.

- [ ] **Step 1: Simplify `ModelStatus` and the two lifecycle signatures**

In `Orbit/Services/SpeechRecognitionService.swift`:

```swift
    /// Model lifecycle state, observable from SwiftUI Settings views.
    enum ModelStatus: Equatable {
        case notDownloaded
        case downloading(progress: Double)  // 0..1
        case loading
        case ready
        case error(String)
    }
```

Drop the `modelName` argument from `isModelDownloaded` and `downloadAndLoadModel` (they were already ignoring it), and update every `modelStatus = ...` assignment to the new cases, e.g. `modelStatus = .ready`, `modelStatus = .downloading(progress: 0)`, `modelStatus = .loading`. Delete the `// TEMPORARY signature (Task 1)` comments.

- [ ] **Step 2: Delete `WhisperModelOption` and the model picker**

In `Orbit/Views/SettingsView.swift`, delete the entire `WhisperModelOption` struct (lines 1-58, including its `all` catalogue) and replace the `Section("Speech model")` body with:

```swift
                Section("Speech model") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(SpeechRecognitionService.modelDisplayName)
                            .font(.body)
                        Text("Runs on-device via CoreML. Covers 25 European languages with automatic language detection, punctuation and capitalization.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    speechModelStatusRow

                    dictationShortcutStatusRow
                }
```

- [ ] **Step 3: Rewrite `speechModelStatusRow`**

```swift
    @ViewBuilder
    private var speechModelStatusRow: some View {
        switch speech.modelStatus {
        case .notDownloaded:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.orange)
                    Text("Not downloaded")
                        .foregroundStyle(.secondary)
                }
                Button("Download \(SpeechRecognitionService.modelDisplayName)") {
                    Task { await speech.downloadAndLoadModel() }
                }
                .buttonStyle(.bordered)
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Downloading\u{2026}")
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }
        case .loading:
            HStack {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
                Text("Loading\u{2026}")
                    .foregroundStyle(.secondary)
            }
        case .ready:
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Ready")
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("Error")
                        .foregroundStyle(.red)
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    Task { await speech.downloadAndLoadModel() }
                }
                .buttonStyle(.bordered)
            }
        }
    }
```

If Step 3 of Task 1 established that FluidAudio exposes no download progress, replace the `.downloading` branch body with an indeterminate row instead:

```swift
        case .downloading:
            HStack {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
                Text("Downloading\u{2026} (about 600 MB)")
                    .foregroundStyle(.secondary)
            }
```

- [ ] **Step 4: Update the engine blurb**

Replace the text in `dictationShortcutStatusRow`:

```swift
            Text("Orbit runs Parakeet TDT 0.6B v3 locally via FluidAudio (CoreML on Apple Silicon) - recognition is entirely on-device and bypasses the system Dictation HUD. macOS will prompt for microphone permission the first time you start dictation. Click the floating indicator or press ESC to stop.")
```

Also update the "Pause tolerance" help text, which still names Whisper:

```swift
                    Text("How long Orbit waits in silence before transcribing what you've said. Higher values let you pause mid-sentence without fragmenting the output. Default 0.8s.")
```

- [ ] **Step 5: Delete `dictationModelName`**

In `Orbit/Services/SettingsService.swift`, delete the `dictationModelName` property, its read in `init()`, its write in `save()`, and the `sanitizeModelName` static helper.

- [ ] **Step 6: Build**

Run: `./build.sh`
Expected: success. A compile error naming `dictationModelName` or `WhisperModelOption` means a call site was missed.

- [ ] **Step 7: Manual verification**

Launch `./Orbit.app`, then:

1. Settings → Dictation shows one Speech model section with the Parakeet name, a status row and no picker. With the model already downloaded it reads "Ready" immediately on open.
2. Copy something to the clipboard, dictate a sentence, then paste manually somewhere else - the original clipboard content is back, and no Orbit transcript appears in your clipboard history manager.
3. Select a non-default microphone in the input device picker and dictate; capture uses that device (unplug the default input to confirm if needed).
4. Quit and relaunch: the first dictation starts without a "Loading model…" state, confirming `prewarm()` still loads from cache with no network access.

- [ ] **Step 8: Commit**

```bash
npx prettier --write .
git add -A
git commit -m "refactor: replace Whisper model picker with single Parakeet model UI"
```

---

### Task 5: Update the docs

`SPEC.md` must describe the app as it now is - the project's CLAUDE.md requires it to be complete enough to rebuild the app from scratch.

**Files:**

- Modify: `SPEC.md`, `README.md`, `CHANGELOG.md`, `project.yml` (version bump)

**Interfaces:**

- Consumes: the finished state of Tasks 1-4.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Find every stale reference**

```bash
grep -n "Whisper\|whisper\|translate\|Translate\|language tile\|LanguageTile\|DictationService\|DictationLanguage\|TranslatePair" SPEC.md README.md | cut -c1-160
```

Work through the list top to bottom; each hit is either rewritten for Parakeet or deleted along with its section.

- [ ] **Step 2: Rewrite the affected `SPEC.md` sections**

At minimum these must be updated: the file inventory (five files deleted, `DictationTileView.swift` added), the dependency list (WhisperKit → FluidAudio `exactVersion: 0.15.5`), the dictation pipeline description (no locale, no decode options, `AsrManager.transcribe`), the ring item model (`OrbitItem` has two cases), the Settings → Dictation description (no language pickers, no model picker, no translation section), the `UserDefaults` key list (`dictationAngle` replaces `languageAngles`, `dictationLanguage1Id`, `dictationLanguage2Id`, `dictationModelName`, `translateTileEnabled`, `translateSourceLocaleId`, `translateAngle`), and the recording indicator description (no flags).

Add a short subsection noting that stale defaults keys are left unread with no migration, and that old WhisperKit models remain on disk at `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/` and can be deleted manually to reclaim several GB.

- [ ] **Step 3: Update `README.md`**

Same substitutions, at the level of detail the README already uses. Remove any translate-tile feature bullet and any Whisper model-size table.

- [ ] **Step 4: Bump the version and write the changelog entry**

In `project.yml`, set `MARKETING_VERSION: "2.0.0"` - the removed translate tile and the removed language tiles are breaking user-facing changes. Then `xcodegen generate`.

Add to `CHANGELOG.md`, matching the file's existing heading style:

```markdown
## 2.0.0

### Changed

- Speech recognition now runs NVIDIA Parakeet TDT 0.6B v3 through FluidAudio instead of OpenAI Whisper through WhisperKit. Comparable accuracy at 600M parameters instead of 1.55B, with automatic punctuation and capitalization.
- Dictation language is detected automatically across 25 European languages. The per-language ring tiles are replaced by a single dictation tile.
- Settings no longer has a speech model picker - Parakeet has one model.

### Removed

- The translate-to-English tile. Parakeet has no translation mode; Whisper's `.translate` task was the only thing that supported it.
- The macOS Dictation language sync. With no per-tile language left to mirror, Orbit no longer writes `com.apple.speech.recognition.AppleSpeechRecognition.prefs`.

### Upgrade notes

- Old WhisperKit models are not deleted automatically. They live in `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/` and can run to several GB.
- The Parakeet model downloads on first use from Settings → Dictation.
```

- [ ] **Step 5: Build and verify docs**

Run: `./build.sh`
Expected: success (the version bump is the only code-adjacent change).

Then re-run the Step 1 grep. Expected: no hits left in `SPEC.md` or `README.md` except historical changelog-style mentions you deliberately kept.

- [ ] **Step 6: Commit**

```bash
npx prettier --write .
git add -A
git commit -m "docs: update SPEC, README and CHANGELOG for Parakeet 2.0.0"
```

---

## Post-implementation check

Not a task - run this once everything is committed, since it is the thing the whole change was made to find out:

- Dictate a mixed-language session: three Swedish sentences, then three English ones, without stopping between them. Note whether any utterance comes back in the wrong language.
- Dictate five very short utterances ("ja", "okej", "nej", "kanske", "yes"). Short input is where auto-detection is weakest; if these fail consistently, that is the finding that decides whether Parakeet stays.
- Compare start-to-first-text latency against the Whisper build (git tag `v1.1.0`) on a sentence of roughly ten words.
