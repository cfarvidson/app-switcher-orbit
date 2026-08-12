import AppKit
import SwiftUI

/// Circular preview for positioning anchored items (pinned apps + the
/// dictation tile). The user drags each icon around a scaled-down ring and
/// the angle snaps to 15° increments on release. Writes back through
/// `SettingsService` so the layout persists.
struct LayoutPreviewView: View {
    @ObservedObject var settings = SettingsService.shared
    @State private var anchors: [Anchor] = []
    @State private var draggingId: String?
    @State private var dragAngle: Double = 0

    private let diameter: CGFloat = 280
    private let iconSize: CGFloat = 44
    private let snapIncrement: Double = 15
    private let collisionThreshold: Double = 5

    /// In-memory snapshot of an anchored item's current state. Each anchor
    /// carries both its persisted angle and an `id` that tells us which
    /// `SettingsService` dictionary to write back to.
    private struct Anchor: Identifiable, Equatable {
        enum Kind: Equatable { case pinnedApp, dictation }
        let id: String
        let kind: Kind
        var angleDegrees: Double
        let displayName: String
        let icon: AnchorIcon

        enum AnchorIcon: Equatable {
            case app(NSImage)
            case dictation
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Drag icons around the ring to position them. Non-pinned running apps fill the gaps automatically in Orbit.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            ZStack {
                // Guide circle at the ring radius
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    .frame(width: diameter - 40, height: diameter - 40)

                // Clock tick marks at 12/3/6/9
                ForEach(0..<4, id: \.self) { i in
                    let degrees = Double(i) * 90
                    Rectangle()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 1, height: 6)
                        .offset(y: -(diameter - 40) / 2)
                        .rotationEffect(.degrees(degrees))
                }

                // Center dot
                Circle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 4, height: 4)

                if anchors.isEmpty {
                    Text("No anchored items yet.\nPin an app or enable dictation to see them here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 160)
                } else {
                    ForEach(anchors) { anchor in
                        anchorTile(anchor)
                    }
                }
            }
            .frame(width: diameter, height: diameter)
            // The named coordinate space must be on the ring ZStack, not on
            // individual icons. `value.location` in the DragGesture below is
            // reported in this space, so the angle math computes relative to
            // the full ring instead of each icon's tiny local frame.
            .coordinateSpace(name: "layoutRing")
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .padding(8)
            )

            Button("Reset to default layout") {
                settings.resetLayoutAngles()
                loadAnchors()
            }
            .buttonStyle(.borderless)
            .disabled(anchors.isEmpty)
        }
        .padding(.vertical, 12)
        .onAppear { loadAnchors() }
        .onChange(of: settings.pinnedBundleIds) { loadAnchors() }
        .onChange(of: settings.dictationEnabled) { loadAnchors() }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func anchorTile(_ anchor: Anchor) -> some View {
        let liveAngle = (draggingId == anchor.id) ? dragAngle : anchor.angleDegrees
        let position = positionForAngle(liveAngle)

        Group {
            switch anchor.icon {
            case .app(let image):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: iconSize, height: iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            case .dictation:
                RoundedRectangle(cornerRadius: 8)
                    .fill(.ultraThinMaterial)
                    .frame(width: iconSize, height: iconSize)
                    .overlay(
                        Image(systemName: "mic.fill")
                            .font(.system(size: iconSize * 0.5, weight: .medium))
                            .foregroundStyle(.primary)
                    )
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 4)
        // .position() moves BOTH the visual placement AND the hit-testing
        // region of the view. .offset() only moves the visual — gesture hit
        // regions stay at the original un-offset position, which made drags
        // silently fail in an earlier iteration.
        .position(position)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("layoutRing"))
                .onChanged { value in
                    let computed = angleFrom(point: value.location)
                    NSLog("[Orbit.layout] drag \(anchor.id) location=\(value.location) computed=\(computed)°")
                    draggingId = anchor.id
                    dragAngle = computed
                }
                .onEnded { value in
                    let raw = angleFrom(point: value.location)
                    let snapped = snap(raw, avoiding: anchor.id)
                    NSLog("[Orbit.layout] drag end \(anchor.id) raw=\(raw)° snapped=\(snapped)°")
                    draggingId = nil
                    dragAngle = snapped
                    commit(anchor: anchor, angle: snapped)
                }
        )
    }

    // MARK: - Angle math

    /// Convert a point inside the ring frame into a degrees-from-12-o'clock
    /// angle. The input point comes from the drag gesture's named coordinate
    /// space, which has (0, 0) at the top-left of the ZStack.
    private func angleFrom(point: CGPoint) -> Double {
        let center = CGPoint(x: diameter / 2, y: diameter / 2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        // SwiftUI's coordinate system has +y going down. 12 o'clock is -y.
        // atan2(dx, -dy) gives the clockwise angle from 12 o'clock in radians.
        let radians = atan2(dx, -dy)
        var degrees = radians * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    /// Converts a clockwise-from-12-o'clock angle into an absolute point
    /// inside the ring's ZStack coordinate space (same space that the
    /// DragGesture reports its `value.location` in).
    private func positionForAngle(_ degrees: Double) -> CGPoint {
        let center = CGPoint(x: diameter / 2, y: diameter / 2)
        let radius = (diameter - 40) / 2
        let radians = degrees * .pi / 180
        // 0° = 12 o'clock, clockwise. In SwiftUI's +y-down space that's
        // x = sin(θ), y = -cos(θ).
        let dx = CGFloat(sin(radians)) * radius
        let dy = CGFloat(cos(radians)) * radius
        return CGPoint(x: center.x + dx, y: center.y - dy)
    }

    /// Snap to the nearest 15° increment, then nudge off any occupied slot
    /// within `collisionThreshold` degrees. Search clockwise then
    /// counter-clockwise in 15° steps for a free slot.
    private func snap(_ degrees: Double, avoiding selfId: String) -> Double {
        var snapped = (degrees / snapIncrement).rounded() * snapIncrement
        snapped = snapped.truncatingRemainder(dividingBy: 360)
        if snapped < 0 { snapped += 360 }

        let occupied = anchors
            .filter { $0.id != selfId }
            .map { normalize($0.angleDegrees) }

        func conflicts(_ angle: Double) -> Bool {
            occupied.contains { abs(smallestDifference($0, angle)) < collisionThreshold }
        }

        if !conflicts(snapped) { return snapped }

        // Walk outward from the snapped slot, alternating clockwise and
        // counter-clockwise, until a free slot is found.
        for step in 1...24 {
            let offsetDegrees = Double(step) * snapIncrement
            let cw = normalize(snapped + offsetDegrees)
            if !conflicts(cw) { return cw }
            let ccw = normalize(snapped - offsetDegrees)
            if !conflicts(ccw) { return ccw }
        }
        return snapped // gave up; last-writer wins
    }

    private func smallestDifference(_ a: Double, _ b: Double) -> Double {
        var diff = a - b
        while diff > 180 { diff -= 360 }
        while diff < -180 { diff += 360 }
        return diff
    }

    private func normalize(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    // MARK: - Persistence

    private func loadAnchors() {
        var result: [Anchor] = []
        settings.ensurePreferredAngles()

        if settings.dictationEnabled {
            result.append(
                Anchor(
                    id: "dictation",
                    kind: .dictation,
                    angleDegrees: settings.dictationPreferredAngle ?? 0,
                    displayName: "Dictation",
                    icon: .dictation
                )
            )
        }

        for bundleId in settings.pinnedBundleIds {
            guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleId
            }) else { continue }

            let angle = settings.pinnedPreferredAngles[bundleId] ?? 0
            let icon = runningApp.icon ?? NSImage(size: NSSize(width: 32, height: 32))
            result.append(
                Anchor(
                    id: "app:\(bundleId)",
                    kind: .pinnedApp,
                    angleDegrees: angle,
                    displayName: runningApp.localizedName ?? bundleId,
                    icon: .app(icon)
                )
            )
        }

        anchors = result
    }

    private func commit(anchor: Anchor, angle: Double) {
        switch anchor.kind {
        case .dictation:
            settings.dictationPreferredAngle = angle
        case .pinnedApp:
            let bundleId = String(anchor.id.dropFirst("app:".count))
            settings.pinnedPreferredAngles[bundleId] = angle
        }
        settings.save()
        loadAnchors()
    }
}
