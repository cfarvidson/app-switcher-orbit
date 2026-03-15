# Changelog

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
