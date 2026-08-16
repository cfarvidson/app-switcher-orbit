# Orbit

Native macOS menu-bar app (`LSUIElement`). Swift 5.9, SwiftUI + AppKit, XcodeGen. Not sandboxed. Bundle id `com.orbit.appswitcher`.

## Spec

After making changes to the codebase, update `SPEC.md` to reflect the current state of the app. The spec should be complete enough that an LLM could rebuild the entire app from it alone. If you add, remove, or change any file, behavior, setting, or UI element, update the corresponding section in `SPEC.md` before committing.

## Project file

`project.yml` is the source of truth. After any change to it, regenerate:

```
xcodegen generate
```

Do not hand-edit `Orbit.xcodeproj` except as the output of that command. `MARKETING_VERSION` lives in `project.yml`; the pbxproj copies are generated.

## Test

```
./test.sh
```

`OrbitTests` is a unit-test bundle that compiles `Orbit/Models` plus the tests. It does **not** host `Orbit.app`. Current coverage: `RingLayout` and `DictationLanguageScope`. There is no CI.

## Build and run locally

```
./build.sh
open Orbit.app
```

Release build, then copies `Orbit.app` to the repo root. The app is gitignored. It is a menu-bar app: no Dock icon, look for the dotted circle.

## Signing

Always Developer ID, never ad-hoc:

- Identity: `Developer ID Application: Arvidson Tech AB (D3LY7SL2HW)`
- Team: `D3LY7SL2HW`
- Style: Manual

Ad-hoc (`CODE_SIGN_IDENTITY: "-"`) makes TCC store the cdhash. Every `./build.sh` then silently kills Accessibility: the Carbon hotkey still works, but `CGEvent.post` (dictation Cmd+V) and the Escape tap are filtered. The Settings toggle does not repair a stale entry.

Verify after a build:

```
codesign -d -r- Orbit.app
```

The requirement must be identity-based (`identifier "com.orbit.appswitcher"` + `subject.OU` = `D3LY7SL2HW`), not cdhash-based.

`OrbitTests` is the exception: it signs ad-hoc on purpose.

Debugging TCC: `log` is shadowed in this user's zsh. Use `/usr/bin/log`. The real paste-failure tell is `inject pre-flight: ... axTrusted=false`.

## Release

Distribution is GitHub Releases only. Not the Mac App Store. `UpdateService` GETs `https://api.github.com/repos/cfarvidson/app-switcher-orbit/releases/latest` and compares `tag_name` to `CFBundleShortVersionString`.

A version is not shipped until a GitHub release exists. Bumping `MARKETING_VERSION` alone does nothing for users.

Checklist:

1. Move `CHANGELOG.md` `## Unreleased` into `## X.Y.Z`. If that version was never published, fold new work into it instead of inventing X.Y.Z+1.
2. Set `MARKETING_VERSION` in `project.yml`, then `xcodegen generate`.
3. Update `SPEC.md`.
4. `./test.sh` and `./build.sh`.
5. Confirm the built app's version: `/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Orbit.app/Contents/Info.plist`
6. Confirm Hardened Runtime and no `get-task-allow`: `codesign -dv --verbose=4 Orbit.app` should show `flags=0x10000(runtime)`. `codesign -d --entitlements - Orbit.app` must not list `get-task-allow`.
7. Notarize (required for GitHub downloads; otherwise Gatekeeper shows "Apple could not verify Orbit.app"):

```
# one-time, app-specific password from appleid.apple.com
xcrun notarytool store-credentials orbit-notary \
  --apple-id carl-fredrik@arvidson.io \
  --team-id D3LY7SL2HW
./notarize.sh
```

8. Zip the **stapled** app (do not commit the zip; `Orbit-*.zip` is gitignored):

```
ditto -c -k --keepParent Orbit.app Orbit-X.Y.Z.zip
```

9. Commit, push `main`.
10. Publish:

```
gh release create vX.Y.Z Orbit-X.Y.Z.zip \
  --title "Orbit vX.Y.Z" \
  --notes-file <changelog-excerpt>
```

Release notes should be the `## X.Y.Z` CHANGELOG section (that is what v1.1.0 used). After publish, the in-app "Update Available" item appears on the next check.

Do not ship a GitHub zip that has not been notarized. v2.2.0 was signed but not notarized; Gatekeeper blocks the download. Local `./build.sh` + `open Orbit.app` is fine (no quarantine). A quarantined download needs a staple.

Release config: `ENABLE_HARDENED_RUNTIME=YES`, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`, `--timestamp`. Entitlements: sandbox off, `com.apple.security.device.audio-input` on.

## Do not

- Rename UserDefaults keys `pinnedAngles` / `dictationAngle`. The Swift properties are `pinnedPreferredAngles` / `dictationPreferredAngle`; the key mismatch is load-bearing so upgrades keep the user's layout.
- Reintroduce the macOS DictationIM path or auto-delete the old WhisperKit cache under `~/Documents/huggingface/`.
- Bump FluidAudio off `exactVersion: 0.15.5` unless a newer **tag** exists. 0.15.5 is current.
- Treat `npx prettier` as the Swift formatter. There is no `package.json`. Prettier does not format Swift.

## Launch after rebuild

Orbit is already a menu-bar agent. Quit the old process before `open Orbit.app`, or you will have two status items.
