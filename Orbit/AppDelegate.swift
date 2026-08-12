import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var overlayPanel: OverlayPanel?
    private var hotkeyService: HotkeyService!
    private let viewModel = OrbitViewModel()
    private let settings = SettingsService.shared
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?
    private var activationMenuItem: NSMenuItem?
    private var inputModeMenuItem: NSMenuItem?
    private var updateMenuItem: NSMenuItem?
    private var lastToggleTime: Date = .distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        promptAccessibilityIfNeeded()
        setupStatusItem()
        setupHotkey()
        setupOverlayPanel()
        observeSettingsChanges()

        viewModel.onDismiss = { [weak self] in
            self?.overlayPanel?.hideOverlay()
        }

        // If dictation is enabled, pre-load the Parakeet model in the
        // background so the first dictation tile click doesn't have to wait
        // several seconds for the CoreML model to load. (Skips silently if
        // not yet downloaded — user must download from Settings first.)
        if settings.dictationEnabled {
            SpeechRecognitionService.shared.prewarm()
        }

        // Forwarded by SpeechRecognitionService when the user clicks
        // "Open Settings…" on the missing-model alert.
        NotificationCenter.default.addObserver(
            forName: .orbitOpenSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.openSettings()
        }

        checkForUpdate()
    }

    // MARK: - Setup

    private func promptAccessibilityIfNeeded() {
        // First-time prompt: only fires when there's NO existing TCC entry.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        // Stale-entry detection: when the binary is rebuilt (which happens
        // on every `./build.sh`), macOS keeps the existing TCC entry but
        // the stored code requirement no longer matches the new signature.
        // The entry still appears enabled in System Settings → Privacy &
        // Security → Accessibility, but TCC silently denies access. The
        // Carbon hotkey keeps working (it bypasses TCC), but `CGEvent.post`
        // for synthesized keystrokes is filtered, so dictation paste never
        // lands. AXIsProcessTrustedWithOptions does NOT re-prompt in this
        // state because the entry exists; we have to detect it ourselves.
        //
        // tccd logs this as: "Failed to match existing code requirement
        // for subject com.orbit.appswitcher and service kTCCServiceAccessibility".
        if !AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showStaleAccessibilityAlert()
            }
        }
    }

    private func showStaleAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility access is disabled"
        alert.informativeText = """
            Orbit needs Accessibility access to register the global hotkey, suppress mouse triggers over browser tabs, and inject text from dictation.

            If Orbit already appears in System Settings → Privacy & Security → Accessibility but isn't working (e.g. dictation paste does nothing), the saved entry is from a previous build. Toggle Orbit OFF and then back ON to refresh it.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Privacy Settings\u{2026}")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        {
            NSWorkspace.shared.open(url)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "circle.dotted",
                accessibilityDescription: "Orbit"
            )
        }

        let menu = NSMenu()

        let activation = NSMenuItem(title: activationDisplayString(), action: nil, keyEquivalent: "")
        activation.isEnabled = false
        menu.addItem(activation)
        activationMenuItem = activation

        let inputMode = NSMenuItem(title: inputModeDisplayString(), action: nil, keyEquivalent: "")
        inputMode.isEnabled = false
        menu.addItem(inputMode)
        inputModeMenuItem = inputMode

        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        )
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(title: "Check for Updates\u{2026}", action: #selector(checkForUpdateManual), keyEquivalent: "")
        )
        menu.addItem(
            NSMenuItem(title: "About Orbit", action: #selector(showAbout), keyEquivalent: "")
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

    private func setupHotkey() {
        hotkeyService = HotkeyService { [weak self] in
            self?.toggleOrbit()
        }
        hotkeyService.registerFromSettings(settings)
    }

    private func setupOverlayPanel() {
        let orbitView = OrbitView(viewModel: viewModel)
        overlayPanel = OverlayPanel(contentView: orbitView)
    }

    private func observeSettingsChanges() {
        // Re-register hotkey when shortcut settings change
        settings.$triggerType
            .combineLatest(settings.$keyCode, settings.$modifiers, settings.$mouseButton)
            .dropFirst()
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                guard let self else { return }
                self.hotkeyService.registerFromSettings(self.settings)
                self.activationMenuItem?.title = self.activationDisplayString()
            }
            .store(in: &cancellables)

        // Update input mode menu item when it changes
        settings.$inputMode
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.inputModeMenuItem?.title = self.inputModeDisplayString()
            }
            .store(in: &cancellables)
    }

    private func activationDisplayString() -> String {
        switch settings.triggerType {
        case .keyboard:
            return settings.shortcutDisplayString
        case .mouseButton:
            return settings.mouseButtonDisplayName
        case .both:
            return "\(settings.shortcutDisplayString) + \(settings.mouseButtonDisplayName)"
        }
    }

    private func inputModeDisplayString() -> String {
        settings.inputMode == .mouse ? "Mouse Mode" : "Trackpad Mode"
    }

    // MARK: - Orbit control

    private func toggleOrbit() {
        let now = Date()
        guard now.timeIntervalSince(lastToggleTime) > 0.2 else { return }
        lastToggleTime = now

        // If dictation is currently recording, the trigger acts as a stop
        // button instead of opening the ring. Lets the user cancel a
        // recording session with the same hotkey/mouse trigger they used
        // to start it via the language tile.
        if SpeechRecognitionService.shared.isRunning {
            SpeechRecognitionService.shared.stop(reason: "orbit retrigger")
            return
        }

        if viewModel.isVisible {
            viewModel.dismiss()
        } else {
            let mouseLocation = NSEvent.mouseLocation
            viewModel.show()
            overlayPanel?.showOverlay(at: mouseLocation, size: viewModel.orbitSize)
        }
    }

    // MARK: - Update check

    private func checkForUpdate(silent: Bool = true) {
        UpdateService.checkForUpdate { [weak self] release in
            DispatchQueue.main.async {
                if let release {
                    self?.showUpdateMenuItem(release)
                } else if !silent {
                    self?.showUpToDateAlert()
                }
            }
        }
    }

    @objc private func checkForUpdateManual() {
        checkForUpdate(silent: false)
    }

    private func showUpdateMenuItem(_ release: UpdateService.Release) {
        // Remove existing update item if present
        if let existing = updateMenuItem {
            if let index = statusItem.menu?.index(of: existing), index >= 0 {
                statusItem.menu?.removeItem(at: index + 1) // separator
                statusItem.menu?.removeItem(existing)
            }
        }

        let item = NSMenuItem(
            title: "Update Available (v\(release.version))",
            action: #selector(openUpdate(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = release.url
        statusItem.menu?.insertItem(item, at: 0)
        statusItem.menu?.insertItem(NSMenuItem.separator(), at: 1)
        updateMenuItem = item
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You're up to date!"
        alert.informativeText = "Orbit v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func openUpdate(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Settings window

    @objc private func openSettings() {
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Orbit Settings"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        settingsWindow = window
    }

    @objc private func showAbout() {
        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(
            string: "By Carl-Fredrik Arvidson\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]
        ))
        credits.append(NSAttributedString(
            string: "carl-fredrik.arvidson.io\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .link: URL(string: "https://carl-fredrik.arvidson.io")!,
            ]
        ))
        credits.append(NSAttributedString(
            string: "github.com/cfarvidson/app-switcher-orbit",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .link: URL(string: "https://github.com/cfarvidson/app-switcher-orbit")!,
            ]
        ))
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
        ])
        NSApp.activate()
    }
}
