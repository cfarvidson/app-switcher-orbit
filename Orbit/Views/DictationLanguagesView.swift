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
