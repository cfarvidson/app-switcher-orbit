import SwiftUI

/// Ring tile representing a dictation language. Visually mirrors
/// `AppIconView` so app and language tiles feel consistent in the ring:
/// same rounded-rect shape, selection glow, stroke, and scale.
struct LanguageTileView: View {
    let language: DictationLanguage
    let isSelected: Bool
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.ultraThinMaterial)
            .overlay(
                Text(language.flagEmoji)
                    .font(.system(size: size * 0.7))
            )
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                Text(localeCodeBadge)
                    .font(.system(size: size * 0.22, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .padding(4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(
                color: isSelected ? Color.accentColor.opacity(0.8) : .clear,
                radius: isSelected ? 12 : 0
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
            )
            .scaleEffect(isSelected ? 1.25 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: isSelected)
    }

    /// Uppercased language subtag — "en_US" → "EN", "zh-Hans_CN" → "ZH".
    private var localeCodeBadge: String {
        guard let first = language.id.split(separator: "_").first else { return "" }
        let langSubtag = first.split(separator: "-").first.map(String.init) ?? String(first)
        return langSubtag.uppercased()
    }
}
