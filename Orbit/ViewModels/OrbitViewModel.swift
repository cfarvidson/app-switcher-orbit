import AppKit
import Carbon
import QuartzCore
import SwiftUI

final class OrbitViewModel: ObservableObject {
    @Published var isVisible = false
    @Published var items: [OrbitItem] = []
    @Published var selectedIndex: Int?

    var onDismiss: (() -> Void)?

    private(set) var radius: CGFloat = 140
    private(set) var iconSize: CGFloat = 56
    private(set) var orbitSize: CGFloat = 400
    private(set) var deadZone: CGFloat = 35
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
        radius = isTrackpad ? 180 : 140
        iconSize = isTrackpad ? 68 : 56
        orbitSize = isTrackpad ? 500 : 400
        deadZone = isTrackpad ? 45 : 35
        stickySelection = isTrackpad
        edgeActivation = SettingsService.shared.edgeActivation
        edgeActivationRadius = radius + iconSize * 0.6
        mouseEnteredRing = false
        scrollAccumulator = 0
        lastScrollSelectionTime = 0

        let excluded = SettingsService.shared.excludedBundleIds
        let pinned = SettingsService.shared.pinnedBundleIds
        let runningApps = AppService.runningApps(excluding: excluded, pinnedFirst: pinned)
        let languages = SettingsService.shared.dictationLanguages
        items = languages.map(OrbitItem.language) + runningApps.map(OrbitItem.app)
        selectedIndex = nil
        isVisible = true
        startMonitors()
    }

    func dismiss() {
        guard isVisible else { return }
        isVisible = false
        selectedIndex = nil
        stopMonitors()
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
            case .language(let language):
                DictationService.switchLanguageAndStart(language.id)
            }
        }
    }

    func angleForIndex(_ index: Int) -> Double {
        guard !items.isEmpty else { return 0 }
        let slice = (2 * Double.pi) / Double(items.count)
        return slice * Double(index) - Double.pi / 2
    }

    func positionForIndex(_ index: Int) -> CGPoint {
        let angle = CGFloat(angleForIndex(index))
        return CGPoint(
            x: center.x + radius * cos(angle),
            y: center.y - radius * sin(angle)
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
