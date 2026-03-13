# Changelog

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
