import SwiftUI

struct OrbitView: View {
    @ObservedObject var viewModel: OrbitViewModel

    var body: some View {
        ZStack {
            if viewModel.isVisible {
                // Background blur circle (tap to dismiss)
                Circle()
                    .fill(Color.black.opacity(0.15))
                    .frame(width: viewModel.orbitSize - 40, height: viewModel.orbitSize - 40)
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: viewModel.orbitSize - 40, height: viewModel.orbitSize - 40)
                    .opacity(0.9)
                    .onTapGesture { viewModel.dismiss() }

                // Inner ring
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    .frame(width: viewModel.radius * 2, height: viewModel.radius * 2)

                // Center dot
                Circle()
                    .fill(Color.white.opacity(0.4))
                    .frame(width: 6, height: 6)

                // Selection indicator line
                if let index = viewModel.selectedIndex {
                    let pos = viewModel.positionForIndex(index)
                    Path { path in
                        path.move(to: viewModel.center)
                        path.addLine(to: pos)
                    }
                    .stroke(
                        Color.accentColor.opacity(0.4),
                        style: StrokeStyle(lineWidth: 2, dash: [4, 4])
                    )
                }

                // Items (apps + dictation languages) arranged in circle
                ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                    let position = viewModel.positionForIndex(index)
                    let isSelected = viewModel.selectedIndex == index

                    Group {
                        switch item {
                        case .app(let app):
                            AppIconView(app: app, isSelected: isSelected, size: viewModel.iconSize)
                        case .language(let language):
                            LanguageTileView(language: language, isSelected: isSelected, size: viewModel.iconSize)
                        }
                    }
                    .position(position)
                    .onTapGesture {
                        viewModel.selectedIndex = index
                        viewModel.selectAndSwitch()
                    }
                }

                // Selected item label at center
                if let index = viewModel.selectedIndex, index < viewModel.items.count {
                    Text(viewModel.items[index].displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .shadow(color: .black.opacity(0.2), radius: 4)
                        )
                        .offset(y: 20)
                }
            }
        }
        .frame(width: viewModel.orbitSize, height: viewModel.orbitSize)
        .animation(.easeOut(duration: 0.2), value: viewModel.isVisible)
        .animation(.interpolatingSpring(stiffness: 300, damping: 25), value: viewModel.selectedIndex)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                viewModel.updateSelection(mouseInView: location)
            case .ended:
                viewModel.handleHoverEnded()
            }
        }
    }
}
