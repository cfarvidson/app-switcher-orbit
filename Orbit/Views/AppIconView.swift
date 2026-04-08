import SwiftUI

struct AppIconView: View {
    let app: RunningApp
    let isSelected: Bool
    let size: CGFloat
    var isAnchored: Bool = false

    /// Anchored (pinned) items render 20% larger so the user's curated apps
    /// are visually weightier than the transient running-app crowd.
    private var effectiveSize: CGFloat {
        isAnchored ? size * 1.2 : size
    }

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: app.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
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
        }
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }
}
