import AppKit

struct RunningApp: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage
    let app: NSRunningApplication

    static func == (lhs: RunningApp, rhs: RunningApp) -> Bool {
        lhs.id == rhs.id
    }
}
