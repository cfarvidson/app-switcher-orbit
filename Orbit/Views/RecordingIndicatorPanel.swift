import AppKit
import SwiftUI

/// Floating non-activating panel that appears near the cursor while
/// `SpeechRecognitionService` is preparing or recording. Has three visible
/// states: `loading` (speech model still being loaded/downloaded),
/// `starting` (model ready, waiting for the first audio buffer to confirm
/// the engine is actually capturing), and `listening` (audio flowing).
/// Click anywhere on the panel to stop.
final class RecordingIndicatorPanel: NSPanel {
    enum State: Equatable {
        case loading(message: String)
        case starting
        case listening
    }

    private var hostingView: NSHostingView<RecordingIndicatorView>?
    private var model: RecordingIndicatorModel?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
    }

    // Must be able to become key to receive mouse clicks. Combined with
    // .nonactivatingPanel this means: panel receives clicks but doesn't
    // steal app focus from the user's text-editing context.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(
        state: State,
        onStopTapped: @escaping () -> Void
    ) {
        let model = RecordingIndicatorModel(state: state)
        self.model = model
        let view = RecordingIndicatorView(model: model, onStop: onStopTapped)
        let host = NSHostingView(rootView: view)
        contentView = host
        hostingView = host

        // Anchor ~30pt below the current cursor; clamp into the visible
        // screen so we don't end up off-screen near a corner.
        let mouse = NSEvent.mouseLocation
        let size = NSSize(width: 220, height: 64)
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 16)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
            origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - size.height - 8))
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
        orderFrontRegardless()
    }

    /// Update the indicator state in place (e.g. flip from `loading` to
    /// `listening` once the model is ready). Cheap — just mutates the
    /// observable model the SwiftUI view is watching.
    func updateState(_ state: State) {
        model?.state = state
    }

    func hideIndicator() {
        orderOut(nil)
    }
}

/// Observable view-model so the indicator can flip from `loading` to
/// `listening` without rebuilding the SwiftUI view tree.
final class RecordingIndicatorModel: ObservableObject {
    @Published var state: RecordingIndicatorPanel.State

    init(state: RecordingIndicatorPanel.State) {
        self.state = state
    }
}

private struct RecordingIndicatorView: View {
    @ObservedObject var model: RecordingIndicatorModel
    let onStop: () -> Void
    @State private var pulse: Bool = false

    private var isLoading: Bool {
        switch model.state {
        case .loading, .starting: return true
        case .listening: return false
        }
    }

    private var statusText: String {
        switch model.state {
        case .loading(let message): return message
        case .starting: return "Starting\u{2026}"
        case .listening: return "Listening\u{2026}"
        }
    }

    private var hintText: String {
        switch model.state {
        case .loading: return "First-time download \u{2014} please wait"
        case .starting: return "Almost ready\u{2026}"
        case .listening: return "Click or press ESC to stop"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isLoading ? Color.gray.opacity(pulse ? 0.5 : 0.2) : Color.red.opacity(pulse ? 0.6 : 0.25))
                    .frame(width: 28, height: 28)
                switch model.state {
                case .loading:
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                case .starting, .listening:
                    Image(systemName: "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .scaleEffect(pulse ? 1.08 : 1.0)
            .animation(
                .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                value: pulse
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(hintText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 220, height: 64)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.25), radius: 8)
        )
        .contentShape(Rectangle())
        .onTapGesture { onStop() }
        .onAppear { pulse = true }
    }
}
