# Dictation language scope

Date: 2026-08-12
Status: approved, ready for implementation planning

## Problem

Parakeet TDT 0.6B v3 detects the spoken language on its own, across 25+
European languages. In practice it sometimes decides that Swedish speech is
Russian and pastes Cyrillic gibberish: a real session produced
`flushed transcript=Неуфумкара.` and injected it into the frontmost app. There is
currently no way to tell Orbit which languages the user actually speaks.

## What the underlying API actually offers

This shapes the whole design, so it is stated before the design itself.

`AsrManager.transcribe(_:decoderState:language:)` already accepts
`language: Language?`. Two facts about it matter:

1. **It filters by script, not by language.** `TokenLanguageFilter` partitions
   FluidAudio's `Language` enum into three `Script` cases - `.latin`,
   `.cyrillic`, `.greek` - and skips top-K decoder tokens whose script does not
   match. There is no mechanism for "English and Swedish but not German". The
   filter's own doc comment says it "partitions by Unicode script
   (Latin/Cyrillic) only". A per-language allowlist is noted there as possible
   future work upstream.

2. **A non-English Latin language additionally triggers an English blocklist.**
   `TdtDecoderV3` runs `applyEnglishBlocklist` when
   `lang.script == .latin && lang != .english`, replacing blocklisted English
   tokens with the best non-English Latin candidate. Passing `.swedish` would
   therefore actively suppress English words - wrong for a user who switches
   between Swedish and English mid-sentence.

Consequence: for a bilingual Swedish/English user, the correct hint is
`.english`. It yields Latin-script filtering with no English suppression, so
Swedish passes through untouched and Cyrillic cannot be emitted.

The hint is a v3-only feature and is silently ignored on other model variants.
Orbit only ships v3, so this is not a concern here.

## Part 1 - The setting

```swift
@Published var dictationLanguages: Set<String>   // ISO codes, e.g. ["en", "sv"]
```

Codes match FluidAudio's `Language.rawValue` exactly, so the mapping is a plain
`Language(rawValue:)` lookup with no translation table to drift.

UserDefaults key: `dictationLanguages`, storing a `[String]`. New key, so no
migration.

**Never-configured and deliberately-empty must stay distinguishable**, or the
user cannot turn filtering off:

- Key absent: seed from `Locale.preferredLanguages`, keeping only codes Parakeet
  supports, and save the result. Compare on the language subtag only, so
  `sv-SE` matches `sv` and `en-GB` matches `en`. If nothing matches, store an
  empty array - the seeding attempt happened and must not repeat.
- Key present but empty: the user cleared it. No filtering.

This mirrors the existing `object(forKey:) != nil` pattern already used in
`SettingsService` for its other optional values.

## Part 2 - Mapping the selection onto the hint

A dedicated type, because this is the only logic-dense part of the feature:

```swift
// Orbit/Models/DictationLanguageScope.swift
enum DictationLanguageScope {
    static func hint(for codes: Set<String>) -> Language?
}
```

Rules, in order:

1. Map each code through `Language(rawValue:)`, discarding unknown codes.
2. Empty result: return `nil`. No filtering.
3. The selected languages span more than one `Script`: return `nil`. No hint can
   express a mixed-script selection, and silently picking one of them would
   discard half the user's answer. No filtering is the honest fallback, and the
   UI says so explicitly (Part 3).
4. All `.latin` and the set contains `.english`: return `.english`. Latin
   filtering, no English blocklist.
5. All `.latin` without `.english`: return the selected language with the
   lowest `rawValue`. This does apply the English blocklist, which is correct
   precisely because the user did not select English.
6. All `.cyrillic`: return the selected language with the lowest `rawValue`. The
   blocklist only applies to Latin, so the choice within the script is
   immaterial - lowest `rawValue` is chosen for determinism.
7. All `.greek`: return `.greek`.

Sorting by `rawValue` in rules 5 and 6 exists solely to make the result
deterministic for a given selection.

The function is pure and total: every input returns either a `Language` or
`nil`, and it never throws.

`Language` is a very generic name to bring into scope from `import FluidAudio`.
If it collides with anything, qualify it as `FluidAudio.Language` rather than
renaming or shadowing it.

## Wiring

Two call sites transcribe, both in `SpeechRecognitionService`:

- `stop(reason:flushBuffer:)`, the final flush (currently line 462)
- `flushAndTranscribe()`, the mid-session VAD flush (currently line 786)

Both change from

```swift
try await manager.transcribe(snapshot, decoderState: &decoderState)
```

to

```swift
try await manager.transcribe(
    snapshot,
    decoderState: &decoderState,
    language: DictationLanguageScope.hint(for: SettingsService.shared.dictationLanguages)
)
```

The hint is computed per flush rather than cached per session. It is a set
lookup over at most 28 elements, and computing it fresh means a settings change
takes effect immediately instead of at the next session.

## Part 3 - Settings UI

A new `Orbit/Views/DictationLanguagesView.swift`. `SettingsView` is already 447
lines and this is a self-contained piece of UI with its own state.

It sits in the Dictation tab below the pause-tolerance slider, as a
`DisclosureGroup` collapsed by default, with the current selection summarised on
the row:

```
Languages                                English, Swedish  v

  Latin
  [x] English    [ ] German     [ ] Polish     [ ] Czech
  [x] Swedish    [ ] Danish     [ ] Finnish    [ ] Dutch
  ...
  Cyrillic
  [ ] Russian    [ ] Ukrainian  [ ] Bulgarian  ...
  Greek
  [ ] Greek
```

Languages are grouped under their script. The grouping is the explanation, not
decoration: seeing Russian under a separate heading is what makes it obvious why
Swedish plus Russian cannot be filtered.

The caption states what the setting does rather than what a user might hope:
Parakeet detects language on its own, and this stops it emitting text in the
wrong alphabet. It does not make Parakeet more accurate in the selected
languages.

**Mixed-script selections must be visible.** When the selection spans more than
one script, filtering is off, and a line appears directly under the group:
"Mixed alphabets selected - filtering is off. Parakeet may emit any script."
Without it the control looks active while doing nothing.

Selection changes call `settings.save()`, matching every other control in this
tab.

The summary on the collapsed row lists the selected languages by display name,
or "None (no filtering)" when the selection is empty.

## Verification

The project has no test target and this design does not add one, consistent with
the rest of the codebase. Verification is `./build.sh` plus:

- Dictate Swedish with English and Swedish selected. Output is Latin script.
  Repeat several utterances - the pre-existing Cyrillic misfire was
  intermittent, so a single clean result is not evidence.
- Dictate an English sentence with the same selection. English words are not
  mangled, confirming no blocklist is applied.
- Select Swedish only, dictate English, and confirm the English blocklist is
  active. This is the observable difference between rules 4 and 5.
- Select Swedish and Russian together and confirm the mixed-alphabet notice
  appears and filtering is off.
- Clear the selection entirely, relaunch, and confirm it stays cleared rather
  than re-seeding from the system languages.
- On a machine that has never run this build, confirm the seed picks up the
  macOS languages.

Log evidence: `[Orbit.speech] flushed transcript=` shows what the model
produced. That is the line to watch.

## Out of scope

- Per-language token allowlists. The upstream filter is script-level; anything
  finer would mean patching FluidAudio.
- Improving recognition accuracy for a selected language. The hint only
  constrains the alphabet.
- Any change to the menu bar, ring layout or Escape handling from the branch
  this builds on.

## Documentation

`SPEC.md` needs a new subsection under `## SpeechRecognitionService` covering the
setting, the script-level mechanism, and the mapping rules, plus the
`SettingsService` stored-properties table and the Dictation tab description.
`CHANGELOG.md` gets an entry.
