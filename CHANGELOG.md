# Changelog

## 2.2.0

### Changed

- Opening the Orbit ring no longer starts the microphone. Pre-roll capture on `show()` took the input device and paused video in browsers and players. The mic starts only when you select the dictation tile.
- Dictation feedback moved from a floating panel near the cursor into the menu bar icon. The panel sat exactly where you were working; the icon now carries the whole session through five visible states - a dimmed breathing dotted circle while the model loads, a dimmed static waveform while the microphone is starting up, an accent-colored breathing waveform while listening, a static ellipsis while the final utterance is transcribed, and the plain dotted circle at rest. The menu grows a status line and a "Stop Dictation" command while a session is live, replacing the panel's click-to-stop. ESC still cancels and the hotkey still stops and commits, both unchanged.
- Pinned ring positions are now preferred directions rather than fixed angles. The ring is always evenly divided into as many slots as there are items, and each pinned app takes the free slot closest to the direction you dragged it. Clustering three pins in one quadrant no longer crams them together and smears every auto-added app across the rest of the circle. Existing pinned positions are read as preferences, so nothing needs to be set up again.
- Dictation can now be limited to the languages you actually speak. Parakeet detects language on its own and would occasionally decide Swedish was Russian, pasting Cyrillic gibberish into whatever you were typing in. Settings > Dictation > Languages lets you pick your languages, and Orbit constrains the decoder to that alphabet. The list is preselected from your macOS language settings, so it works without being configured. Picking languages from different alphabets turns filtering off, and the setting says so rather than looking active while doing nothing.
- The Layout tab now previews the resolved ring with every running app in it, instead of showing the pinned apps alone. Non-pinned apps are drawn small and dimmed, and rearrange live as you drag. Dragging is free - there is no 15 degree snapping and no collision nudging, because the solver quantizes to slots regardless.

### Fixed

- Settings no longer tells you to click the deleted floating listening indicator. Stop is the menu bar command, the hotkey, or ESC.
- The Settings window is resizable (520×720, min 520×560) so the Dictation tab is no longer clipped below a 640 pt frame.
- Pressing Escape to cancel dictation no longer leaks the key press into the app you were typing in. It used to cancel the session and then also close your dialog, dismiss your find bar, or drop you out of your editor's insert mode. Escape is now intercepted for the duration of a session and consumed. This needs Accessibility permission, which Orbit already requires; without it, Escape still cancels dictation exactly as before.
- Flushed transcripts are logged by character count, not the spoken text.

### Removed

- `RecordingIndicatorPanel`, the floating "Listening…" panel.

## 2.1.0

### Fixed

- New ring anchors are no longer placed on top of an existing one. When two anchors shared a stored angle, the gap scan in `RingLayout.nextAnchorAngle` read that zero-width gap as a full circle and returned its midpoint, which landed on an occupied angle. `RingLayout.compute` has no duplicate handling, so the two tiles rendered on the same point and the later one took the click. In practice: the new dictation tile could end up under a pinned app, showing that app's icon and launching it instead of starting dictation.

### Note

- 2.0.0 was never released. Its changes ship here.

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
- If you only had the translate tile enabled and dictation turned off, you now have no ring tile at all - the app does not tell you this. Enable dictation in Settings → Dictation to get a ring tile back.

## 1.1.0

### New Features

- **Translate-to-English dictation tile** — A new tile in the Orbit ring that takes audio in a configurable source language (default Swedish) and pastes English text into the frontmost app. The tile renders two flags side-by-side (🇸🇪 → 🇬🇧) so the translation direction is unmistakable. Powered by WhisperKit's built-in `.translate` task — audio stays on-device. Configure the source language in Settings → Dictation → Translation. Target flag follows whichever `en_*` variant you have enabled in System Settings.
- **Microphone input device picker** — New control in Settings → Dictation → Microphone that lets you pin Whisper to a specific input device independent of the macOS system default. Solves the common "I plugged in a USB mic but Whisper keeps using the built-in" paper cut. Powered by a small CoreAudio wrapper (`AudioInputDeviceService`) that enumerates input devices by persistent UID. Silent fallback to the system default if the stored device is disconnected.
- **Pause tolerance slider** — Settings → Dictation → Microphone now has a "Pause tolerance" slider (0.5–3.0s, default 0.8s). Slow speakers who pause mid-sentence can dial this up so their natural rhythm doesn't fragment the transcript.

### Improvements

- **Pre-roll audio capture** — The audio engine now starts the moment the Orbit ring opens, filling a 2-second circular buffer. When you click a dictation or translate tile, that buffer is promoted into the session — so the first phoneme you speak when clicking is never lost to engine startup latency. Trade-off: the macOS mic privacy LED lights for the duration the ring is visible. This is the visible cost of not dropping words at click time.
- **`.starting` indicator state** — The recording indicator used to say "Listening…" immediately after `AVAudioEngine.start()` returned, but the engine took another ~100–300 ms to actually deliver audio. The indicator now shows "Starting…" until the first real audio buffer arrives, then flips to "Listening…". Combined with pre-roll, no more dropped opening words.
- **Whisper ellipsis stripping** — Whisper inserts "…" mid-sentence whenever it detects a pause (interpreted as trailing-off speech). For dictation this polluted natural speech with ellipsis the user didn't intend. Both ASCII "..." and Unicode "…" forms are now stripped from transcripts before injection.
- **Turbo translation warning** — OpenAI's Whisper Large v3 Turbo is fine-tuned for transcription only and silently ignores `task: .translate`. Settings now shows an orange warning in the Translation section when Turbo is the selected model, explaining the limitation and pointing at Large v3 as the alternative.
- **Dual-flag recording indicator** — During a translate session, the floating indicator renders both flags (🇸🇪 → 🇬🇧) instead of the regular "single flag + locale badge" layout used for same-language dictation. Makes it obvious mid-session that translation is active.

### Technical details

- `SpeechRecognitionService` split its single `start(localeId:)` method into `startDictation(localeId:)` and `startTranslation(sourceLocaleId:targetLocaleId:)` delegating to a private `startInternal(localeId:task:targetLocaleIdForDisplay:)` that threads the WhisperKit `DecodingTask` through the existing transcription pipeline.
- `DictationService.startTranslation(pair:)` deliberately does NOT write the macOS Dictation plist prefs, because system Dictation cannot translate — touching those prefs would misconfigure the user's physical dictation shortcut.
- New `OrbitItem.translate(TranslatePair)` case + new `TranslateTileView` with the same visual treatment as language tiles but with a 3-way flag-arrow-flag layout.
- `translateAngle` is preserved across enable/disable cycles of the translate toggle, so the ring slot is restored when you re-enable.

## 1.0.13

### Improvements

- **Dictation never pollutes clipboard history** — Both the transcript paste and the restore are marked with the [nspasteboard.org](http://nspasteboard.org/) transient/concealed/auto-generated types, so clipboard history managers (Maccy, Paste, Pastebot, Raycast clipboard, Alfred Snippets, …) skip the entries entirely. Your history shows exactly what it would have without Orbit running.

## 1.0.12

### New Features

- **On-device dictation via Whisper** — The dictation tiles no longer drive macOS's built-in DictationIM. Orbit now runs OpenAI Whisper locally via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML on Apple Silicon) entirely in-process, with proper punctuation, casing, and sentence boundaries across all 99 Whisper languages. Audio never leaves your Mac.
- **Speech model picker** — Settings → Dictation now lets you choose from Tiny / Base / Small (recommended) / Medium / Large v3 Turbo / Large v3. Models download from Hugging Face with progress; the previously selected model is pre-loaded into RAM at launch so the first language-tile click is instant.
- **Floating recording indicator** — A small non-activating panel near the cursor shows "Listening…" while a session is active. Click it to commit and stop. Loading state covers first-time model loads.
- **Ring layout positioning** — Pinned apps and language tiles get fixed angles around the ring (Hitman weapon-wheel style) so they keep the same position regardless of which other apps are running. Layout preview tab in Settings.

### Improvements

- **Press hotkey to commit dictation** — Stop the session by re-pressing your Orbit hotkey or clicking the indicator and the buffered audio is transcribed and pasted as a final utterance, so you don't have to sit through the VAD silence timer. ESC still cancels (matches macOS Dictation convention).
- **Universal text injection** — Dictation pastes via `NSPasteboard` + synthesized `Cmd+V` instead of `CGEvent.keyboardSetUnicodeString`. Works in Electron/Chromium apps (Cursor, VS Code, Slack, Discord, Notion) where unicode-only event injection was silently dropped. The pre-injection clipboard contents are restored after 300 ms.
- **Stale Accessibility entry detection** — On launch, Orbit now checks `AXIsProcessTrusted()` independently of the system prompt. After every rebuild, ad-hoc-signed apps lose their TCC code-requirement match — the entry stays visible in System Settings → Privacy & Security → Accessibility but is silently denied, which broke synthesized keyboard events. Orbit now detects this and shows a warning alert with a button to open the right settings pane so you can toggle the entry off and back on.
- **Accurate permission strings** — `NSMicrophoneUsageDescription` now correctly describes on-device speech recognition. The unused `NSSpeechRecognitionUsageDescription` is gone (Orbit doesn't use `SFSpeechRecognizer`).

### Bug Fixes

- **Removed obsolete dictation invocation paths** — The previous menu-walking AX path and the earlier `CGPostKeyboardEvent` synthesis are both gone. Both were fragile (DictationIM died ~1.4 s after start with `(null)` errors) and only worked for some apps.

## 1.0.11

### New Features

- **Dictation language switcher** — Opt-in feature that adds two language tiles at the start of the Orbit ring. Click a tile to switch the macOS Dictation language and immediately start dictation in the focused text field. Configure your two languages in the new Dictation settings tab (pick from the languages you've already enabled in System Settings → Keyboard → Dictation). Requires a real keyboard shortcut for Dictation — the default "Press Fn twice" cannot be triggered programmatically.

## 1.0.10

### Bug Fixes

- **Fixed mouse trigger in Zen browser** — Removed overly aggressive `AXWindow` suppression that blocked the mouse trigger across the entire content area of Firefox/Zen-based browsers. Tab/link suppression still works in Safari and Chrome.

## 1.0.9

### Improvements

- **Smart mouse trigger suppression** — When using a mouse button as the trigger, Orbit now detects if the cursor is over a browser tab or link and suppresses activation. This prevents conflicts with middle-click-to-close-tab and middle-click-to-open-in-new-tab actions in Safari, Chrome, and Firefox/Zen browsers.

## 1.0.8

### Improvements

- Added screenshot to README

## 1.0.7

### New Features

- **Check for Updates** — New menu item lets you manually check for newer releases at any time. Shows an alert if you're already up to date.

## 1.0.6

### Improvements

- Added author info and GitHub repo link to the About panel
- Updated README with author section and architecture details
- License changed to GPL-3.0

## 1.0.5

### New Features

- **Update checker** — Orbit now checks for new releases on GitHub at launch. When a newer version is available, an "Update Available" item appears at the top of the menu bar menu, linking directly to the download page.

## 1.0.4

### Bug Fixes

- **Edge activation** — Fixed accidental activation when the cursor starts near the ring edge on open. The mouse must now enter the ring before outward movement can trigger a switch.

## 1.0.3

### New Features

- **Pinned apps** — Pin your most-used apps to fixed positions in the ring for muscle memory. Pinned apps always appear first, in your chosen order. Drag to reorder in the new "Pinned" tab in Settings.

### Improvements

- Improved overlay readability on light backgrounds (subtle dark underlay + text shadow)

## 1.0.2

### New Features

- **Edge activation** — Move the cursor to the edge of the ring to automatically switch to the selected app. No click needed. Toggled off by default in Settings.

### Improvements

- Author info and website link in the About panel

## 1.0.1

### New Features

- **Mouse/Trackpad input mode** — Choose between Mouse and Trackpad interaction styles in Settings. Trackpad mode provides larger icons, a bigger orbit ring, and sticky selection that persists when the cursor leaves the panel.
- **"Both" activation mode** — Use a keyboard shortcut and mouse button simultaneously. No need to choose one or the other.
- **Scroll-to-rotate** — Two-finger swipe or scroll wheel rotates the highlight around the ring (works in both input modes).
- **Arrow key navigation** — Left/Right arrow keys cycle through apps, Enter confirms selection.

### Improvements

- Interruptible spring animation for smooth rapid selection changes
- Momentum scroll filtering prevents unintended coasting after trackpad swipe
- Menu bar now shows the current activation method and input mode
- Settings window enlarged to fit all options without scrolling
- Toggle debounce prevents double-fire when both triggers are active

### Code Quality

- Key codes use Carbon constants (`kVK_Escape`, etc.) instead of magic numbers
- Defensive `deinit` cleanup on OrbitViewModel
- ShortcutRecorderView cleans up monitors on disappear
- HotkeyService refactored with targeted unregister helpers

## 1.0.0

- Initial release
