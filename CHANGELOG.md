# Changelog

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
