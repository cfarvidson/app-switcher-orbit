import Foundation

/// A single item rendered around the Orbit ring. Ring positions, angle math,
/// scroll-to-rotate and arrow navigation all operate on `[OrbitItem]` so that
/// apps and dictation languages can coexist in a single ring.
enum OrbitItem: Identifiable, Equatable {
    case app(RunningApp)
    case language(DictationLanguage)

    var id: String {
        switch self {
        case .app(let app): return "app:\(app.id)"
        case .language(let language): return "lang:\(language.id)"
        }
    }

    var displayName: String {
        switch self {
        case .app(let app): return app.name
        case .language(let language): return language.displayName
        }
    }
}
