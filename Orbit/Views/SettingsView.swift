import Carbon
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = SettingsService.shared
    @ObservedObject var speech = SpeechRecognitionService.shared
    @State private var allApps: [AppInfo] = []
    @State private var availableInputDevices: [AudioInputDeviceService.Device] = []

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
            layoutTab
                .tabItem { Label("Layout", systemImage: "circle.grid.cross") }
        }
        .frame(minWidth: 520, minHeight: 560)
        .onAppear {
            refreshApps()
            refreshInputDevices()
        }
    }

    // MARK: - Layout Tab

    private var layoutTab: some View {
        VStack(spacing: 0) {
            LayoutPreviewView(settings: settings)
            Spacer()
        }
        .padding()
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
                Toggle("Show the dictation tile in the ring", isOn: $settings.dictationEnabled)
                    .onChange(of: settings.dictationEnabled) {
                        settings.save()
                        if settings.dictationEnabled {
                            // Assign an angle now so the tile appears at a
                            // sensible spot the next time the ring opens.
                            settings.ensurePreferredAngles()
                        }
                    }

                Text("When on, a dictation tile appears in the Orbit ring. Selecting it starts on-device dictation. The spoken language is detected automatically. Recognition runs entirely inside Orbit - no audio leaves your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.dictationEnabled {
                Section("Speech model") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(SpeechRecognitionService.modelDisplayName)
                            .font(.body)
                        Text("Runs on-device via CoreML. Covers 25 European languages with automatic language detection, punctuation and capitalization.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    speechModelStatusRow

                    dictationShortcutStatusRow
                }
            }

            Section("Microphone") {
                Picker("Input device", selection: $settings.dictationInputDeviceUID) {
                    Text("System Default").tag(String?.none)
                    ForEach(availableInputDevices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                    // If the stored UID is not in the enumerated list, show
                    // a "Not connected" placeholder so the user understands
                    // why the picker would otherwise look like it had reset.
                    if let storedUID = settings.dictationInputDeviceUID,
                       !availableInputDevices.contains(where: { $0.uid == storedUID })
                    {
                        Text("\u{26A0}\u{FE0E} Not connected (\(storedUID))")
                            .tag(Optional(storedUID))
                    }
                }
                .onChange(of: settings.dictationInputDeviceUID) { settings.save() }

                Button("Refresh list") { refreshInputDevices() }
                    .buttonStyle(.borderless)

                Text("Orbit uses this microphone for dictation. \"System Default\" follows your macOS audio input setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Pause tolerance")
                        Spacer()
                        Text(String(format: "%.1fs", settings.dictationSilenceTriggerSeconds))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.dictationSilenceTriggerSeconds, in: 0.5...3.0, step: 0.1)
                        .onChange(of: settings.dictationSilenceTriggerSeconds) { settings.save() }
                    Text("How long Orbit waits in silence before transcribing what you've said. Higher values let you pause mid-sentence without fragmenting the output. Default 0.8s.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                DictationLanguagesView()
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private var speechModelStatusRow: some View {
        switch speech.modelStatus {
        case .notDownloaded:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.orange)
                    Text("Not downloaded")
                        .foregroundStyle(.secondary)
                }
                Button("Download \(SpeechRecognitionService.modelDisplayName)") {
                    Task { await speech.downloadAndLoadModel() }
                }
                .buttonStyle(.bordered)
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Downloading\u{2026}")
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }
        case .loading:
            HStack {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
                Text("Loading\u{2026}")
                    .foregroundStyle(.secondary)
            }
        case .ready:
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Ready")
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("Error")
                        .foregroundStyle(.red)
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    Task { await speech.downloadAndLoadModel() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var dictationShortcutStatusRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Orbit runs Parakeet TDT 0.6B v3 locally via FluidAudio (CoreML on Apple Silicon) - recognition is entirely on-device and bypasses the system Dictation HUD. macOS will prompt for microphone permission the first time you start dictation. Re-press the Orbit hotkey or choose Stop Dictation in the menu bar to commit. Press ESC to cancel.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Microphone Privacy\u{2026}") { openMicrophonePrivacy() }
                .buttonStyle(.borderless)
        }
    }

    private func openMicrophonePrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshInputDevices() {
        availableInputDevices = AudioInputDeviceService.listInputDevices()
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
