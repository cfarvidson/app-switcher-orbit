import Carbon
import SwiftUI

/// Catalog of WhisperKit models the user can pick from in Settings. The
/// model identifier matches the `variant` argument WhisperKit's downloader
/// expects (and corresponds to a folder in
/// `argmaxinc/whisperkit-coreml` on Hugging Face).
struct WhisperModelOption: Identifiable {
    let id: String
    let label: String
    let description: String

    static let all: [WhisperModelOption] = [
        WhisperModelOption(
            id: "openai_whisper-tiny",
            label: "Tiny (~75 MB)",
            description: "Fastest, lowest quality. Good for testing or very limited disk."
        ),
        WhisperModelOption(
            id: "openai_whisper-base",
            label: "Base (~150 MB)",
            description: "Balanced. Decent quality, fast cold-start."
        ),
        WhisperModelOption(
            id: "openai_whisper-small",
            label: "Small (~500 MB) — recommended",
            description: "Strong sweet spot for dictation. Good multilingual quality, real-time on Apple Silicon."
        ),
        WhisperModelOption(
            id: "openai_whisper-medium",
            label: "Medium (~1.5 GB)",
            description: "High quality. Slower cold-start, more RAM. Best for difficult audio."
        ),
        WhisperModelOption(
            id: "openai_whisper-large-v3-v20240930",
            label: "Large v3 Turbo (~1.5 GB)",
            description: "Apple's Whisper Turbo (Sep 2024) — large-v3 transcription quality at small-like speed."
        ),
        WhisperModelOption(
            id: "openai_whisper-large-v3",
            label: "Large v3 (~2.9 GB)",
            description: "Full Whisper Large v3. Highest quality, but slower and more RAM than Turbo."
        ),
    ]
}

struct SettingsView: View {
    @ObservedObject var settings = SettingsService.shared
    @ObservedObject var speech = SpeechRecognitionService.shared
    @State private var allApps: [AppInfo] = []
    @State private var enabledDictationLocales: [DictationLanguage] = []
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
        .frame(width: 520, height: 800)
        .onAppear {
            refreshApps()
            refreshDictationLocales()
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
                Toggle("Show dictation languages in the ring", isOn: $settings.dictationEnabled)
                    .onChange(of: settings.dictationEnabled) { settings.save() }

                Text("When on, language tiles appear in the Orbit ring. Selecting one starts on-device dictation in that language using a local Whisper model. Recognition runs entirely inside Orbit — no audio leaves your Mac.")
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

                Section("Speech model") {
                    Picker("Model", selection: $settings.dictationModelName) {
                        ForEach(WhisperModelOption.all) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .onChange(of: settings.dictationModelName) {
                        settings.save()
                        let newModel = settings.dictationModelName
                        if speech.isModelDownloaded(newModel) {
                            // Already on disk — load it eagerly so the next
                            // dictation click is instant.
                            Task { await speech.downloadAndLoadModel(newModel) }
                        } else {
                            // Not downloaded — flip the published status so
                            // the status row shows the Download button for
                            // the new selection (otherwise it would still
                            // show the previously-loaded model's "Ready"
                            // state, hiding the button).
                            speech.modelStatus = .notDownloaded
                        }
                    }

                    if let info = WhisperModelOption.all.first(where: { $0.id == settings.dictationModelName }) {
                        Text(info.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    speechModelStatusRow
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
                    Text("How long Whisper waits in silence before transcribing what you've said. Higher values let you pause mid-sentence without fragmenting the output. Default 0.8s.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                Button("Download \(WhisperModelOption.all.first { $0.id == settings.dictationModelName }?.label ?? settings.dictationModelName)") {
                    Task { await speech.downloadAndLoadModel(settings.dictationModelName) }
                }
                .buttonStyle(.bordered)
            }
        case .downloading(let progress, let modelName):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Downloading \(modelName)\u{2026}")
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }
        case .loading(let modelName):
            HStack {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
                Text("Loading \(modelName)\u{2026}")
                    .foregroundStyle(.secondary)
            }
        case .ready(let modelName):
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Ready (\(modelName))")
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
                    Task { await speech.downloadAndLoadModel(settings.dictationModelName) }
                }
                .buttonStyle(.bordered)
            }
        }
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Orbit runs OpenAI Whisper locally via WhisperKit (CoreML on Apple Silicon) — recognition is entirely on-device and bypasses the system Dictation HUD. macOS will prompt for microphone permission the first time you click a language tile. Click the floating indicator or press ESC to stop dictation.")
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

    private func refreshDictationLocales() {
        enabledDictationLocales = DictationService.enabledLocales()
    }

    private func refreshInputDevices() {
        availableInputDevices = AudioInputDeviceService.listInputDevices()
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
