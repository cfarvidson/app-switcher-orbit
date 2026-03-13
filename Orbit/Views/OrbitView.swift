import SwiftUI

struct OrbitView: View {
    @ObservedObject var viewModel: OrbitViewModel

    var body: some View {
        ZStack {
            if viewModel.isVisible {
                // Background blur circle (tap to dismiss)
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

                // App icons arranged in circle
                ForEach(Array(viewModel.apps.enumerated()), id: \.element.id) { index, app in
                    let position = viewModel.positionForIndex(index)
                    let isSelected = viewModel.selectedIndex == index

                    AppIconView(app: app, isSelected: isSelected, size: viewModel.iconSize)
                        .position(position)
                        .onTapGesture {
                            viewModel.selectedIndex = index
                            viewModel.selectAndSwitch()
                        }
                }

                // Selected app name at center
                if let index = viewModel.selectedIndex, index < viewModel.apps.count {
                    Text(viewModel.apps[index].name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
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
