import SwiftUI

/// Ring tile that starts dictation. Visually mirrors `AppIconView` so app
/// and dictation tiles feel consistent in the ring: same rounded-rect shape,
/// selection glow, stroke, and scale.
struct DictationTileView: View {
    let isSelected: Bool
    let size: CGFloat
    var isAnchored: Bool = true

    /// The dictation tile is always anchored (that is how it gets into the
    /// ring). The flag is threaded through for consistency with
    /// `AppIconView` and so the layout preview can render mock tiles.
    private var effectiveSize: CGFloat {
        isAnchored ? size * 1.2 : size
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.ultraThinMaterial)
            .overlay(
                Image(systemName: "mic.fill")
                    .font(.system(size: effectiveSize * 0.5, weight: .medium))
                    .foregroundStyle(.primary)
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
