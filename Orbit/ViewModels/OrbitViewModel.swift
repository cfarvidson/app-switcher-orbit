import AppKit
import Carbon
import QuartzCore
import SwiftUI

final class OrbitViewModel: ObservableObject {
    @Published var isVisible = false
    @Published var positionedItems: [RingLayout.Positioned] = []
    @Published var selectedIndex: Int?

    /// Convenience accessor that mirrors the old `items` property — kept only
    /// so existing call sites that care about count and index semantics can
    /// keep working without threading .item through every line.
    var items: [OrbitItem] { positionedItems.map(\.item) }

    var onDismiss: (() -> Void)?

    private(set) var radius: CGFloat = 180
    private(set) var iconSize: CGFloat = 56
    private(set) var orbitSize: CGFloat = 480
    private(set) var deadZone: CGFloat = 45
    private(set) var stickySelection: Bool = false
    private(set) var edgeActivation: Bool = false
    private(set) var edgeActivationRadius: CGFloat = 0
    private var mouseEnteredRing: Bool = false

    private var escMonitor: Any?
    private var globalEscMonitor: Any?
    private var globalClickMonitor: Any?

    private var scrollAccumulator: CGFloat = 0
    private var scrollMonitor: Any?
    private var lastScrollSelectionTime: CFTimeInterval = 0
    private let scrollSelectionMinInterval: CFTimeInterval = 0.06

    deinit {
        stopMonitors()
    }

    var center: CGPoint {
        CGPoint(x: orbitSize / 2, y: orbitSize / 2)
    }

    func show() {
        let isTrackpad = SettingsService.shared.inputMode == .trackpad
        radius = isTrackpad ? 230 : 180
        iconSize = isTrackpad ? 68 : 56
        orbitSize = isTrackpad ? 600 : 480
        deadZone = isTrackpad ? 55 : 45
        stickySelection = isTrackpad
        edgeActivation = SettingsService.shared.edgeActivation
        edgeActivationRadius = radius + iconSize * 0.6
        mouseEnteredRing = false
        scrollAccumulator = 0
        lastScrollSelectionTime = 0

        let settings = SettingsService.shared
        let excluded = settings.excludedBundleIds
        let pinned = settings.pinnedBundleIds

        // Prune/assign angles for current anchored items before layout.
        settings.ensureAnchorAngles()

        let allApps = AppService.runningApps(excluding: excluded, pinnedFirst: pinned)
        let pinnedSet = Set(pinned)
        let anchoredApps = allApps.filter { pinnedSet.contains($0.bundleIdentifier ?? "") }
        let nonPinnedApps = allApps.filter { !pinnedSet.contains($0.bundleIdentifier ?? "") }

        // Build the anchored (item, angle) list from the user's stored angles.
        var anchored: [(OrbitItem, Double)] = []
        if settings.dictationEnabled, let angle = settings.dictationAngle {
            anchored.append((.dictation, angle))
        }
        for app in anchoredApps {
            if let bundleId = app.bundleIdentifier, let angle = settings.pinnedAngles[bundleId] {
                anchored.append((.app(app), angle))
            }
        }

        NSLog("[Orbit.layout] show() dictationAngle=\(String(describing: settings.dictationAngle)) pinAngles=\(settings.pinnedAngles)")
        NSLog("[Orbit.layout] show() anchored=\(anchored.map { "\($0.0.id)@\(Int($0.1))°" })")

        positionedItems = RingLayout.compute(
            anchoredItems: anchored,
            nonPinned: nonPinnedApps.map(OrbitItem.app)
        )

        NSLog("[Orbit.layout] show() positioned=\(positionedItems.map { "\($0.item.id)@\(Int($0.angleDegrees))°\($0.isAnchored ? "*" : "")" })")

        selectedIndex = nil
        isVisible = true
        startMonitors()

        // Pre-roll audio capture so the first phoneme spoken when the user
        // clicks a tile is not lost to AVAudioEngine startup latency. No-op
        // if mic permission isn't granted yet (no surprise prompts).
        if SettingsService.shared.dictationEnabled {
            SpeechRecognitionService.shared.warmupAudioCapture()
        }
    }

    func dismiss() {
        guard isVisible else { return }
        isVisible = false
        selectedIndex = nil
        stopMonitors()
        SpeechRecognitionService.shared.cancelWarmup()
        onDismiss?()
    }

    func selectAndSwitch() {
        guard let index = selectedIndex, index < items.count else {
            dismiss()
            return
        }
        let item = items[index]
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            switch item {
            case .app(let app):
                app.app.activate()
            case .dictation:
                SpeechRecognitionService.shared.startDictation { errorMessage in
                    NSLog("[Orbit.dictation] speech start failed: \(errorMessage)")
                }
            }
        }
    }

    /// Angle in math convention (radians, 0 at +x axis, CCW positive), used
    /// by `updateSelection`'s `atan2(-dy, dx)` mouse-angle comparison.
    /// Stored angles are clockwise-from-12-o'clock in degrees; convert by
    /// treating 12 o'clock as +y in math space (i.e., π/2) and going
    /// clockwise as negative.
    func angleForIndex(_ index: Int) -> Double {
        guard positionedItems.indices.contains(index) else { return 0 }
        let degreesFromTwelve = positionedItems[index].angleDegrees
        return .pi / 2 - (degreesFromTwelve * .pi / 180)
    }

    /// Renders a stored clockwise-from-12-o'clock angle to a SwiftUI point
    /// inside the ring (y+ down coordinate space). 0° = top, 90° = right,
    /// 180° = bottom, 270° = left.
    func positionForIndex(_ index: Int) -> CGPoint {
        guard positionedItems.indices.contains(index) else { return center }
        let degrees = positionedItems[index].angleDegrees
        let radians = degrees * .pi / 180
        return CGPoint(
            x: center.x + radius * CGFloat(sin(radians)),
            y: center.y - radius * CGFloat(cos(radians))
        )
    }

    func updateSelection(mouseInView: CGPoint) {
        let dx = Double(mouseInView.x - center.x)
        let dy = Double(mouseInView.y - center.y)
        let distance = sqrt(dx * dx + dy * dy)

        guard distance > Double(deadZone), !items.isEmpty else {
            selectedIndex = nil
            return
        }

        let mouseAngle = normalizeAngle(atan2(-dy, dx))

        var closestIndex = 0
        var closestDiff = Double.infinity

        for i in 0..<items.count {
            let itemAngle = normalizeAngle(angleForIndex(i))
            var diff = abs(mouseAngle - itemAngle)
            if diff > Double.pi {
                diff = 2 * Double.pi - diff
            }
            if diff < closestDiff {
                closestDiff = diff
                closestIndex = i
            }
        }

        selectedIndex = closestIndex

        if distance < Double(edgeActivationRadius) {
            mouseEnteredRing = true
        }

        if edgeActivation && mouseEnteredRing && distance > Double(edgeActivationRadius) {
            selectAndSwitch()
        }
    }

    func handleHoverEnded() {
        if !stickySelection {
            selectedIndex = nil
        }
    }

    func handleScroll(deltaY: CGFloat) {
        guard !items.isEmpty else { return }
        scrollAccumulator += deltaY
        let threshold: CGFloat = 3.0
        guard abs(scrollAccumulator) > threshold else { return }

        let now = CACurrentMediaTime()
        guard now - lastScrollSelectionTime >= scrollSelectionMinInterval else { return }

        let direction = scrollAccumulator > 0 ? -1 : 1
        let current = selectedIndex ?? 0
        selectedIndex = (current + direction + items.count) % items.count
        scrollAccumulator -= CGFloat(scrollAccumulator > 0 ? 1 : -1) * threshold
        lastScrollSelectionTime = now
    }

    /// Normalize angle to [0, 2π)
    private func normalizeAngle(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 2 * Double.pi)
        if a < 0 { a += 2 * Double.pi }
        return a
    }

    // MARK: - Event monitors

    private func startMonitors() {
        // Keyboard navigation (local): ESC, arrows, Enter
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch Int(event.keyCode) {
            case kVK_Escape:
                self.dismiss()
                return nil
            case kVK_LeftArrow:
                if !self.items.isEmpty {
                    let current = self.selectedIndex ?? 0
                    self.selectedIndex = (current - 1 + self.items.count) % self.items.count
                }
                return nil
            case kVK_RightArrow:
                if !self.items.isEmpty {
                    let current = self.selectedIndex ?? 0
                    self.selectedIndex = (current + 1) % self.items.count
                }
                return nil
            case kVK_Return:
                self.selectAndSwitch()
                return nil
            default:
                return event
            }
        }
        globalEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Int(event.keyCode) == kVK_Escape {
                self?.dismiss()
            }
        }

        // Click outside to dismiss (global monitor fires for clicks on other apps)
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.dismiss()
        }

        // Scroll wheel for trackpad rotation
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            if event.phase == .began {
                self.scrollAccumulator = 0
            }
            guard event.momentumPhase == NSEvent.Phase(rawValue: 0) else {
                return event
            }
            self.handleScroll(deltaY: event.scrollingDeltaY)
            if event.phase == .ended || event.phase == .cancelled {
                self.scrollAccumulator = 0
            }
            return event
        }
    }

    private func stopMonitors() {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
        if let monitor = globalEscMonitor {
            NSEvent.removeMonitor(monitor)
            globalEscMonitor = nil
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }
}
