import AppKit
import SwiftUI

final class OrbitViewModel: ObservableObject {
    @Published var isVisible = false
    @Published var apps: [RunningApp] = []
    @Published var selectedIndex: Int?

    var onDismiss: (() -> Void)?

    let radius: CGFloat = 140
    let iconSize: CGFloat = 56
    let orbitSize: CGFloat = 400

    private var escMonitor: Any?
    private var globalEscMonitor: Any?
    private var globalClickMonitor: Any?

    var center: CGPoint {
        CGPoint(x: orbitSize / 2, y: orbitSize / 2)
    }

    func show() {
        let excluded = SettingsService.shared.excludedBundleIds
        apps = AppService.runningApps(excluding: excluded)
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
        guard let index = selectedIndex, index < apps.count else {
            dismiss()
            return
        }
        let app = apps[index]
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            app.app.activate()
        }
    }

    func angleForIndex(_ index: Int) -> Double {
        guard apps.count > 0 else { return 0 }
        let slice = (2 * Double.pi) / Double(apps.count)
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

        guard distance > 35, !apps.isEmpty else {
            selectedIndex = nil
            return
        }

        let mouseAngle = normalizeAngle(atan2(-dy, dx))

        var closestIndex = 0
        var closestDiff = Double.infinity

        for i in 0..<apps.count {
            let appAngle = normalizeAngle(angleForIndex(i))
            var diff = abs(mouseAngle - appAngle)
            if diff > Double.pi {
                diff = 2 * Double.pi - diff
            }
            if diff < closestDiff {
                closestDiff = diff
                closestIndex = i
            }
        }

        selectedIndex = closestIndex
    }

    /// Normalize angle to [0, 2π)
    private func normalizeAngle(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 2 * Double.pi)
        if a < 0 { a += 2 * Double.pi }
        return a
    }

    // MARK: - Event monitors

    private func startMonitors() {
        // ESC to dismiss (local + global)
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.dismiss()
                return nil
            }
            return event
        }
        globalEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.dismiss()
            }
        }

        // Click outside to dismiss (global monitor fires for clicks on other apps)
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.dismiss()
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
    }
}
