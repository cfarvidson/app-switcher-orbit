import AppKit

enum AppService {
    static func runningApps(excluding: Set<String> = [], pinnedFirst: [String] = []) -> [RunningApp] {
        let all = NSWorkspace.shared.runningApplications
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

        guard !pinnedFirst.isEmpty else { return all }

        let pinnedSet = Set(pinnedFirst)
        var pinned: [RunningApp] = []
        var rest: [RunningApp] = []

        for app in all {
            if let bid = app.bundleIdentifier, pinnedSet.contains(bid) {
                pinned.append(app)
            } else {
                rest.append(app)
            }
        }

        // Sort pinned apps by their order in pinnedFirst
        pinned.sort { a, b in
            let ai = pinnedFirst.firstIndex(of: a.bundleIdentifier ?? "") ?? Int.max
            let bi = pinnedFirst.firstIndex(of: b.bundleIdentifier ?? "") ?? Int.max
            return ai < bi
        }

        return pinned + rest
    }
}
