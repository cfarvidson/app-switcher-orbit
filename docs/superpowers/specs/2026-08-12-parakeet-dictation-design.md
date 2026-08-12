# Replace WhisperKit with Parakeet TDT 0.6B v3

**Date:** 2026-08-12
**Status:** Approved (brainstorming complete)
**Author:** brainstorming session with Carl-Fredrik Arvidson

## Goal

Replace Orbit's speech recognition engine. WhisperKit (OpenAI Whisper via CoreML) is swapped out for NVIDIA Parakeet TDT 0.6B v3, running through the [FluidAudio](https://github.com/FluidInference/FluidAudio) Swift package (CoreML, ANE-accelerated, on-device).

Two features are removed as a direct consequence, because Parakeet cannot do what Whisper did:

1. **The translate tile is deleted.** It depends on Whisper's `task: .translate`. Parakeet transcribes only.
2. **Per-language dictation tiles collapse into a single dictation tile.** Parakeet v3 auto-detects language across 25 European languages and takes no language parameter, so a language selector would no longer influence recognition.

## Why

Parakeet TDT 0.6B v3 reaches roughly Whisper large-v3 transcription quality with 600M parameters instead of 1.55B, at ~110x realtime on Apple Silicon. It includes automatic punctuation and capitalization, and covers Swedish along with 24 other European languages. Today's setup forces a tradeoff between the fast small Whisper models (weaker transcription) and large-v3 (slow, RAM-hungry). Parakeet removes the tradeoff, so the model picker disappears with it.

Removing the language tiles is not collateral damage but the honest UI: a language selector that does not change recognition behaviour would mislead the user. The system Dictation language sync in `DictationService` also loses its purpose - it existed so the user's _physical_ macOS dictation shortcut matched the tile they clicked, and there is no tile-level language left to mirror.

## Scope and constraints

**In scope:**

- Dependency swap in `project.yml`: WhisperKit out, FluidAudio in.
- `SpeechRecognitionService` rewritten around `AsrManager` / `AsrModels`.
- Ring model, tile view and settings collapsed to a single dictation tile.
- Whisper model picker replaced by a single-model download/status UI.
- Full removal of the translate feature.
- `SPEC.md` updated to match.

**Out of scope:**

- Streaming recognition. FluidAudio ships a `StreamingAsrManager`, but Orbit injects finished utterances via clipboard paste; streaming partial hypotheses would require rewriting already-pasted text. The existing VAD-chunked batch model is kept.
- Deleting the user's downloaded Whisper models. They are left in place (see Cleanup below).
- Any change to the audio capture path, VAD tuning, preroll warmup, ESC handling, hard caps, or clipboard injection.
- Migration of stale `UserDefaults` keys. They are simply no longer read.

**Constraints:**

- macOS 14+, Apple Silicon. FluidAudio requires the same deployment target Orbit already sets.
- No test target exists in the project. Verification is a manual checklist (see below).

## Architecture

### Engine

The audio pipeline is unchanged and continues to produce exactly what Parakeet expects: 16 kHz mono Float32 PCM in `[-1, 1]`.

```
AVAudioEngine tap
  → AVAudioConverter (device format → 16 kHz mono Float32)
  → preroll circular buffer (warmup) / audioBuffer (session)
  → RMS VAD, silence trigger, 25s buffer cap, 60s session cap
  → [Float] snapshot
  → AsrManager.transcribe(snapshot)      ← the only replaced step
  → transcript cleanup
  → clipboard paste (Cmd+V, transient pasteboard markers)
```

The transcription call goes from:

```swift
let options = DecodingOptions(verbose: false, task: currentTask, language: language, ...)
let results = try await kit.transcribe(audioArray: snapshot, decodeOptions: options)
let text = results.map(\.text).joined(separator: " ")
```

to:

```swift
let result = try await asrManager.transcribe(snapshot, source: .microphone)
let text = result.text
```

There are no decode options, no language argument and no task argument. Consequently these members are deleted from `SpeechRecognitionService`: `currentLocaleId`, `currentTask`, `currentTranslationTargetId`, `whisperKit`, `whisperKitLoading`, `loadedModelName`, and the `startTranslation(sourceLocaleId:targetLocaleId:onError:)` entry point. `startInternal` loses its `localeId`, `task` and `targetLocaleIdForDisplay` parameters.

`startDictation(onError:)` becomes the single public entry point for beginning a session. `warmupAudioCapture()`, `cancelWarmup()`, `stop(reason:flushBuffer:)` and `prewarm()` keep their current signatures and semantics, minus the locale arguments.

### Model lifecycle

`ModelStatus` stays as the observable state driving the Settings UI, but loses its `modelName` associated values since there is exactly one model:

```swift
enum ModelStatus: Equatable {
    case notDownloaded
    case downloading(progress: Double)   // 0..1
    case loading
    case ready
    case error(String)
}
```

The three lifecycle functions map onto FluidAudio:

| Today (WhisperKit)                                    | After (FluidAudio)                                          |
| ----------------------------------------------------- | ----------------------------------------------------------- |
| `isModelDownloaded(_ modelName:)` + hand-rolled path  | `AsrModels.modelsExist(at:version:)`                        |
| `WhisperKit.download(variant:from:progressCallback:)` | `AsrModels.downloadAndLoad(version: .v3, progressHandler:)` |
| `WhisperKit(WhisperKitConfig(modelFolder:))`          | `AsrManager(config: .default)` + `loadModels(_:)`           |

The hand-rolled `modelFolderURL(for:)` helper is deleted; FluidAudio owns its own cache location. Existing behaviour is preserved: `prewarm()` loads the model at launch **only if already downloaded** and never triggers a network fetch, and a tile click with no downloaded model aborts with the "Set it up in Settings" alert rather than downloading implicitly.

### Transcript handling

`handleFlushedTranscript` keeps the leading-space joining between utterances, the ellipsis stripping, and the bracket/parenthesis filter (`[Music]`, `(applause)`).

The `boilerplateBlocklist` set is deleted. Entries like "Thanks for watching!" are Whisper hallucinations on silence; Parakeet's transducer architecture does not produce them, and keeping the list risks silently swallowing a legitimate short utterance.

### Ring model and views

`OrbitItem` collapses two cases into one:

```swift
enum OrbitItem: Identifiable, Equatable {
    case app(RunningApp)
    case dictation
}
```

- `id` for the new case is `"dictation"`, `displayName` is `"Dictation"`.
- New `DictationTileView`: same `RoundedRectangle(cornerRadius: 12)` over `.ultraThinMaterial`, same selection glow, stroke, 1.25x selection scale and 1.2x anchored boost as `AppIconView` and the tile it replaces. The flag emoji is replaced by SF Symbol `mic.fill` at `effectiveSize * 0.5`, and the locale-code badge in the bottom-trailing corner is dropped.
- `RecordingIndicatorPanel` shows `mic.fill` instead of a flag, and `show(localeId:state:targetLocaleId:onStop:)` loses both locale parameters.

Deleted files: `Models/DictationLanguage.swift`, `Models/TranslatePair.swift`, `Views/LanguageTileView.swift`, `Views/TranslateTileView.swift`, `Services/DictationService.swift`.

`OrbitViewModel` calls `SpeechRecognitionService.shared.startDictation()` directly on `.dictation` activation, replacing both `DictationService.switchLanguageAndStart(_:)` and `DictationService.startTranslation(pair:)`. Its warmup guard becomes `if SettingsService.shared.dictationEnabled`.

### Settings

`SettingsService` loses `dictationLanguage1Id`, `dictationLanguage2Id`, `languageAngles`, `dictationModelName`, `translateTileEnabled`, `translateSourceLocaleId`, `translateAngle`, the `dictationLanguages` and `translatePair` computed properties, and `sanitizeModelName`. It gains a single `dictationAngle: Double?`, persisted under the key `"dictationAngle"`.

`ensureAnchorAngles(for:)` loses its argument and becomes `ensureAnchorAngles()`: it assigns angles to pinned apps as today, and assigns `dictationAngle` via `RingLayout.nextAnchorAngle(existingAngles:)` the first time dictation is enabled. `allAnchorAngles` sums pinned angles plus `dictationAngle`. `resetAngles()` clears `dictationAngle` alongside `pinnedAngles`.

The Dictation tab in `SettingsView` keeps:

- the "Enable dictation" toggle,
- the model status row, Download button and progress bar - now for one fixed model, labelled **Parakeet TDT 0.6B v3**, described as covering 25 European languages with automatic language detection, punctuation and capitalization,
- the silence-trigger slider,
- the microphone input device picker.

It loses: `WhisperModelOption` and its five-entry catalogue, the model `Picker` and its `onChange` handler, both language pickers, the entire translate section (toggle, source picker, Turbo warning) and `translateSourceCandidates`.

### Stale defaults

`languageAngles`, `dictationLanguage1Id`, `dictationLanguage2Id`, `dictationModelName`, `translateTileEnabled`, `translateSourceLocaleId` and `translateAngle` are no longer read or written. No migration code is added: on first launch after the update, `dictationAngle` is nil and gets assigned by the existing next-empty-arc algorithm, so the dictation tile lands in a sensible ring position without user action.

### Cleanup (user-facing note, not code)

Downloaded WhisperKit models are **not** deleted by Orbit. They live in:

```
~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/
```

and can run to several GB. This path is documented in `SPEC.md` and the changelog entry so the user can remove them manually.

## Error handling

Behaviour is preserved end to end; only the failing subsystem changes name:

- **Model not downloaded on tile click** - session aborts before touching the mic, `NSAlert` points to Settings → Dictation, `.orbitOpenSettings` notification fires on confirm.
- **Model load failure** - `modelStatus = .error(message)`, indicator hidden, `onError` propagated to the caller's log line.
- **Microphone permission denied** - unchanged: `NSAlert` linking to System Settings → Privacy & Security → Microphone.
- **Audio engine start failure** - unchanged: indicator hidden, error surfaced via `onError`.
- **Transcription throw** - logged, `transcribing` reset to false, session continues so the next utterance still works.
- **Download failure or interruption** - `modelStatus = .error`, Download button returns to its actionable state so the user can retry.

## Testing

The project has no test target, so verification is manual after `./build.sh`:

1. Fresh state: Settings → Dictation shows Parakeet v3 as not downloaded; Download reports progress and ends in Ready.
2. Ring shows exactly one dictation tile with the `mic.fill` glyph; no flags, no translate tile.
3. Swedish speech pastes Swedish text with correct punctuation and capitalization.
4. English speech in the same session pastes English text, with nothing switched in between.
5. Preroll still works: speech begun at the moment of clicking the tile keeps its first syllable.
6. ESC cancels and discards the buffer; clicking the indicator commits and flushes; re-triggering Orbit commits and flushes.
7. Multi-utterance session separates utterances with a single space.
8. Clipboard contents are restored after paste and no entry appears in the clipboard history manager.
9. Relaunch: `prewarm()` loads the model with no network access and the first dictation starts without a loading state.
10. Input device picker still binds capture to the selected microphone.

## Risks

- **Language auto-detection on short utterances.** Very short input ("ja", "okej") gives the detector little to work with and may resolve to the wrong language. This is the main unknown and the reason the change is framed as a test; it can only be judged in real use.
- **FluidAudio API drift.** The signatures above come from the package's published documentation. The first build may need adjustment against the actual API surface of the pinned version.
- **First-load latency.** Parakeet v3 is a multi-model bundle (encoder, decoder, joint, preprocessor). Initial ANE compilation on first load may exceed WhisperKit's, which would show up as a longer `.loading` state on the very first session after download.
- **No fallback engine.** With WhisperKit removed, a Parakeet regression has no in-app escape hatch; reverting means reverting the commit.
