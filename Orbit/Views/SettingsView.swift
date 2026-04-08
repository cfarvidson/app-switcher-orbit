import Carbon
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = SettingsService.shared
    @State private var allApps: [AppInfo] = []
    @State private var enabledDictationLocales: [DictationLanguage] = []

    var body: some View {
        TabView {
            shortcutTab
                .tabItem { Label("Shortcut", systemImage: "keyboard") }
            pinnedTab
                .tabItem { Label("Pinned", systemImage: "pin") }
            appsTab
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            dictationTab
                .tabItem { Label("Dictation", systemImage: "mic") }
        }
        .frame(width: 420, height: 600)
        .onAppear {
            refreshApps()
            refreshDictationLocales()
        }
    }

    // MARK: - Shortcut Tab

    private var shortcutTab: some View {
        Form {
            Section {
                Picker("Input Mode", selection: $settings.inputMode) {
                    Text("Mouse").tag(SettingsService.InputMode.mouse)
                    Text("Trackpad").tag(SettingsService.InputMode.trackpad)
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.inputMode) { settings.save() }

                Text(settings.inputMode == .mouse
                    ? "Optimized for mouse. Hover to select, click to switch."
                    : "Larger targets and sticky selection for trackpad use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Activation Method", selection: $settings.triggerType) {
                    Text("Keyboard").tag(SettingsService.TriggerType.keyboard)
                    Text("Mouse Button").tag(SettingsService.TriggerType.mouseButton)
                    Text("Both").tag(SettingsService.TriggerType.both)
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.triggerType) { settings.save() }
            }

            if settings.triggerType == .keyboard || settings.triggerType == .both {
                Section("Keyboard Shortcut") {
                    ShortcutRecorderView(settings: settings)
                }
            }

            if settings.triggerType == .mouseButton || settings.triggerType == .both {
                Section("Mouse Button") {
                    Picker("Button", selection: $settings.mouseButton) {
                        Text("Middle Button").tag(2)
                        Text("Button 4 (Back)").tag(3)
                        Text("Button 5 (Forward)").tag(4)
                    }
                    .onChange(of: settings.mouseButton) { settings.save() }

                    Text("Click the selected mouse button anywhere to open Orbit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Edge Activation", isOn: $settings.edgeActivation)
                    .onChange(of: settings.edgeActivation) { settings.save() }

                Text("Automatically switch to the selected app when the cursor reaches the edge of the ring. No click needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Pinned Tab

    private var pinnedTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pinned apps always appear first in the ring, in this order.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)

            // Pinned apps (reorderable)
            if !settings.pinnedBundleIds.isEmpty {
                List {
                    ForEach(pinnedAppInfos, id: \.bundleId) { app in
                        HStack(spacing: 10) {
                            Image(nsImage: app.icon)
                                .resizable()
                                .frame(width: 28, height: 28)

                            Text(app.name)
                                .lineLimit(1)

                            Spacer()

                            Button {
                                settings.pinnedBundleIds.removeAll { $0 == app.bundleId }
                                settings.save()
                            } label: {
                                Image(systemName: "pin.slash")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { from, to in
                        settings.pinnedBundleIds.move(fromOffsets: from, toOffset: to)
                        settings.save()
                    }
                }
            } else {
                Spacer()
                Text("No pinned apps yet.\nPin apps from the list below.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }

            Divider()

            // Available apps to pin
            Text("Running Apps")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            List(unpinnedApps) { app in
                HStack(spacing: 10) {
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 28, height: 28)

                    Text(app.name)
                        .lineLimit(1)

                    Spacer()

                    Button {
                        settings.pinnedBundleIds.append(app.bundleId)
                        settings.save()
                    } label: {
                        Image(systemName: "pin")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }

            HStack {
                Button("Refresh") { refreshApps() }
                    .buttonStyle(.borderless)
                Spacer()
                Text("\(settings.pinnedBundleIds.count) pinned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Apps Tab

    private var appsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose which apps appear in the Orbit ring.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)

            List(allApps) { app in
                HStack(spacing: 10) {
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 28, height: 28)

                    Text(app.name)
                        .lineLimit(1)

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { !settings.excludedBundleIds.contains(app.bundleId) },
                        set: { visible in
                            if visible {
                                settings.excludedBundleIds.remove(app.bundleId)
                            } else {
                                settings.excludedBundleIds.insert(app.bundleId)
                            }
                            settings.save()
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                .padding(.vertical, 2)
            }

            HStack {
                Button("Refresh") { refreshApps() }
                    .buttonStyle(.borderless)
                Spacer()
                Text("\(settings.excludedBundleIds.count) hidden")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Dictation Tab

    private var dictationTab: some View {
        Form {
            Section {
                Toggle("Show dictation languages in the ring", isOn: $settings.dictationEnabled)
                    .onChange(of: settings.dictationEnabled) { settings.save() }

                Text("When on, two language tiles appear at the start of the Orbit ring. Selecting one switches the macOS Dictation language and immediately starts dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.dictationEnabled {
                Section("Languages") {
                    if enabledDictationLocales.isEmpty {
                        Text("No dictation languages are enabled in System Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        dictationLanguagePicker(
                            title: "Language 1",
                            selection: $settings.dictationLanguage1Id
                        )
                        dictationLanguagePicker(
                            title: "Language 2",
                            selection: $settings.dictationLanguage2Id
                        )
                    }

                    Button("Add more languages in System Settings\u{2026}") {
                        openDictationSystemSettings()
                    }
                    .buttonStyle(.borderless)

                    Button("Refresh list") { refreshDictationLocales() }
                        .buttonStyle(.borderless)
                }

                Section("Status") {
                    HStack {
                        Text("Current dictation language")
                        Spacer()
                        Text(DictationService.currentLanguage() ?? "\u{2014}")
                            .foregroundStyle(.secondary)
                    }
                    dictationShortcutStatusRow
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func dictationLanguagePicker(
        title: String,
        selection: Binding<String?>
    ) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag(String?.none)
            ForEach(enabledDictationLocales) { language in
                Text("\(language.flagEmoji)  \(language.displayName)")
                    .tag(Optional(language.id))
            }
        }
        .onChange(of: selection.wrappedValue) { settings.save() }
    }

    @ViewBuilder
    private var dictationShortcutStatusRow: some View {
        if DictationService.dictationShortcut() == nil {
            VStack(alignment: .leading, spacing: 6) {
                Label("No dictation shortcut set", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("The default “Press Fn twice” cannot be triggered programmatically. Choose a keyboard shortcut in System Settings → Keyboard → Dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open System Settings") { openDictationSystemSettings() }
                    .buttonStyle(.borderless)
            }
        } else {
            HStack {
                Text("Dictation shortcut")
                Spacer()
                Text("Configured ✓")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func refreshDictationLocales() {
        enabledDictationLocales = DictationService.enabledLocales()
    }

    private func openDictationSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Dictation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Helpers

    private var pinnedAppInfos: [AppInfo] {
        settings.pinnedBundleIds.compactMap { bundleId in
            allApps.first { $0.bundleId == bundleId }
        }
    }

    private var unpinnedApps: [AppInfo] {
        let pinned = Set(settings.pinnedBundleIds)
        return allApps.filter { !pinned.contains($0.bundleId) }
    }

    private func refreshApps() {
        allApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AppInfo? in
                guard let name = app.localizedName,
                      let bundleId = app.bundleIdentifier else { return nil }
                return AppInfo(
                    bundleId: bundleId,
                    name: name,
                    icon: app.icon ?? NSImage(size: NSSize(width: 32, height: 32))
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct AppInfo: Identifiable {
    let bundleId: String
    let name: String
    let icon: NSImage
    var id: String { bundleId }
}
