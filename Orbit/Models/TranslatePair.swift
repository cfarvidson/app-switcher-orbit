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
