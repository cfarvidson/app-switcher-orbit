import AppKit
import AVFoundation
import CoreAudio
import CoreGraphics
import FluidAudio
import Foundation
import os

/// In-process speech recognition powered by Parakeet TDT 0.6B v3 (NVIDIA's
/// transducer ASR running on Apple Silicon via CoreML, through the
/// FluidAudio package).
///
/// Replaces the previous WhisperKit implementation. Parakeet reaches
/// comparable transcription quality at 600M parameters instead of 1.55B,
/// auto-detects language across 25 European languages, and emits
/// punctuation and capitalization. It has no translation mode and takes no
/// language parameter - both of which the surrounding UI used to expose.
///
/// Pipeline:
///   1. `AVAudioEngine` taps the input node and accumulates samples in a
///      ring buffer (16 kHz mono float, the format Parakeet expects).
///   2. Voice activity detection flushes the buffer to
///      `AsrManager.transcribe(_:decoderState:language:)` once the user
///      pauses (see the VAD section below).
///   3. When the resulting transcript extends what we've already injected,
///      we type the new portion via `CGEvent.keyboardSetUnicodeString`.
///   4. ESC or any other physical keypress stops the session. Click on the
///      indicator stops it. Re-triggering Orbit stops it.
///
/// Lazy model load: FluidAudio downloads the Parakeet CoreML model bundle on
/// first use. There is only one supported model; Settings'
/// `dictationModelName` selection is temporarily ignored (Task 4 removes it).
final class SpeechRecognitionService: ObservableObject {
    static let shared = SpeechRecognitionService()

    private let log = Logger(subsystem: "com.orbit.appswitcher", category: "speech")

    /// Model lifecycle state, observable from SwiftUI Settings views.
    enum ModelStatus: Equatable {
        case notDownloaded
        case downloading(progress: Double, modelName: String)  // 0..1
        case loading(modelName: String)
        case ready(modelName: String)
        case error(String)
    }

    @Published var modelStatus: ModelStatus = .notDownloaded

    // MARK: - Parakeet setup

    /// Display name for the one and only supported model. Shown in Settings.
    static let modelDisplayName = "Parakeet TDT 0.6B v3"

    private var asrManager: AsrManager?
    private var modelsLoading: Bool = false

    // MARK: - Audio capture

    private let audioEngine = AVAudioEngine()
    /// Whisper expects 16 kHz mono float samples. AVAudioEngine's default
    /// input format is the device sample rate; we convert via AVAudioConverter.
    private var converter: AVAudioConverter?
    private let targetSampleRate: Double = 16_000
    private var audioBuffer: [Float] = []
    private let audioBufferQueue = DispatchQueue(label: "com.orbit.speech.buffer")

    // MARK: - Voice activity detection (VAD-based chunking)
    //
    // We don't transcribe on a fixed timer because Whisper re-transcribes
    // the whole buffer each pass with more context, so the result drifts
    // (e.g. "stad oskiven omting" → "starta och skriva någonting"). Instead
    // we wait for the user to pause, transcribe the captured utterance once,
    // inject it cleanly, and reset the buffer for the next utterance.
    //
    // RMS-based VAD: each tap callback computes the RMS amplitude of the
    // converted samples. Above threshold = speech; below = silence. After
    // `SettingsService.shared.dictationSilenceTriggerSeconds` of continuous
    // silence following speech, we transcribe whatever we have.

    /// Amplitude threshold (RMS, 0..1). Tuned empirically for typical mic
    /// gain — quiet speech still passes, baseline room noise doesn't.
    private let speechRmsThreshold: Float = 0.012
    /// Minimum buffered speech duration before we bother transcribing.
    private let minSpeechSeconds: Double = 0.3
    /// Hard cap on the audio buffer to prevent runaway memory if VAD never
    /// triggers (e.g. user holds an "uhhhhh"). 25s is plenty for any
    /// utterance worth transcribing in one pass.
    private let maxBufferSeconds: Double = 25.0

    private var hasSpeechInBuffer: Bool = false
    private var silentSamplesAfterSpeech: Int = 0
    private var transcribing: Bool = false

    // MARK: - Stop / interaction

    private var escMonitor: Any?
    private var hardCapWorkItem: DispatchWorkItem?
    private var injectedSoFar: String = ""
    private(set) var isRunning: Bool = false
    private var indicatorPanel: RecordingIndicatorPanel?

    private var starting: Bool = false
    private var lastStartTime: CFTimeInterval = 0
    private let startLockout: CFTimeInterval = 0.75

    /// Set just before each `injectText` so the keypress monitor can ignore
    /// the resulting events instead of self-terminating.
    private var lastInjectionTime: CFTimeInterval = 0
    private let injectionGracePeriod: CFTimeInterval = 0.25

    private var hasReceivedFirstAudioBuffer: Bool = false

    /// Circular buffer holding the most recent ~2 seconds of audio captured
    /// during warmup (before the user clicks a tile). On tile click, the
    /// contents are prepended to the session's `audioBuffer` so the first
    /// phoneme spoken at click time is not lost to engine startup latency.
    private var prerollBuffer: [Float] = []
    private let prerollMaxSamples: Int = 32_000  // 2.0s at 16 kHz mono

    /// True while the service is running the engine in warmup mode (no
    /// active session). The tap callback uses this flag to decide whether
    /// new samples go to `prerollBuffer` (circular) or `audioBuffer` (append).
    private var isInPrerollMode: Bool = false

    /// True once the engine has been started for warmup. Tracks whether
    /// `cancelWarmup()` actually needs to do anything.
    private var warmupActive: Bool = false

    private init() {}

    // MARK: - Public API

    /// Pre-load the model into RAM at app launch IF it's already
    /// downloaded. We never trigger a download from prewarm — downloads
    /// only happen when the user explicitly clicks "Download" in Settings,
    /// so the user always knows what's happening on the network.
    func prewarm() {
        guard isModelDownloaded() else {
            NSLog("[Orbit.speech] prewarm skipped - Parakeet model not downloaded")
            modelStatus = .notDownloaded
            return
        }
        Task { @MainActor in
            await downloadAndLoadModel()
        }
    }

    /// Start a regular (non-translating) dictation session in `localeId`.
    /// Parakeet transcribes audio (auto-detecting language) and pastes the
    /// transcript into the frontmost app.
    /// TEMPORARY signature (Task 1): `localeId` is ignored by the engine but
    /// still used for the recording indicator's flag/label. Removed in Task 3.
    func startDictation(localeId: String, onError: @escaping (String) -> Void = { _ in }) {
        startInternal(localeId: localeId, onError: onError)
    }

    /// Starts the audio engine in warmup mode without showing an indicator
    /// or committing to a session. Fills a circular preroll buffer with
    /// recent audio so a subsequent `startDictation` call can promote the
    /// warmup into an active session with the last ~2 seconds of audio
    /// already captured.
    ///
    /// Idempotent — calling while warmup or a session is already running
    /// is a no-op. Silently does nothing if mic permission is not granted
    /// (we never want to surprise the user with a permission prompt just
    /// for opening the ring).
    func warmupAudioCapture() {
        // Don't disturb an active session.
        if isRunning { return }
        // Don't double-warm.
        if warmupActive { return }
        // Permission gate. We use the synchronous status check (not
        // requestAccess) so opening the ring never triggers a prompt.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }

        // Honor the user's selected input device, same as beginCapture does.
        if let uid = SettingsService.shared.dictationInputDeviceUID,
           let deviceID = AudioInputDeviceService.audioDeviceID(forUID: uid),
           let audioUnit = audioEngine.inputNode.audioUnit
        {
            var mutableID = deviceID
            _ = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &mutableID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            NSLog("[Orbit.speech] warmup: failed to build target format")
            return
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        audioBufferQueue.sync {
            prerollBuffer.removeAll(keepingCapacity: true)
        }
        isInPrerollMode = true
        warmupActive = true

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, targetFormat: targetFormat)
        }

        audioEngine.prepare()
        do {
            // NOTE: starting the engine lights the macOS mic privacy LED in the
            // menu bar, even though we're not committing to a session. This is the
            // price of pre-roll capture: we trade a brief LED flicker for the user
            // not losing the first phoneme of speech to engine startup latency.
            try audioEngine.start()
            NSLog("[Orbit.speech] warmup started")
        } catch {
            NSLog("[Orbit.speech] warmup start failed: \(error.localizedDescription)")
            warmupActive = false
            isInPrerollMode = false
        }
    }

    /// Stops the warmup engine and discards the preroll buffer. Called when
    /// the user dismisses the Orbit ring without clicking a tile. No-op if
    /// warmup isn't running, or if a session is currently active (the
    /// session owns the engine in that case and will tear it down via stop()).
    func cancelWarmup() {
        guard warmupActive else { return }
        if isRunning { return }  // session took over the engine; let it run

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)

        audioBufferQueue.sync {
            prerollBuffer.removeAll(keepingCapacity: true)
        }
        warmupActive = false
        isInPrerollMode = false
        NSLog("[Orbit.speech] warmup cancelled")
    }

    private func startInternal(
        localeId: String,
        onError: @escaping (String) -> Void
    ) {
        let now = CACurrentMediaTime()
        if starting || (now - lastStartTime) < startLockout {
            NSLog("[Orbit.speech] start() suppressed (starting=\(starting), since-last=\(Int((now - lastStartTime) * 1000))ms)")
            return
        }
        starting = true
        lastStartTime = now

        if isRunning {
            stop()
        }

        // Hard pre-flight: if the model isn't downloaded yet, refuse to
        // start and tell the user where to set it up. We never trigger
        // automatic downloads from a tile click — downloads happen only
        // from Settings → Dictation so the user is aware of the network
        // activity and disk usage.
        guard isModelDownloaded() else {
            NSLog("[Orbit.speech] start aborted - Parakeet model not downloaded")
            starting = false
            onError("Speech model not downloaded. Set it up in Settings → Dictation.")
            showSetupReminderNotification()
            return
        }

        // Replace any existing indicator so we anchor near the user's
        // current cursor and use the right locale.
        if indicatorPanel != nil {
            indicatorPanel?.hideIndicator()
            indicatorPanel = nil
        }

        // Show the indicator immediately so the user gets feedback. The
        // model is downloaded but might still be loading into RAM.
        let initialState: RecordingIndicatorPanel.State =
            (asrManager == nil) ? .loading(message: "Loading model\u{2026}") : .listening
        showIndicator(localeId: localeId, state: initialState)

        ensurePermissions { [weak self] granted in
            guard let self else { return }
            guard granted else {
                NSLog("[Orbit.speech] permission denied")
                self.starting = false
                DispatchQueue.main.async {
                    self.indicatorPanel?.hideIndicator()
                    self.indicatorPanel = nil
                    onError("Microphone permission denied")
                    self.showMicPermissionAlert()
                }
                return
            }
            Task { @MainActor in
                await self.ensureModelsLoaded(onError: onError)
                if self.asrManager != nil {
                    if self.warmupActive {
                        self.promoteWarmupToSession(localeId: localeId)
                    } else {
                        self.indicatorPanel?.updateState(.starting)
                        self.beginCapture(localeId: localeId, onError: onError)
                    }
                }
                self.starting = false
            }
        }
    }

    /// User-friendly NSAlert pointing the user to Settings if they try to
    /// dictate before the model is downloaded. Non-blocking — runs as an
    /// independent dialog so it doesn't interrupt anything.
    private func showSetupReminderNotification() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Dictation needs setup"
            alert.informativeText = "Open Orbit Settings → Dictation and download a speech model before using the language tiles."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Settings\u{2026}")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn {
                NotificationCenter.default.post(name: .orbitOpenSettings, object: nil)
            }
        }
    }

    /// Shown when the user clicks a language tile but has previously denied
    /// microphone access. Without this the failure is silent — Orbit just
    /// dismisses and nothing happens, which is the symptom of "dictation
    /// doesn't work" most users hit after a rebuild invalidates TCC.
    private func showMicPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone access denied"
        alert.informativeText = "Orbit needs microphone access to dictate. Enable it in System Settings → Privacy & Security → Microphone, then try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Privacy Settings\u{2026}")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        {
            NSWorkspace.shared.open(url)
        }
    }

    /// Stops the dictation session.
    /// - Parameters:
    ///   - reason: Free-form label for the log line.
    ///   - flushBuffer: When `true` (the default), any speech still in the
    ///     audio buffer is transcribed and injected as a final utterance
    ///     before tearing down. When `false`, the buffer is discarded —
    ///     used by ESC because the macOS Dictation convention is "ESC
    ///     cancels". The hotkey re-trigger and the indicator click both
    ///     commit (flushBuffer=true) because pressing those means "I'm
    ///     done", not "throw it away".
    func stop(reason: String = "explicit", flushBuffer: Bool = true) {
        hardCapWorkItem?.cancel()
        hardCapWorkItem = nil

        guard isRunning else { return }
        NSLog("[Orbit.speech] stop reason=\(reason) flush=\(flushBuffer)")

        // Snapshot whatever audio is in the buffer BEFORE tearing down
        // the engine. If the user spoke and then pressed the hotkey to
        // stop (which is the natural "I'm done" gesture), VAD probably
        // hasn't fired yet because they didn't sit through 0.8s of
        // silence. We do not want to lose that audio — flush it as the
        // session's final transcript.
        let finalSnapshot: [Float] = audioBufferQueue.sync {
            let copy = audioBuffer
            audioBuffer.removeAll()
            return copy
        }
        let hadSpeech = hasSpeechInBuffer

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)

        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }

        indicatorPanel?.hideIndicator()
        indicatorPanel = nil

        hasSpeechInBuffer = false
        silentSamplesAfterSpeech = 0
        hasReceivedFirstAudioBuffer = false
        warmupActive = false
        isInPrerollMode = false
        isRunning = false

        // Final flush. Runs async — by the time the transcript lands,
        // the indicator is already hidden and the user has presumably
        // refocused their target text field. We deliberately do NOT
        // reset `injectedSoFar` until after the final flush has been
        // dispatched so multi-utterance sessions still get the leading
        // space treatment for the last chunk.
        // The `!transcribing` clause: if a VAD-triggered flushAndTranscribe
        // Task is already in flight (the user spoke, VAD fired, Parakeet is
        // mid-decode), we skip the final flush here. The original Task will
        // still inject its transcript when it completes, so the audio that
        // triggered VAD is NOT lost. What we discard is whatever fragment
        // was captured between the VAD flush dispatch and this stop() —
        // typically a few hundred ms of mid-utterance speech, which would
        // produce broken text if transcribed in isolation. Trade-off: we
        // accept losing that fragment in exchange for never producing
        // garbled half-word output at session end.
        let minSamples = Int(targetSampleRate * minSpeechSeconds)
        if flushBuffer, hadSpeech, finalSnapshot.count > minSamples, let manager = asrManager, !transcribing {
            NSLog("[Orbit.speech] stop: final flush \(String(format: "%.2f", Double(finalSnapshot.count) / targetSampleRate))s audio")
            transcribing = true
            Task { [weak self] in
                guard let self else { return }
                do {
                    // Fresh decoder state per utterance: each flush is a
                    // complete, independent utterance (see the VAD comment
                    // above), so there's no continuity to carry across calls.
                    let decoderLayers = await manager.decoderLayerCount
                    var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
                    let result = try await manager.transcribe(finalSnapshot, decoderState: &decoderState)
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run {
                        self.handleFlushedTranscript(text)
                        self.injectedSoFar = ""
                        self.transcribing = false
                    }
                } catch {
                    NSLog("[Orbit.speech] final flush transcribe error: \(error.localizedDescription)")
                    await MainActor.run {
                        self.injectedSoFar = ""
                        self.transcribing = false
                    }
                }
            }
        } else {
            injectedSoFar = ""
        }
    }

    // MARK: - Model availability + download

    /// Returns true if the Parakeet model files are present in FluidAudio's
    /// cache. Doesn't trigger any network or load. The `modelName` argument
    /// is ignored - there is exactly one supported model.
    /// TEMPORARY signature (Task 1): the argument is removed in Task 4.
    func isModelDownloaded(_ modelName: String = SpeechRecognitionService.modelDisplayName) -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    /// Public entry point used by the Settings UI. Downloads the model if
    /// needed (with progress) and loads it into memory. Updates
    /// `modelStatus` throughout the lifecycle. Idempotent — calling while a
    /// download is already in flight is a no-op.
    /// TEMPORARY signature (Task 1): the argument is removed in Task 4.
    @MainActor
    func downloadAndLoadModel(_ modelName: String = SpeechRecognitionService.modelDisplayName) async {
        if modelsLoading { return }
        if asrManager != nil {
            modelStatus = .ready(modelName: Self.modelDisplayName)
            return
        }
        modelsLoading = true
        defer { modelsLoading = false }

        do {
            modelStatus = .downloading(progress: 0, modelName: Self.modelDisplayName)
            NSLog("[Orbit.speech] downloading/loading \(Self.modelDisplayName)…")
            let models = try await AsrModels.downloadAndLoad(version: .v3) { progress in
                Task { @MainActor in
                    self.modelStatus = .downloading(
                        progress: progress.fractionCompleted,
                        modelName: Self.modelDisplayName
                    )
                }
            }
            modelStatus = .loading(modelName: Self.modelDisplayName)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asrManager = manager
            modelStatus = .ready(modelName: Self.modelDisplayName)
            NSLog("[Orbit.speech] Parakeet ready")
        } catch {
            NSLog("[Orbit.speech] downloadAndLoadModel failed: \(error)")
            asrManager = nil
            modelStatus = .error(error.localizedDescription)
        }
    }

    // MARK: - Parakeet lazy load (during dictation start)

    @MainActor
    private func ensureModelsLoaded(onError: @escaping (String) -> Void) async {
        if asrManager != nil { return }
        await downloadAndLoadModel()
        if asrManager == nil {
            onError("Failed to load the Parakeet model. Set up dictation in Settings → Dictation.")
            indicatorPanel?.hideIndicator()
            indicatorPanel = nil
        }
    }

    // MARK: - Permissions

    private func ensurePermissions(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                completion(granted)
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    // MARK: - Audio capture and chunked transcription

    /// Transition from warmup mode to an active session. Engine and tap are
    /// already running from `warmupAudioCapture`; we just snapshot the
    /// preroll into the session buffer, flip the mode flag, and update the
    /// indicator. The next audio tap callback will write to `audioBuffer`
    /// instead of `prerollBuffer`.
    private func promoteWarmupToSession(localeId: String) {
        audioBufferQueue.sync {
            audioBuffer.removeAll(keepingCapacity: true)
            audioBuffer.append(contentsOf: prerollBuffer)
            prerollBuffer.removeAll(keepingCapacity: true)
            isInPrerollMode = false
            hasSpeechInBuffer = false
            silentSamplesAfterSpeech = 0
            hasReceivedFirstAudioBuffer = true
        }
        warmupActive = false
        installEscMonitor()
        scheduleHardCap()
        isRunning = true
        // The engine has been delivering buffers since warmup; flip indicator
        // straight to .listening (skip the .starting state, no startup gap).
        indicatorPanel?.updateState(.listening)
        NSLog("[Orbit.speech] promoted warmup to session for locale \(localeId), preroll=\(audioBuffer.count) samples")
    }

    private func beginCapture(localeId: String, onError: @escaping (String) -> Void) {
        // Configure input device BEFORE reading inputNode.outputFormat — the
        // format depends on whichever device the input unit is bound to, and
        // the tap install below uses that format. The user's stored UID is
        // resolved to a current AudioDeviceID; if the device is no longer
        // connected (UID not found), we fall through silently and the engine
        // uses the system default. We do not show an alert because unplugging
        // a mic is a normal, expected user action.
        if let uid = SettingsService.shared.dictationInputDeviceUID {
            if let deviceID = AudioInputDeviceService.audioDeviceID(forUID: uid) {
                var mutableID = deviceID
                if let audioUnit = audioEngine.inputNode.audioUnit {
                    let status = AudioUnitSetProperty(
                        audioUnit,
                        kAudioOutputUnitProperty_CurrentDevice,
                        kAudioUnitScope_Global,
                        0,
                        &mutableID,
                        UInt32(MemoryLayout<AudioDeviceID>.size)
                    )
                    if status == noErr {
                        NSLog("[Orbit.speech] input device set to \(uid)")
                    } else {
                        NSLog(
                            "[Orbit.speech] failed to set input device \(uid): OSStatus=\(status) — falling back to system default"
                        )
                    }
                } else {
                    NSLog("[Orbit.speech] inputNode.audioUnit is nil — cannot set device, using system default")
                }
            } else {
                NSLog("[Orbit.speech] stored input device \(uid) is not connected — falling back to system default")
            }
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Whisper wants 16 kHz mono Float32. Build a converter from whatever
        // the input device gives us.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            NSLog("[Orbit.speech] failed to build target audio format")
            onError("Failed to configure audio format")
            return
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, targetFormat: targetFormat)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            NSLog("[Orbit.speech] audio engine failed to start: \(error)")
            onError("Audio engine failed to start: \(error.localizedDescription)")
            indicatorPanel?.hideIndicator()
            indicatorPanel = nil
            return
        }

        installEscMonitor()
        scheduleHardCap()
        isRunning = true
        NSLog("[Orbit.speech] capture started for locale \(localeId)")
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let converter else { return }

        // Convert to 16 kHz mono float and append to the rolling buffer.
        let inputFrames = buffer.frameLength
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrames = AVAudioFrameCount(Double(inputFrames) * ratio + 64)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrames
        ) else { return }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error || error != nil {
            NSLog("[Orbit.speech] audio conversion error: \(error?.localizedDescription ?? "unknown")")
            return
        }

        guard let channelData = outputBuffer.floatChannelData?[0] else { return }
        let frameCount = Int(outputBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))

        // RMS computed outside the queue (cheap, doesn't need locking).
        let rms = computeRMS(samples)
        let isSpeech = rms > speechRmsThreshold

        var shouldFlush = false
        var bufferDuration: Double = 0
        var shouldFlipToListening = false

        audioBufferQueue.sync {
            if isInPrerollMode {
                // Warmup mode: append to circular preroll buffer, evict
                // oldest samples when over capacity. No VAD, no flush.
                prerollBuffer.append(contentsOf: samples)
                if prerollBuffer.count > prerollMaxSamples {
                    prerollBuffer.removeFirst(prerollBuffer.count - prerollMaxSamples)
                }
                return
            }

            // Session mode: first-buffer indicator hook (Task 14b).
            // Read and write under the queue to avoid a data race with
            // the main-thread writers (warmupAudioCapture, cancelWarmup,
            // promoteWarmupToSession, stop).
            if !hasReceivedFirstAudioBuffer {
                hasReceivedFirstAudioBuffer = true
                shouldFlipToListening = true
            }

            audioBuffer.append(contentsOf: samples)
            bufferDuration = Double(audioBuffer.count) / targetSampleRate

            if isSpeech {
                hasSpeechInBuffer = true
                silentSamplesAfterSpeech = 0
            } else if hasSpeechInBuffer {
                silentSamplesAfterSpeech += frameCount
                let silentSeconds = Double(silentSamplesAfterSpeech) / targetSampleRate
                let speechSeconds = bufferDuration - silentSeconds
                if silentSeconds >= SettingsService.shared.dictationSilenceTriggerSeconds,
                   speechSeconds >= minSpeechSeconds
                {
                    shouldFlush = true
                }
            }

            // Hard cap on buffer length: if VAD never triggers, force a
            // flush so we don't accumulate forever.
            if bufferDuration >= maxBufferSeconds, hasSpeechInBuffer {
                shouldFlush = true
            }
        }

        if shouldFlipToListening {
            DispatchQueue.main.async { [weak self] in
                self?.indicatorPanel?.updateState(.listening)
            }
        }

        if shouldFlush {
            flushAndTranscribe()
        }
    }

    private func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Hand the currently buffered audio to Parakeet, then clear the buffer
    /// and reset the VAD state for the next utterance.
    private func flushAndTranscribe() {
        guard isRunning, !transcribing, let manager = asrManager else { return }

        let snapshot: [Float] = audioBufferQueue.sync {
            let copy = audioBuffer
            audioBuffer.removeAll(keepingCapacity: true)
            hasSpeechInBuffer = false
            silentSamplesAfterSpeech = 0
            return copy
        }

        guard snapshot.count > Int(targetSampleRate * minSpeechSeconds) else { return }

        transcribing = true
        NSLog("[Orbit.speech] flushing \(Double(snapshot.count) / targetSampleRate)s of audio for transcription")

        Task { [weak self] in
            guard let self else { return }
            do {
                // Fresh decoder state per utterance: each flush is a
                // complete, independent utterance (see the VAD comment
                // above), so there's no continuity to carry across calls.
                let decoderLayers = await manager.decoderLayerCount
                var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
                let result = try await manager.transcribe(snapshot, decoderState: &decoderState)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    self.handleFlushedTranscript(text)
                    self.transcribing = false
                }
            } catch {
                NSLog("[Orbit.speech] transcribe error: \(error.localizedDescription)")
                await MainActor.run { self.transcribing = false }
            }
        }
    }

    // MARK: - Transcript handling and text injection

    /// Each flush is a complete utterance (we wait for silence before
    /// transcribing), so there's no diffing or revision handling — just
    /// inject the whole thing with a leading space if we've already injected
    /// something earlier in the session.
    private func handleFlushedTranscript(_ transcript: String) {
        guard !transcript.isEmpty else { return }
        NSLog("[Orbit.speech] flushed transcript=\(transcript)")

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { return }
        if trimmed.hasPrefix("(") && trimmed.hasSuffix(")") { return }

        // Strip ellipsis in case the model emits "..." or "…" when the
        // speaker pauses mid-sentence (interpreted as trailing-off). For
        // dictation this just pollutes natural speech with ellipsis the
        // user didn't intend. We strip both the ASCII three-dot form and
        // the Unicode single-glyph form, then collapse any resulting
        // double-spaces.
        let cleaned = trimmed
            .replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: "\u{2026}", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        // Add a leading space if we've already typed an utterance in this
        // session, so consecutive utterances are separated by a space.
        let toInject = injectedSoFar.isEmpty ? cleaned : " " + cleaned
        injectText(toInject)
        injectedSoFar += toInject
    }

    private func injectText(_ text: String) {
        guard !text.isEmpty,
              let source = CGEventSource(stateID: .hidSystemState)
        else {
            NSLog("[Orbit.speech] injectText skipped (empty or no event source)")
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        let axTrusted = AXIsProcessTrusted()
        NSLog("[Orbit.speech] inject pre-flight: frontApp=\(frontApp?.localizedName ?? "nil") bundleId=\(frontApp?.bundleIdentifier ?? "nil") axTrusted=\(axTrusted)")

        // Inject via clipboard paste rather than synthesized
        // `keyboardSetUnicodeString` events. Reasons:
        //
        // 1. Electron / Chromium apps (Cursor, VS Code, Slack, Discord,
        //    Notion, etc.) ignore CGEvent keystrokes that have
        //    `virtualKey: 0`. Chromium's input layer validates the key
        //    code against the platform keymap and drops events with no
        //    real key, regardless of the unicode payload.
        // 2. Many native apps also dislike unicode-only events for
        //    non-ASCII characters; the å in "hallå" may roundtrip via
        //    layout-dependent paths.
        // 3. Cmd+V is universal: every text-accepting app on macOS handles
        //    it identically because it goes through the standard responder
        //    chain and the OS-level paste action.
        //
        // Trade-offs we accept: we briefly clobber the user's clipboard
        // and restore it ~300ms later. We mark BOTH writes (the transcript
        // and the restore) as transient via the nspasteboard.org community
        // convention so clipboard history managers (Maccy, Paste, Pastebot,
        // Raycast, Alfred, …) skip them entirely. The user's original
        // entry already exists in their history from before Orbit touched
        // anything, so the restore doesn't need to land in history either.
        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)
        Self.setTransientPasteboardString(text, on: pasteboard)

        // Cmd+V via .cghidEventTap so it flows through the standard event
        // pipeline exactly as if the user pressed it physically.
        let vKey: CGKeyCode = 9  // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        lastInjectionTime = CACurrentMediaTime()
        NSLog("[Orbit.speech] pasted \(text.count) chars via Cmd+V (transient)")

        // Restore the previous pasteboard contents after the paste has
        // had time to land in the target app. 300ms is a conservative
        // ceiling for paste latency on macOS even on slow Electron apps.
        if let saved = savedString {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                Self.setTransientPasteboardString(saved, on: pasteboard)
            }
        }
    }

    /// Writes `value` to `pasteboard` and marks the entry as transient so
    /// clipboard history managers skip it. The marker types come from the
    /// nspasteboard.org community convention honored by Maccy, Paste,
    /// Pastebot, Raycast clipboard, Alfred Snippets, and others. Important:
    /// the markers must be declared BEFORE the actual content type so the
    /// manager sees them when it observes the new pasteboard generation.
    private static func setTransientPasteboardString(_ value: String, on pasteboard: NSPasteboard) {
        let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let autoGenType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
        pasteboard.clearContents()
        // Declare the marker types up front in the same call as the
        // string type. Some managers only look at declaredTypes during
        // the initial declaration, not at subsequent setData calls.
        pasteboard.declareTypes([transientType, concealedType, autoGenType, .string], owner: nil)
        pasteboard.setData(Data(), forType: transientType)
        pasteboard.setData(Data(), forType: concealedType)
        pasteboard.setData(Data(), forType: autoGenType)
        pasteboard.setString(value, forType: .string)
    }

    // MARK: - Stop triggers

    private func installEscMonitor() {
        // ESC-only stop. The "stop on any keypress" variant was killing
        // legitimate dictation sessions whenever any incidental keystroke
        // arrived between audio capture and Whisper finishing transcription
        // (~600ms latency). Users who want to switch from dictation to
        // typing should press ESC, click the indicator, or re-trigger Orbit.
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            if event.keyCode != 53 { return }  // kVK_Escape
            // ESC = cancel (matches macOS Dictation). Discards the audio
            // buffer instead of transcribing it.
            DispatchQueue.main.async { self.stop(reason: "esc", flushBuffer: false) }
        }
    }

    private func scheduleHardCap() {
        let work = DispatchWorkItem { [weak self] in
            self?.stop(reason: "60s hard cap")
        }
        hardCapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    // MARK: - Indicator

    private func showIndicator(localeId: String, state: RecordingIndicatorPanel.State) {
        let panel = RecordingIndicatorPanel()
        panel.show(localeId: localeId, state: state) { [weak self] in
            DispatchQueue.main.async { self?.stop(reason: "indicator click") }
        }
        indicatorPanel = panel
    }
}

extension Notification.Name {
    /// Posted by `SpeechRecognitionService` when the user clicks "Open
    /// Settings…" on the missing-model alert. `AppDelegate` listens for it
    /// and opens its Settings window.
    static let orbitOpenSettings = Notification.Name("OrbitOpenSettings")
}

private extension String {
    func chunked(by n: Int) -> [String] {
        guard n > 0, !isEmpty else { return [self] }
        var result: [String] = []
        var start = startIndex
        while start < endIndex {
            let end = index(start, offsetBy: n, limitedBy: endIndex) ?? endIndex
            result.append(String(self[start..<end]))
            start = end
        }
        return result
    }
}
