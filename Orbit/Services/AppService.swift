import AppKit

enum AppService {
    static func runningApps(excluding: Set<String> = []) -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { app in
                guard let bundleId = app.bundleIdentifier else { return true }
                return !excluding.contains(bundleId)
            }
            .compactMap { app -> RunningApp? in
                guard let name = app.localizedName else { return nil }
                let icon = app.icon ?? NSImage(size: NSSize(width: 64, height: 64))
                return RunningApp(
                    id: app.processIdentifier,
                    name: name,
                    bundleIdentifier: app.bundleIdentifier,
                    icon: icon,
                    app: app
                )
            }
    }
}
