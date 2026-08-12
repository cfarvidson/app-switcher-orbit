import Foundation

/// A single item rendered around the Orbit ring. Ring positions, angle math,
/// scroll-to-rotate and arrow navigation all operate on `[OrbitItem]` so that
/// apps and the dictation tile can coexist in a single ring.
enum OrbitItem: Identifiable, Equatable {
    case app(RunningApp)
    case dictation

    var id: String {
        switch self {
        case .app(let app): return "app:\(app.id)"
        case .dictation: return "dictation"
        }
    }

    var displayName: String {
        switch self {
        case .app(let app): return app.name
        case .dictation: return "Dictation"
        }
    }
}
