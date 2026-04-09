import AppKit
import SwiftUI

/// Floating non-activating panel that appears near the cursor while
/// `SpeechRecognitionService` is preparing or recording. Has two visible
/// states: `loading` (Whisper model still being loaded/downloaded) and
/// `listening` (audio capture active). Click anywhere on the panel to stop.
final class RecordingIndicatorPanel: NSPanel {
    enum State: Equatable {
        case loading(message: String)
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
        localeId: String,
        state: State,
        targetLocaleId: String? = nil,
        onStopTapped: @escaping () -> Void
    ) {
        let model = RecordingIndicatorModel(
            localeId: localeId,
            targetLocaleId: targetLocaleId,
            state: state
        )
        self.model = model
        let view = RecordingIndicatorView(model: model, onStop: onStopTapped)
        let host = NSHostingView(rootView: view)
        contentView = host
        hostingView = host

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
    /// `listening` once Whisper is ready). Cheap — just mutates the
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
    let localeId: String
    let targetLocaleId: String?
    @Published var state: RecordingIndicatorPanel.State

    init(localeId: String, targetLocaleId: String?, state: RecordingIndicatorPanel.State) {
        self.localeId = localeId
        self.targetLocaleId = targetLocaleId
        self.state = state
    }
}

private struct RecordingIndicatorView: View {
    @ObservedObject var model: RecordingIndicatorModel
    let onStop: () -> Void
    @State private var pulse: Bool = false

    private var flagEmoji: String {
        guard let region = model.localeId.split(separator: "_").last,
              region.count == 2
        else { return "🏳️" }
        let base: UInt32 = 127397
        var scalar = ""
        for ch in region.uppercased().unicodeScalars {
            if let combined = UnicodeScalar(base + ch.value) {
                scalar.unicodeScalars.append(combined)
            }
        }
        return scalar.isEmpty ? "🏳️" : scalar
    }

    private var targetFlagEmoji: String? {
        guard let targetLocaleId = model.targetLocaleId,
              let region = targetLocaleId.split(separator: "_").last,
              region.count == 2
        else { return nil }
        let base: UInt32 = 127397
        var scalar = ""
        for ch in region.uppercased().unicodeScalars {
            if let combined = UnicodeScalar(base + ch.value) {
                scalar.unicodeScalars.append(combined)
            }
        }
        return scalar.isEmpty ? nil : scalar
    }

    private var localeBadge: String {
        guard let first = model.localeId.split(separator: "_").first else { return "" }
        return (first.split(separator: "-").first.map(String.init) ?? String(first)).uppercased()
    }

    private var isLoading: Bool {
        if case .loading = model.state { return true }
        return false
    }

    private var statusText: String {
        switch model.state {
        case .loading(let message): return message
        case .listening: return "Listening…"
        }
    }

    private var hintText: String {
        switch model.state {
        case .loading: return "First-time download \u{2014} please wait"
        case .listening: return "Click or press ESC to stop"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isLoading ? Color.gray.opacity(pulse ? 0.5 : 0.2) : Color.red.opacity(pulse ? 0.6 : 0.25))
                    .frame(width: 28, height: 28)
                if isLoading {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
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
                HStack(spacing: 4) {
                    Text(flagEmoji)
                        .font(.system(size: 16))
                    if let targetFlag = targetFlagEmoji {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(targetFlag)
                            .font(.system(size: 16))
                    } else {
                        Text(localeBadge)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
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
