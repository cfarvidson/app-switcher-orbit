# Dictation Language Scope Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user pick which languages they speak, so Parakeet stops emitting Cyrillic when they dictate Swedish.

**Architecture:** A new `Set<String>` of ISO codes in `SettingsService`, seeded once from the macOS language list. A pure mapping function turns that selection into FluidAudio's single `Language?` hint, which is script-level rather than language-level. A self-contained SwiftUI view in the Dictation tab edits the set.

**Tech Stack:** Swift 5.9, SwiftUI + AppKit, macOS 14 deployment target, xcodegen (`project.yml`), FluidAudio 0.15.5.

## Global Constraints

- Deployment target is macOS 14.0. Do not use API newer than that.
- The project has **no test target** and this plan does not add one. Every task is verified by `./build.sh` plus the manual checks written into that task.
- Build with `./build.sh` from the repo root.
- Run `npx prettier --write .` before every commit.
- Never use em dashes in code comments or user-facing copy; use a plain hyphen.
- Adding a new `.swift` file requires `xcodegen generate` and committing the regenerated `Orbit.xcodeproj/project.pbxproj`. `./build.sh` builds through the `.xcodeproj`, so a new file without a regenerated project will not compile in.
- The UserDefaults key for the new setting is `dictationLanguages`. It is new, so there is nothing to migrate, but do not rename existing keys - `pinnedAngles` and `dictationAngle` deliberately differ from their Swift property names.
- `Language` is FluidAudio's enum, brought in by `import FluidAudio`. If the bare name collides, qualify it as `FluidAudio.Language` rather than shadowing it.

## Reference: the language set

FluidAudio's `Language` enum, grouped by the `script` it maps to. The implementation must not hardcode this grouping - read it from `Language.script` - but the plan lists it so you can check your work.

- **Latin (22):** en, es, fr, de, it, pt, ro, nl, da, sv, fi, hu, et, lv, lt, mt, pl, cs, sk, sl, hr, bs
- **Cyrillic (5):** ru, uk, be, bg, sr
- **Greek (1):** el

---

### Task 1: `DictationLanguageScope` mapping function

**Files:**

- Create: `Orbit/Models/DictationLanguageScope.swift`
- Modify: `Orbit.xcodeproj/project.pbxproj` (regenerated)

**Interfaces:**

- Consumes: `FluidAudio.Language` (public enum, `String` raw values, `CaseIterable`) and its `script: Script` property (`.latin` / `.cyrillic` / `.greek`).
- Produces: `DictationLanguageScope.hint(for codes: Set<String>) -> Language?` and `DictationLanguageScope.supportedCodes: Set<String>`. Tasks 2, 3 and 4 use both.

- [ ] **Step 1: Create the file**

```swift
import FluidAudio
import Foundation

/// Translates the user's selected dictation languages into the single
/// `Language?` hint FluidAudio's decoder accepts.
///
/// The underlying filter is script-level, not language-level: it partitions
/// languages into Latin / Cyrillic / Greek and skips decoder tokens whose
/// script does not match. There is no way to express "English and Swedish but
/// not German", so this maps a set onto the one value that best represents it.
///
/// The subtlety that drives the rules below: `TdtDecoderV3` additionally runs
/// an English blocklist whenever the hint is a Latin language other than
/// English, actively replacing English tokens. That is right for someone who
/// never speaks English and wrong for someone who code-switches, so English
/// wins the tie whenever it is selected.
enum DictationLanguageScope {

    /// Every language code Parakeet supports.
    static var supportedCodes: Set<String> {
        Set(Language.allCases.map(\.rawValue))
    }

    /// The hint for a selection, or nil when no filtering should apply.
    static func hint(for codes: Set<String>) -> Language? {
        let languages = codes.compactMap { Language(rawValue: $0) }
        guard !languages.isEmpty else { return nil }

        // A mixed-script selection has no representable hint. Picking one
        // script would silently discard half the user's answer, so filtering
        // is switched off instead. The Settings UI says so explicitly.
        let scripts = Set(languages.map(\.script))
        guard scripts.count == 1, let script = scripts.first else { return nil }

        switch script {
        case .latin:
            // English suppresses nothing; any other Latin language triggers
            // the decoder's English blocklist.
            if languages.contains(.english) { return .english }
            return languages.min { $0.rawValue < $1.rawValue }
        case .cyrillic, .greek:
            // The blocklist is Latin-only, so the choice within the script
            // does not affect behavior. Sorted for determinism.
            return languages.min { $0.rawValue < $1.rawValue }
        }
    }
}
```

- [ ] **Step 2: Regenerate the Xcode project**

Run: `xcodegen generate`
Expected: `Created project at .../Orbit.xcodeproj`

- [ ] **Step 3: Build**

Run: `./build.sh`
Expected: `** BUILD SUCCEEDED **` then `Copied to ./Orbit.app`

If `Language` fails to resolve, qualify it as `FluidAudio.Language` throughout the file. Do not rename it or define a local alias.

- [ ] **Step 4: Verify the mapping by reasoning, and record it**

There is no test target, so work these six cases on paper and write the results into your report. Each must match:

| selection      | expected result | why                                                 |
| -------------- | --------------- | --------------------------------------------------- |
| `[]`           | `nil`           | nothing selected                                    |
| `["zz"]`       | `nil`           | unknown code, drops to empty                        |
| `["en", "sv"]` | `.english`      | all Latin, English present                          |
| `["sv", "da"]` | `.danish`       | all Latin, no English, lowest rawValue of `da`/`sv` |
| `["sv", "ru"]` | `nil`           | mixed Latin and Cyrillic                            |
| `["ru", "uk"]` | `.russian`      | all Cyrillic, lowest rawValue                       |

- [ ] **Step 5: Commit**

```bash
npx prettier --write .
git add Orbit/Models/DictationLanguageScope.swift Orbit.xcodeproj/project.pbxproj
git commit -m "feat: map selected dictation languages onto FluidAudio's script hint"
```

---

### Task 2: `dictationLanguages` setting with first-run seeding

**Files:**

- Modify: `Orbit/Services/SettingsService.swift`

**Interfaces:**

- Consumes: `DictationLanguageScope.supportedCodes` from Task 1.
- Produces: `SettingsService.shared.dictationLanguages: Set<String>`, a `@Published` property persisted under the UserDefaults key `dictationLanguages`. Tasks 3 and 4 read it.

- [ ] **Step 1: Add the published property**

In `Orbit/Services/SettingsService.swift`, below `@Published var dictationInputDeviceUID: String?`:

```swift
@Published var dictationLanguages: Set<String>
```

- [ ] **Step 2: Load or seed it in `init`**

In `private init()`, below the `dictationInputDeviceUID` line:

```swift
// Distinguish "never configured" from "deliberately cleared". A missing
// key means first run, so seed from the languages macOS says the user
// reads. An empty stored array means the user unchecked everything, and
// must stay empty - re-seeding would make it impossible to turn the
// filter off.
if let stored = defaults.array(forKey: "dictationLanguages") as? [String] {
    dictationLanguages = Set(stored)
} else {
    dictationLanguages = SettingsService.seedLanguagesFromSystem()
    defaults.set(Array(dictationLanguages), forKey: "dictationLanguages")
}
```

- [ ] **Step 3: Add the seeding helper**

Below the existing `loadAngleDict` helper:

```swift
/// Languages to preselect on first run: whatever macOS reports the user
/// reads, narrowed to what Parakeet supports. `Locale.preferredLanguages`
/// returns tags like "sv-SE" and "en-GB", so compare on the language
/// subtag only. Returns an empty set when nothing matches, which is stored
/// as such so the seeding is not attempted again.
private static func seedLanguagesFromSystem() -> Set<String> {
    let supported = DictationLanguageScope.supportedCodes
    var result: Set<String> = []
    for tag in Locale.preferredLanguages {
        let subtag = String(tag.prefix(while: { $0 != "-" && $0 != "_" })).lowercased()
        if supported.contains(subtag) {
            result.insert(subtag)
        }
    }
    return result
}
```

- [ ] **Step 4: Persist it in `save()`**

In `save()`, below the `dictationInputDeviceUID` block:

```swift
defaults.set(Array(dictationLanguages), forKey: "dictationLanguages")
```

- [ ] **Step 5: Build**

Run: `./build.sh`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Verify the seed**

Run: `defaults read com.orbit.appswitcher dictationLanguages`

Expected on this machine: an array containing at least `sv` and `en`, because macOS reports Swedish and English. The exact contents depend on System Settings, so what matters is that the key now exists and holds only codes from the supported list.

Then confirm the cleared state survives:

```bash
defaults write com.orbit.appswitcher dictationLanguages -array
open ./Orbit.app
```

Quit Orbit, then run `defaults read com.orbit.appswitcher dictationLanguages` again. Expected: still empty. If it re-seeded, the `object(forKey:)` distinction is wrong.

Restore your real selection afterwards by deleting the key and relaunching:
`defaults delete com.orbit.appswitcher dictationLanguages`

- [ ] **Step 7: Commit**

```bash
npx prettier --write .
git add Orbit/Services/SettingsService.swift
git commit -m "feat: store selected dictation languages, seeded from system languages"
```

---

### Task 3: Pass the hint to the decoder

**Files:**

- Modify: `Orbit/Services/SpeechRecognitionService.swift` (two call sites)

**Interfaces:**

- Consumes: `DictationLanguageScope.hint(for:)` from Task 1 and `SettingsService.shared.dictationLanguages` from Task 2.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add the hint to the final flush**

In `stop(reason:flushBuffer:)`, the call currently reading:

```swift
let result = try await manager.transcribe(finalSnapshot, decoderState: &decoderState)
```

becomes:

```swift
let result = try await manager.transcribe(
    finalSnapshot,
    decoderState: &decoderState,
    language: DictationLanguageScope.hint(for: SettingsService.shared.dictationLanguages)
)
```

- [ ] **Step 2: Add the hint to the mid-session flush**

In `flushAndTranscribe()`, the call currently reading:

```swift
let result = try await manager.transcribe(snapshot, decoderState: &decoderState)
```

becomes:

```swift
let result = try await manager.transcribe(
    snapshot,
    decoderState: &decoderState,
    language: DictationLanguageScope.hint(for: SettingsService.shared.dictationLanguages)
)
```

Compute the hint at the call site rather than caching it per session. It is a set lookup over at most 28 elements, and computing it fresh means a settings change takes effect on the next utterance instead of the next session.

- [ ] **Step 3: Log the hint so the effect is observable**

There is no test target, so the log is the only evidence this is wired up. In `flushAndTranscribe()`, immediately after the existing `NSLog("[Orbit.speech] flushing ...")` line, add:

```swift
NSLog("[Orbit.speech] language hint=\(String(describing: DictationLanguageScope.hint(for: SettingsService.shared.dictationLanguages)))")
```

- [ ] **Step 4: Build**

Run: `./build.sh`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Verify end to end**

Install and run the build, then stream the log:

```
/usr/bin/log stream --predicate 'process == "Orbit"' --style compact | grep -E "language hint|flushed transcript"
```

Note `/usr/bin/log` with the absolute path - `log` is shadowed by a shell function in this environment and the bare name returns nothing.

Dictate several Swedish sentences. Expected: `language hint=Optional(FluidAudio.Language.english)` and every `flushed transcript=` line in Latin script. Run several utterances - the Cyrillic misfire was intermittent, so one clean result proves nothing.

- [ ] **Step 6: Commit**

```bash
npx prettier --write .
git add Orbit/Services/SpeechRecognitionService.swift
git commit -m "feat: constrain transcription to the selected languages' script"
```

---

### Task 4: Language picker in Settings

**Files:**

- Create: `Orbit/Views/DictationLanguagesView.swift`
- Modify: `Orbit/Views/SettingsView.swift` (Dictation tab, after the pause-tolerance block)
- Modify: `Orbit.xcodeproj/project.pbxproj` (regenerated)

**Interfaces:**

- Consumes: `SettingsService.shared.dictationLanguages` from Task 2, `DictationLanguageScope` from Task 1.
- Produces: `DictationLanguagesView`, a `View` with no initialiser arguments.

- [ ] **Step 1: Create the view**

```swift
import FluidAudio
import SwiftUI

/// Lets the user say which languages they actually speak, so the decoder can
/// be told which alphabet to stay inside.
///
/// Languages are grouped by script because the grouping IS the explanation:
/// the underlying filter is script-level, so seeing Russian under its own
/// heading is what makes it obvious why Swedish plus Russian cannot be
/// filtered at all.
struct DictationLanguagesView: View {
    @ObservedObject var settings = SettingsService.shared
    @State private var isExpanded = false

    private let columns = [GridItem(.adaptive(minimum: 130), alignment: .leading)]

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Self.scriptGroups, id: \.name) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                            ForEach(group.languages, id: \.rawValue) { language in
                                Toggle(Self.displayName(language), isOn: binding(for: language))
                                    .toggleStyle(.checkbox)
                            }
                        }
                    }
                }

                if isMixedScript {
                    Text("Mixed alphabets selected - filtering is off. Parakeet may emit any script.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text("Parakeet detects the spoken language on its own. Selecting the languages you actually speak stops it writing in the wrong alphabet. It does not make it more accurate in those languages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text("Languages")
                Spacer()
                Text(summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    // MARK: - Selection

    private func binding(for language: Language) -> Binding<Bool> {
        Binding(
            get: { settings.dictationLanguages.contains(language.rawValue) },
            set: { isOn in
                if isOn {
                    settings.dictationLanguages.insert(language.rawValue)
                } else {
                    settings.dictationLanguages.remove(language.rawValue)
                }
                settings.save()
            }
        )
    }

    /// True when the selection spans more than one script, which is exactly
    /// when `DictationLanguageScope.hint` gives up and returns nil.
    private var isMixedScript: Bool {
        let scripts = Set(
            settings.dictationLanguages
                .compactMap { Language(rawValue: $0) }
                .map(\.script)
        )
        return scripts.count > 1
    }

    private var summary: String {
        let names = settings.dictationLanguages
            .compactMap { Language(rawValue: $0) }
            .map(Self.displayName)
            .sorted()
        return names.isEmpty ? "None (no filtering)" : names.joined(separator: ", ")
    }

    // MARK: - Static data

    private struct ScriptGroup {
        let name: String
        let languages: [Language]
    }

    /// Built from `Language.script` rather than a hardcoded list, so adding a
    /// language upstream cannot silently drop it from this picker.
    private static let scriptGroups: [ScriptGroup] = {
        let order: [(String, Script)] = [
            ("Latin", .latin), ("Cyrillic", .cyrillic), ("Greek", .greek),
        ]
        return order.compactMap { name, script in
            let languages = Language.allCases
                .filter { $0.script == script }
                .sorted { displayName($0) < displayName($1) }
            return languages.isEmpty ? nil : ScriptGroup(name: name, languages: languages)
        }
    }()

    /// Localized language name from the OS, so this never needs a hand-written
    /// table of 28 names to keep in sync.
    private static func displayName(_ language: Language) -> String {
        Locale.current.localizedString(forLanguageCode: language.rawValue)?.capitalized
            ?? language.rawValue.uppercased()
    }
}
```

- [ ] **Step 2: Add it to the Dictation tab**

In `Orbit/Views/SettingsView.swift`, the Dictation section currently ends with the pause-tolerance `VStack` (the one containing the `Slider` bound to `dictationSilenceTriggerSeconds`). Directly after that closing brace, still inside the same `Section`, add:

```swift
Divider()

DictationLanguagesView()
```

- [ ] **Step 3: Regenerate the Xcode project**

Run: `xcodegen generate`
Expected: `Created project at .../Orbit.xcodeproj`

- [ ] **Step 4: Build**

Run: `./build.sh`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Verify the picker**

Install and open Settings, Dictation tab.

- The "Languages" row shows your seeded selection, e.g. "English, Swedish".
- Expanding it shows three groups: Latin, Cyrillic, Greek. Counts are 22 / 5 / 1.
- Checking and unchecking updates the summary immediately.
- Check Russian while Swedish is checked. The orange mixed-alphabet notice appears.
- Uncheck Russian. The notice disappears.
- Uncheck everything. The summary reads "None (no filtering)".
- Quit and relaunch Orbit. The selection is exactly as you left it, including the empty case.

- [ ] **Step 6: Commit**

```bash
npx prettier --write .
git add Orbit/Views/DictationLanguagesView.swift Orbit/Views/SettingsView.swift Orbit.xcodeproj/project.pbxproj
git commit -m "feat: add a dictation language picker to Settings"
```

---

### Task 5: Documentation

**Files:**

- Modify: `SPEC.md`
- Modify: `CHANGELOG.md`

**Interfaces:**

- Consumes: everything from Tasks 1-4.
- Produces: nothing.

- [ ] **Step 1: Document the setting in `SPEC.md`**

In the `### Stored Properties` table under `## SettingsService`, add a row: property `dictationLanguages`, type `Set<String>`, default "seeded from `Locale.preferredLanguages`", UserDefaults key `dictationLanguages`.

Below the table, state that a missing key means first run and triggers seeding, while a present-but-empty array means the user cleared the selection and must not be re-seeded - and that this distinction is what makes it possible to turn filtering off at all.

- [ ] **Step 2: Add a `### Language scope` subsection under `## SpeechRecognitionService`**

Cover, reading the current source to get it right:

- `AsrManager.transcribe` takes a `language: Language?` hint that filters decoder tokens by **script** (Latin / Cyrillic / Greek), not by language. "English and Swedish but not German" is not expressible.
- `TdtDecoderV3` additionally applies an English blocklist when the hint is a Latin language other than English, replacing English tokens. This is why English wins the tie whenever it is selected.
- The mapping rules implemented in `DictationLanguageScope.hint(for:)`, in order: empty or unrecognised gives nil; mixed scripts give nil; all Latin containing English gives `.english`; all Latin without English gives the lowest `rawValue`; all Cyrillic gives the lowest `rawValue`; all Greek gives `.greek`.
- The hint is computed per flush at both transcribe call sites, so a settings change takes effect on the next utterance.

- [ ] **Step 3: Document the UI in the Dictation tab section**

Describe the `DisclosureGroup` labelled "Languages" with the selection summarised on the row, the three script groups, and the orange mixed-alphabet notice shown when the selection spans scripts.

- [ ] **Step 4: Add the CHANGELOG entry**

Directly below `# Changelog`, inside the existing `## 2.2.0` section's `### Changed` list, add:

```markdown
- Dictation can now be limited to the languages you actually speak. Parakeet detects language on its own and would occasionally decide Swedish was Russian, pasting Cyrillic gibberish into whatever you were typing in. Settings > Dictation > Languages now lets you pick your languages, and Orbit constrains the decoder to that alphabet. The list is preselected from your macOS language settings, so it works without being configured. Selecting languages from different alphabets turns filtering off, and the setting says so rather than looking active while doing nothing.
```

- [ ] **Step 5: Verify no stale claims**

Run: `grep -n "detects the spoken language\|language is detected\|automatically" SPEC.md | head`

Expected: any existing sentence claiming the language is detected automatically with no user control is either removed or now qualified by the new section. Fix any that still read as absolute.

- [ ] **Step 6: Build and commit**

Run: `./build.sh`
Expected: `** BUILD SUCCEEDED **`

```bash
npx prettier --write .
git add SPEC.md CHANGELOG.md
git commit -m "docs: document dictation language scope"
```
