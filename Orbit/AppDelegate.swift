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

    func applicationDidFinishLaunching(_ notification: Notification) {
        promptAccessibilityIfNeeded()
        setupStatusItem()
        setupHotkey()
        setupOverlayPanel()
        observeSettingsChanges()

        viewModel.onDismiss = { [weak self] in
            self?.overlayPanel?.hideOverlay()
        }
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
            .dropFirst() // Skip initial values
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                guard let self else { return }
                self.hotkeyService.registerFromSettings(self.settings)
            }
            .store(in: &cancellables)
    }

    // MARK: - Orbit control

    private func toggleOrbit() {
        if viewModel.isVisible {
            viewModel.dismiss()
        } else {
            let mouseLocation = NSEvent.mouseLocation
            viewModel.show()
            overlayPanel?.showOverlay(at: mouseLocation, size: viewModel.orbitSize)
        }
    }

    // MARK: - Settings window

    @objc private func openSettings() {
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
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
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate()
    }
}
