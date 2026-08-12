import AppKit
import Combine

/// Owns the menu bar status item: its button appearance, its menu, and the
/// mapping from `SpeechRecognitionService.DictationState` to an icon
/// treatment. Split out of `AppDelegate` so the delegate keeps only the menu
/// actions and the app lifecycle.
///
/// Menu items built here use a `nil` target so their actions travel the
/// responder chain to `AppDelegate`, which is how the menu already worked
/// before this type existed. Items owned by this controller set an explicit
/// target instead.
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private var cancellables = Set<AnyCancellable>()

    private var activationMenuItem: NSMenuItem?
    private var inputModeMenuItem: NSMenuItem?
    private var updateMenuItem: NSMenuItem?
    private var dictationStatusItem: NSMenuItem?
    private var stopDictationItem: NSMenuItem?
    private var dictationSeparatorItem: NSMenuItem?

    private var breatheTimer: Timer?
    private var breathePhase: Double = 0

    /// How the button renders in a given dictation state. `breathePeriod` of
    /// nil means a static icon.
    private struct IconStyle {
        let symbol: String
        let tinted: Bool
        let alpha: CGFloat
        let breathePeriod: Double?
    }

    init(activationTitle: String, inputModeTitle: String) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        buildMenu(activationTitle: activationTitle, inputModeTitle: inputModeTitle)
        apply(state: .idle)
        observeDictationState()
    }

    // MARK: - Menu

    private func buildMenu(activationTitle: String, inputModeTitle: String) {
        let menu = NSMenu()

        let activation = NSMenuItem(title: activationTitle, action: nil, keyEquivalent: "")
        activation.isEnabled = false
        menu.addItem(activation)
        activationMenuItem = activation

        let inputMode = NSMenuItem(title: inputModeTitle, action: nil, keyEquivalent: "")
        inputMode.isEnabled = false
        menu.addItem(inputMode)
        inputModeMenuItem = inputMode

        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(title: "Settings\u{2026}", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        )
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(title: "Check for Updates\u{2026}", action: #selector(AppDelegate.checkForUpdateManual), keyEquivalent: "")
        )
        menu.addItem(
            NSMenuItem(title: "About Orbit", action: #selector(AppDelegate.showAbout), keyEquivalent: "")
        )
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit Orbit",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        statusItem.menu = menu
    }

    func setActivationTitle(_ title: String) {
        activationMenuItem?.title = title
    }

    func setInputModeTitle(_ title: String) {
        inputModeMenuItem?.title = title
    }

    /// Inserts (or replaces) the "Update Available" item at the top of the
    /// menu, followed by a separator.
    func showUpdateItem(title: String, url: URL, target: AnyObject, action: Selector) {
        if let existing = updateMenuItem, let menu = statusItem.menu {
            let index = menu.index(of: existing)
            if index >= 0 {
                menu.removeItem(at: index + 1)
                menu.removeItem(existing)
            }
        }

        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = url
        statusItem.menu?.insertItem(item, at: 0)
        statusItem.menu?.insertItem(NSMenuItem.separator(), at: 1)
        updateMenuItem = item
    }

    // MARK: - Dictation state

    private func observeDictationState() {
        SpeechRecognitionService.shared.$dictationState
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.apply(state: state)
            }
            .store(in: &cancellables)
    }

    private func style(for state: SpeechRecognitionService.DictationState) -> IconStyle {
        switch state {
        case .idle:
            return IconStyle(symbol: "circle.dotted", tinted: false, alpha: 1.0, breathePeriod: nil)
        case .loading:
            return IconStyle(symbol: "circle.dotted", tinted: false, alpha: 0.45, breathePeriod: 1.6)
        case .starting:
            return IconStyle(symbol: "waveform", tinted: false, alpha: 0.45, breathePeriod: nil)
        case .listening:
            return IconStyle(symbol: "waveform", tinted: true, alpha: 1.0, breathePeriod: 1.2)
        case .transcribing:
            return IconStyle(symbol: "ellipsis", tinted: false, alpha: 1.0, breathePeriod: nil)
        }
    }

    private func apply(state: SpeechRecognitionService.DictationState) {
        guard let button = statusItem.button else { return }
        let style = style(for: state)

        button.image = NSImage(
            systemSymbolName: style.symbol,
            accessibilityDescription: "Orbit"
        )
        // The image must stay a template for `contentTintColor` to have any
        // effect. A non-template image ignores the tint entirely, which is
        // why the tinted state is expressed purely through the tint color.
        button.image?.isTemplate = true
        button.contentTintColor = style.tinted ? NSColor.controlAccentColor : nil

        if let period = style.breathePeriod {
            startBreathing(period: period, baseAlpha: style.alpha)
        } else {
            stopBreathing(resetTo: style.alpha)
        }

        updateDictationMenuItems(for: state)
    }

    /// Inserts a disabled status line plus a "Stop Dictation" command at the
    /// top of the menu while a session is live, and removes both when it ends.
    /// This is the visible replacement for the old click-to-stop panel, and the
    /// only place the `.loading` message is still shown.
    private func updateDictationMenuItems(for state: SpeechRecognitionService.DictationState) {
        guard let menu = statusItem.menu else { return }

        // Tear down whatever is currently installed, separator included.
        for item in [stopDictationItem, dictationStatusItem].compactMap({ $0 }) {
            let index = menu.index(of: item)
            if index >= 0 { menu.removeItem(at: index) }
        }
        if let separator = dictationSeparatorItem, menu.index(of: separator) >= 0 {
            menu.removeItem(separator)
        }
        dictationStatusItem = nil
        stopDictationItem = nil
        dictationSeparatorItem = nil

        let statusText: String
        switch state {
        case .idle: return
        case .loading(let message): statusText = message
        case .starting: statusText = "Starting\u{2026}"
        case .listening: statusText = "Listening\u{2026}"
        case .transcribing: statusText = "Transcribing\u{2026}"
        }

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        let stop = NSMenuItem(title: "Stop Dictation", action: #selector(stopDictation), keyEquivalent: "")
        stop.target = self
        let separator = NSMenuItem.separator()

        menu.insertItem(status, at: 0)
        menu.insertItem(stop, at: 1)
        menu.insertItem(separator, at: 2)
        dictationStatusItem = status
        stopDictationItem = stop
        dictationSeparatorItem = separator
    }

    @objc private func stopDictation() {
        SpeechRecognitionService.shared.stop(reason: "menu bar stop")
    }

    // MARK: - Breathe animation

    /// Oscillates the button's alpha between `baseAlpha` and 55% of it. Runs
    /// on `.common` so it keeps animating while a menu is open. Invalidated
    /// on every transition to a static state, so the icon is motionless
    /// except while loading or listening.
    private func startBreathing(period: Double, baseAlpha: CGFloat) {
        stopBreathing(resetTo: baseAlpha)
        breathePhase = 0
        let tick = 1.0 / 30.0
        let timer = Timer(timeInterval: tick, repeats: true) { [weak self] _ in
            guard let self, let button = self.statusItem.button else { return }
            self.breathePhase += tick / period * 2 * .pi
            let wave = (sin(self.breathePhase) + 1) / 2  // 0...1
            button.alphaValue = baseAlpha * (0.55 + 0.45 * CGFloat(wave))
        }
        RunLoop.main.add(timer, forMode: .common)
        breatheTimer = timer
    }

    private func stopBreathing(resetTo alpha: CGFloat) {
        breatheTimer?.invalidate()
        breatheTimer = nil
        statusItem.button?.alphaValue = alpha
    }
}
