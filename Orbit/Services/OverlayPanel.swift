import AppKit
import SwiftUI

final class OverlayPanel: NSPanel {
    init<Content: View>(contentView: Content) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true

        let hostingView = NSHostingView(rootView: contentView)
        self.contentView = hostingView
    }

    func showOverlay(at point: CGPoint, size: CGFloat) {
        var frame = NSRect(
            x: point.x - size / 2,
            y: point.y - size / 2,
            width: size,
            height: size
        )

        // Clamp to visible screen bounds
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - size))
            frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - size))
        }

        setFrame(frame, display: true)
        orderFrontRegardless()
        makeKey()
    }

    func hideOverlay() {
        orderOut(nil)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
