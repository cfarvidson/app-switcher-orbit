import AppKit
import SwiftUI

/// Live preview of the resolved ring. Pinned apps and the dictation tile are
/// draggable and set a preferred direction; every non-pinned running app is
/// drawn dimmed and smaller so the user can see what the ring will actually
/// look like rather than an abstract set of anchors.
///
/// This view calls the same `RingLayout.compute` the real ring uses, so the
/// preview cannot drift from the thing it is previewing.
struct LayoutPreviewView: View {
    @ObservedObject var settings = SettingsService.shared
    @State private var runningApps: [RunningApp] = []
    @State private var draggingId: String?
    @State private var dragAngle: Double = 0

    private let diameter: CGFloat = 280
    private let anchorIconSize: CGFloat = 44
    private let otherIconSize: CGFloat = 26

    private var ringRadius: CGFloat { (diameter - 40) / 2 }
    private var center: CGPoint { CGPoint(x: diameter / 2, y: diameter / 2) }

    var body: some View {
        VStack(spacing: 12) {
            Text("Drag a pinned app to roughly where you want it. Orbit keeps every app evenly spaced and gives each pinned app the free slot closest to your direction.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    .frame(width: ringRadius * 2, height: ringRadius * 2)

                ForEach(0..<4, id: \.self) { i in
                    Rectangle()
                        .fill(Color.primary.opacity(0.25))
                        .frame(width: 1, height: 6)
                        .offset(y: -ringRadius)
                        .rotationEffect(.degrees(Double(i) * 90))
                }

                Circle()
                    .fill(Color.primary.opacity(0.3))
                    .frame(width: 4, height: 4)

                if draggingId != nil {
                    preferenceRay
                    resolvedSlotDot
                }

                ForEach(resolvedRing, id: \.item.id) { positioned in
                    tile(positioned)
                }

                // The ring is almost never empty - every running app is in
                // it - so the empty state keys off having nothing draggable,
                // and sits in the middle of the dimmed apps rather than
                // replacing them.
                if !hasAnchors {
                    Text("Nothing pinned yet.\nPin an app or enable dictation to place it here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 160)
                }
            }
            .frame(width: diameter, height: diameter)
            .coordinateSpace(name: "layoutRing")
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .padding(8)
            )
            .animation(
                .interpolatingSpring(stiffness: 260, damping: 22),
                value: resolvedRing.map(\.angleDegrees)
            )

            Text("Dimmed icons are running apps that aren't pinned. They fill whatever slots are left.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Reset to default layout") {
                settings.resetLayoutAngles()
                reload()
            }
            .buttonStyle(.borderless)
            .disabled(!hasAnchors)
        }
        .padding(.vertical, 12)
        .onAppear { reload() }
        .onChange(of: settings.pinnedBundleIds) { reload() }
        .onChange(of: settings.dictationEnabled) { reload() }
    }

    // MARK: - Ring resolution

    /// The ring as `RingLayout` resolves it right now. While a drag is in
    /// flight the dragged item's stored preference is replaced by the live
    /// drag angle, so the rest of the ring re-solves under the cursor.
    private var resolvedRing: [RingLayout.Positioned] {
        var preferred: [(item: OrbitItem, preferredAngle: Double)] = []
        var others: [OrbitItem] = []

        if settings.dictationEnabled, let stored = settings.dictationPreferredAngle {
            let angle = (draggingId == "dictation") ? dragAngle : stored
            preferred.append((.dictation, angle))
        }

        for app in runningApps {
            guard let bundleId = app.bundleIdentifier,
                  let stored = settings.pinnedPreferredAngles[bundleId]
            else {
                others.append(.app(app))
                continue
            }
            let id = "app:\(bundleId)"
            let angle = (draggingId == id) ? dragAngle : stored
            preferred.append((.app(app), angle))
        }

        return RingLayout.compute(preferred: preferred, others: others)
    }

    /// True when there is at least one draggable item in the ring.
    private var hasAnchors: Bool {
        resolvedRing.contains { $0.isAnchored }
    }

    /// The drag id for an item, or nil when it is not draggable.
    private func anchorId(for item: OrbitItem) -> String? {
        switch item {
        case .dictation:
            return "dictation"
        case .app(let app):
            guard let bundleId = app.bundleIdentifier,
                  settings.pinnedPreferredAngles[bundleId] != nil
            else { return nil }
            return "app:\(bundleId)"
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func tile(_ positioned: RingLayout.Positioned) -> some View {
        let id = anchorId(for: positioned.item)
        let isDragged = id != nil && id == draggingId
        // The dragged icon follows the cursor freely; everything else sits on
        // its resolved slot.
        let angle = isDragged ? dragAngle : positioned.angleDegrees
        let size = positioned.isAnchored ? anchorIconSize : otherIconSize

        Group {
            switch positioned.item {
            case .app(let app):
                Image(nsImage: app.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
            case .dictation:
                RoundedRectangle(cornerRadius: size * 0.18)
                    .fill(.ultraThinMaterial)
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "mic.fill")
                            .font(.system(size: size * 0.5, weight: .medium))
                            .foregroundStyle(.primary)
                    )
            }
        }
        .opacity(positioned.isAnchored ? 1.0 : 0.35)
        .position(positionForAngle(angle))
        .allowsHitTesting(positioned.isAnchored)
        .gesture(dragGesture(for: id))
    }

    private func dragGesture(for id: String?) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("layoutRing"))
            .onChanged { value in
                guard let id else { return }
                draggingId = id
                dragAngle = angleFrom(point: value.location)
            }
            .onEnded { value in
                guard let id else { return }
                let angle = angleFrom(point: value.location)
                draggingId = nil
                dragAngle = angle
                commit(id: id, angle: angle)
            }
    }

    /// Hairline from the center showing the direction the cursor is pointing.
    private var preferenceRay: some View {
        Path { path in
            path.move(to: center)
            path.addLine(to: positionForAngle(dragAngle))
        }
        .stroke(Color.primary.opacity(0.25), lineWidth: 1)
    }

    /// Small accent dot marking the slot the dragged item will land on.
    @ViewBuilder
    private var resolvedSlotDot: some View {
        if let draggingId,
           let resolved = resolvedRing.first(where: { anchorId(for: $0.item) == draggingId })
        {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
                .position(positionForAngle(resolved.angleDegrees))
        }
    }

    // MARK: - Angle math

    /// Convert a point in the ring's named coordinate space into a
    /// degrees-clockwise-from-twelve angle. SwiftUI's +y goes down, so twelve
    /// o'clock is -y and `atan2(dx, -dy)` gives the clockwise angle.
    private func angleFrom(point: CGPoint) -> Double {
        let dx = point.x - center.x
        let dy = point.y - center.y
        var degrees = atan2(dx, -dy) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    /// 0 degrees is twelve o'clock, clockwise. In SwiftUI's +y-down space
    /// that is x = sin(theta), y = -cos(theta).
    private func positionForAngle(_ degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(
            x: center.x + CGFloat(sin(radians)) * ringRadius,
            y: center.y - CGFloat(cos(radians)) * ringRadius
        )
    }

    // MARK: - Persistence

    private func reload() {
        settings.ensurePreferredAngles()
        runningApps = AppService.runningApps(
            excluding: settings.excludedBundleIds,
            pinnedFirst: settings.pinnedBundleIds
        )
    }

    private func commit(id: String, angle: Double) {
        if id == "dictation" {
            settings.dictationPreferredAngle = angle
        } else {
            settings.pinnedPreferredAngles[String(id.dropFirst("app:".count))] = angle
        }
        settings.save()
    }
}
