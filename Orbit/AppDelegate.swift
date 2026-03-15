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

        checkForUpdate()
    }

    // MARK: - Setup

    private func promptAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
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

        if viewModel.isVisible {
            viewModel.dismiss()
        } else {
            let mouseLocation = NSEvent.mouseLocation
            viewModel.show()
            overlayPanel?.showOverlay(at: mouseLocation, size: viewModel.orbitSize)
        }
    }

    // MARK: - Update check

    private func checkForUpdate() {
        UpdateService.checkForUpdate { [weak self] release in
            guard let release else { return }
            DispatchQueue.main.async {
                self?.showUpdateMenuItem(release)
            }
        }
    }

    private func showUpdateMenuItem(_ release: UpdateService.Release) {
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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
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
