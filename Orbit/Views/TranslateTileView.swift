import SwiftUI

/// Ring tile representing a translate-dictation pair. Visually mirrors
/// `LanguageTileView` (same RoundedRectangle, ultraThinMaterial, selection
/// glow, stroke, scale) but renders TWO flags side-by-side with an arrow
/// between them so the source → target direction is unmistakable.
struct TranslateTileView: View {
    let pair: TranslatePair
    let isSelected: Bool
    let size: CGFloat
    var isAnchored: Bool = true

    /// Anchored translate tiles get the same 1.2x size boost as anchored
    /// language tiles for visual consistency in the ring.
    private var effectiveSize: CGFloat {
        isAnchored ? size * 1.2 : size
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.ultraThinMaterial)
            .overlay(
                // Flag/arrow proportions sum to ~0.98 of tile width so the
                // HStack doesn't get clipped — emoji glyphs typically render
                // 10–15% wider than their nominal font size, eating any
                // extra slack. Reduced from initial 0.42/0.22/0.06 which
                // overflowed at all ring sizes.
                HStack(spacing: effectiveSize * 0.05) {
                    Text(pair.source.flagEmoji)
                        .font(.system(size: effectiveSize * 0.34))
                    Image(systemName: "arrow.right")
                        .font(.system(size: effectiveSize * 0.20, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(pair.target.flagEmoji)
                        .font(.system(size: effectiveSize * 0.34))
                }
            )
            .frame(width: effectiveSize, height: effectiveSize)
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
}
