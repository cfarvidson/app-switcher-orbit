import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var overlayPanel: OverlayPanel?
    private var hotkeyService: HotkeyService!
    private let viewModel = OrbitViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        promptAccessibilityIfNeeded()
        setupStatusItem()
        setupHotkey()
        setupOverlayPanel()

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
        if !hotkeyService.register() {
            NSLog("Orbit: Hotkey registration failed. The app may not respond to Option+Space.")
        }
    }

    private func setupOverlayPanel() {
        let orbitView = OrbitView(viewModel: viewModel)
        overlayPanel = OverlayPanel(contentView: orbitView)
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

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
