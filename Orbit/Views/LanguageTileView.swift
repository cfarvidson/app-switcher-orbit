import SwiftUI

/// Ring tile representing a dictation language. Visually mirrors
/// `AppIconView` so app and language tiles feel consistent in the ring:
/// same rounded-rect shape, selection glow, stroke, and scale.
struct LanguageTileView: View {
    let language: DictationLanguage
    let isSelected: Bool
    let size: CGFloat
    var isAnchored: Bool = true

    /// Language tiles are almost always anchored (that's how the user puts
    /// them in the ring in the first place). The `isAnchored` flag is still
    /// threaded through for consistency with `AppIconView` and to let the
    /// Layout preview render non-anchored mock tiles if we ever need to.
    private var effectiveSize: CGFloat {
        isAnchored ? size * 1.2 : size
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.ultraThinMaterial)
            .overlay(
                Text(language.flagEmoji)
                    .font(.system(size: effectiveSize * 0.7))
            )
            .frame(width: effectiveSize, height: effectiveSize)
            .overlay(alignment: .bottomTrailing) {
                Text(localeCodeBadge)
                    .font(.system(size: effectiveSize * 0.22, weight: .bold))
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
