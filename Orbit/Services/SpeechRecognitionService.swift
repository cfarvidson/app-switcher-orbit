import AppKit
import AVFoundation
import CoreAudio
import CoreGraphics
import Foundation
import WhisperKit
import os

/// In-process speech recognition powered by WhisperKit (OpenAI Whisper
/// running on Apple Silicon via CoreML).
///
/// Replaces the previous `SFSpeechRecognizer` implementation, which had
/// shallow language understanding: bad punctuation outside English, no
/// auto-capitalization, and didn't model sentence boundaries from prosody.
/// Whisper handles all 99 languages with proper punctuation and casing.
///
/// Pipeline:
///   1. `AVAudioEngine` taps the input node and accumulates samples in a
///      ring buffer (16 kHz mono float, the format Whisper expects).
///   2. Every `transcribeInterval` seconds we hand the accumulated buffer
///      to `WhisperKit.transcribe(audioArray:decodeOptions:)`.
///   3. When the resulting transcript extends what we've already injected,
///      we type the new portion via `CGEvent.keyboardSetUnicodeString`.
///   4. ESC or any other physical keypress stops the session. Click on the
///      indicator stops it. Re-triggering Orbit stops it.
///
/// Lazy model load: WhisperKit downloads its CoreML model on first init
/// (~150 MB for "base", ~500 MB for "small"). The model name comes from
/// `SettingsService.dictationModelName` so the user can pick their tradeoff
/// in Settings.
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

    // MARK: - WhisperKit setup

    private var whisperKit: WhisperKit?
    private var whisperKitLoading: Bool = false
    private var loadedModelName: String?

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
    // `silenceTriggerSeconds` of continuous silence following speech, we
    // transcribe whatever we have.

    /// Amplitude threshold (RMS, 0..1). Tuned empirically for typical mic
    /// gain — quiet speech still passes, baseline room noise doesn't.
    private let speechRmsThreshold: Float = 0.012
    /// How long the user has to be silent after speech to trigger a flush.
    private let silenceTriggerSeconds: Double = 0.8
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

    private var currentLocaleId: String = "en_US"
    private var currentTask: DecodingTask = .transcribe
    private var currentTranslationTargetId: String?
    private var hasReceivedFirstAudioBuffer: Bool = false

    private init() {}

    // MARK: - Public API

    /// Pre-load the model into RAM at app launch IF it's already
    /// downloaded. We never trigger a download from prewarm — downloads
    /// only happen when the user explicitly clicks "Download" in Settings,
    /// so the user always knows what's happening on the network.
    func prewarm() {
        let modelName = SettingsService.shared.dictationModelName
        guard isModelDownloaded(modelName) else {
            NSLog("[Orbit.speech] prewarm skipped — model \(modelName) not downloaded")
            modelStatus = .notDownloaded
            return
        }
        Task { @MainActor in
            await downloadAndLoadModel(modelName)
        }
    }

    /// Start a regular (non-translating) dictation session in `localeId`.
    /// Whisper transcribes audio in the same language and pastes the
    /// transcript into the frontmost app.
    func startDictation(localeId: String, onError: @escaping (String) -> Void = { _ in }) {
        startInternal(
            localeId: localeId,
            task: .transcribe,
            targetLocaleIdForDisplay: nil,
            onError: onError
        )
    }

    /// Start a translation session: Whisper takes audio in `sourceLocaleId`
    /// and pastes English text into the frontmost app. The `targetLocaleId`
    /// is purely cosmetic — it controls which `en_*` flag the recording
    /// indicator displays. Whisper itself ignores it (its `.translate` task
    /// always outputs English).
    func startTranslation(
        sourceLocaleId: String,
        targetLocaleId: String,
        onError: @escaping (String) -> Void = { _ in }
    ) {
        startInternal(
            localeId: sourceLocaleId,
            task: .translate,
            targetLocaleIdForDisplay: targetLocaleId,
            onError: onError
        )
    }

    private func startInternal(
        localeId: String,
        task: DecodingTask,
        targetLocaleIdForDisplay: String?,
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

        currentLocaleId = localeId
        currentTask = task
        currentTranslationTargetId = targetLocaleIdForDisplay

        // Hard pre-flight: if the model isn't downloaded yet, refuse to
        // start and tell the user where to set it up. We never trigger
        // automatic downloads from a tile click — downloads happen only
        // from Settings → Dictation so the user is aware of the network
        // activity and disk usage.
        let modelName = SettingsService.shared.dictationModelName
        guard isModelDownloaded(modelName) else {
            NSLog("[Orbit.speech] start aborted — model \(modelName) not downloaded")
            starting = false
            currentTask = .transcribe
            currentTranslationTargetId = nil
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
            (whisperKit == nil) ? .loading(message: "Loading model\u{2026}") : .listening
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
                await self.ensureWhisperKitLoaded(onError: onError)
                if self.whisperKit != nil {
                    self.indicatorPanel?.updateState(.starting)
                    self.beginCapture(localeId: localeId, onError: onError)
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
        isRunning = false

        // Final flush. Runs async — by the time the transcript lands,
        // the indicator is already hidden and the user has presumably
        // refocused their target text field. We deliberately do NOT
        // reset `injectedSoFar` until after the final flush has been
        // dispatched so multi-utterance sessions still get the leading
        // space treatment for the last chunk.
        // The `!transcribing` clause: if a VAD-triggered flushAndTranscribe
        // Task is already in flight (the user spoke, VAD fired, Whisper is
        // mid-decode), we skip the final flush here. The original Task will
        // still inject its transcript when it completes, so the audio that
        // triggered VAD is NOT lost. What we discard is whatever fragment
        // was captured between the VAD flush dispatch and this stop() —
        // typically a few hundred ms of mid-utterance speech, which would
        // produce broken text if transcribed in isolation. Trade-off: we
        // accept losing that fragment in exchange for never producing
        // garbled half-word output at session end.
        let minSamples = Int(targetSampleRate * minSpeechSeconds)
        if flushBuffer, hadSpeech, finalSnapshot.count > minSamples, let kit = whisperKit, !transcribing {
            let bcp47 = currentLocaleId
                .replacingOccurrences(of: "_", with: "-")
                .lowercased()
            let language = String(bcp47.split(separator: "-").first ?? "en")
            let capturedTask = currentTask  // Snapshot before reset below races the async task.
            NSLog("[Orbit.speech] stop: final flush \(String(format: "%.2f", Double(finalSnapshot.count) / targetSampleRate))s audio (\(language), task=\(capturedTask))")
            transcribing = true
            Task { [weak self] in
                guard let self else { return }
                do {
                    let options = DecodingOptions(
                        verbose: false,
                        task: capturedTask,
                        language: language,
                        temperature: 0,
                        temperatureFallbackCount: 5,
                        skipSpecialTokens: true,
                        withoutTimestamps: true,
                        noSpeechThreshold: 0.5
                    )
                    let results = try await kit.transcribe(audioArray: finalSnapshot, decodeOptions: options)
                    let text = results
                        .map(\.text)
                        .joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
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
        // Reset task state AFTER the final-flush block so capturedTask above
        // reads the session's actual task, not the post-reset value.
        currentTask = .transcribe
        currentTranslationTargetId = nil
    }

    // MARK: - Model availability + download

    /// Returns true if the model files for `modelName` are present in the
    /// local cache. Doesn't trigger any network or load. Used by the
    /// Settings UI to decide whether to show a "Download" button.
    func isModelDownloaded(_ modelName: String) -> Bool {
        let cacheURL = SpeechRecognitionService.modelFolderURL(for: modelName)
        // The folder exists with at least one .mlmodelc inside means the
        // download completed.
        guard let folder = cacheURL,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return false }
        return entries.contains { $0.hasSuffix(".mlmodelc") || $0.hasSuffix(".mlpackage") }
    }

    /// Conventional location WhisperKit / huggingface-swift caches models.
    /// We compute the same path so `isModelDownloaded` and our own load
    /// path agree on where to look.
    private static func modelFolderURL(for modelName: String) -> URL? {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return documents
            .appendingPathComponent("huggingface")
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")
            .appendingPathComponent(modelName)
    }

    /// Public entry point used by the Settings UI. Downloads the model if
    /// needed (with progress) and loads it into memory. Updates
    /// `modelStatus` throughout the lifecycle. Idempotent — calling while a
    /// download is already in flight is a no-op.
    @MainActor
    func downloadAndLoadModel(_ modelName: String) async {
        if whisperKitLoading { return }
        // Different model than what's currently loaded → release the old one.
        if loadedModelName != nil, loadedModelName != modelName {
            whisperKit = nil
            loadedModelName = nil
        }
        // Already loaded → done.
        if whisperKit != nil, loadedModelName == modelName {
            modelStatus = .ready(modelName: modelName)
            return
        }
        whisperKitLoading = true
        defer { whisperKitLoading = false }

        do {
            // Step 1: download (with progress) if not already cached. The
            // download() call internally checks the cache and is fast for
            // already-downloaded models.
            modelStatus = .downloading(progress: 0, modelName: modelName)
            NSLog("[Orbit.speech] starting download of \(modelName)…")
            let folderURL = try await WhisperKit.download(
                variant: modelName,
                from: "argmaxinc/whisperkit-coreml",
                progressCallback: { [weak self] progress in
                    Task { @MainActor in
                        self?.modelStatus = .downloading(
                            progress: progress.fractionCompleted,
                            modelName: modelName
                        )
                    }
                }
            )
            // Step 2: load WhisperKit from the local folder.
            modelStatus = .loading(modelName: modelName)
            NSLog("[Orbit.speech] download complete, loading WhisperKit from \(folderURL.path)")
            let config = WhisperKitConfig(modelFolder: folderURL.path)
            let kit = try await WhisperKit(config)
            whisperKit = kit
            loadedModelName = modelName
            modelStatus = .ready(modelName: modelName)
            NSLog("[Orbit.speech] WhisperKit ready (\(modelName))")
        } catch {
            NSLog("[Orbit.speech] downloadAndLoadModel failed: \(error)")
            modelStatus = .error(error.localizedDescription)
        }
    }

    // MARK: - WhisperKit lazy load (during dictation start)

    @MainActor
    private func ensureWhisperKitLoaded(onError: @escaping (String) -> Void) async {
        let target = SettingsService.shared.dictationModelName
        if whisperKit != nil, loadedModelName == target { return }
        await downloadAndLoadModel(target)
        if whisperKit == nil {
            onError("Failed to load Whisper model. Set up dictation in Settings → Dictation.")
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
        if !hasReceivedFirstAudioBuffer {
            hasReceivedFirstAudioBuffer = true
            DispatchQueue.main.async { [weak self] in
                self?.indicatorPanel?.updateState(.listening)
            }
        }

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

        // RMS amplitude over this frame; cheap VAD.
        let rms = computeRMS(samples)
        let isSpeech = rms > speechRmsThreshold

        var shouldFlush = false
        var bufferDuration: Double = 0

        audioBufferQueue.sync {
            audioBuffer.append(contentsOf: samples)
            bufferDuration = Double(audioBuffer.count) / targetSampleRate

            if isSpeech {
                hasSpeechInBuffer = true
                silentSamplesAfterSpeech = 0
            } else if hasSpeechInBuffer {
                silentSamplesAfterSpeech += frameCount
                let silentSeconds = Double(silentSamplesAfterSpeech) / targetSampleRate
                let speechSeconds = bufferDuration - silentSeconds
                if silentSeconds >= silenceTriggerSeconds, speechSeconds >= minSpeechSeconds {
                    shouldFlush = true
                }
            }

            // Hard cap on buffer length: if VAD never triggers, force a
            // flush so we don't accumulate forever.
            if bufferDuration >= maxBufferSeconds, hasSpeechInBuffer {
                shouldFlush = true
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

    /// Hand the currently buffered audio to Whisper, then clear the buffer
    /// and reset the VAD state for the next utterance.
    private func flushAndTranscribe() {
        guard isRunning, !transcribing, let kit = whisperKit else { return }

        let snapshot: [Float] = audioBufferQueue.sync {
            let copy = audioBuffer
            audioBuffer.removeAll(keepingCapacity: true)
            hasSpeechInBuffer = false
            silentSamplesAfterSpeech = 0
            return copy
        }

        guard snapshot.count > Int(targetSampleRate * minSpeechSeconds) else { return }

        transcribing = true
        let bcp47 = currentLocaleId
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let language = String(bcp47.split(separator: "-").first ?? "en")  // "en", "sv", etc.

        NSLog("[Orbit.speech] flushing \(Double(snapshot.count) / targetSampleRate)s of audio for transcription (\(language))")

        Task { [weak self] in
            guard let self else { return }
            do {
                let options = DecodingOptions(
                    verbose: false,
                    task: currentTask,
                    language: language,
                    temperature: 0,
                    // If a chunk decodes with low confidence at temperature
                    // 0, retry with progressively higher temperature up to
                    // 5 times. Lets Whisper recover from tricky audio
                    // (background noise, fast speech, accents).
                    temperatureFallbackCount: 5,
                    skipSpecialTokens: true,
                    withoutTimestamps: true,
                    // Lower threshold means we suppress less aggressively,
                    // letting quieter speech through.
                    noSpeechThreshold: 0.5
                )
                let results = try await kit.transcribe(audioArray: snapshot, decodeOptions: options)
                let text = results
                    .map(\.text)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
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

        // Whisper sometimes emits boilerplate ("[Music]", "Thanks for
        // watching!", etc.) on quiet/noisy buffers. Filter the most common
        // ones — they're recognizable by being wrapped in brackets or by
        // exact-match against a small list.
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { return }
        if trimmed.hasPrefix("(") && trimmed.hasSuffix(")") { return }
        let lower = trimmed.lowercased()
        if SpeechRecognitionService.boilerplateBlocklist.contains(lower) { return }

        // Strip ellipsis. Whisper inserts "..." or "…" whenever the speaker
        // pauses mid-sentence (interpreted as trailing-off). For dictation
        // this just pollutes natural speech with ellipsis the user didn't
        // intend. We strip both the ASCII three-dot form and the Unicode
        // single-glyph form, then collapse any resulting double-spaces.
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

    /// Common Whisper hallucinations on silence/noise. We've all seen
    /// "Thanks for watching!" appear in unexpected places.
    private static let boilerplateBlocklist: Set<String> = [
        "thanks for watching!",
        "thanks for watching",
        "thank you for watching.",
        "thank you for watching",
        "you",
        ".",
        "...",
        "music",
        "applause",
        "[music]",
        "[applause]",
    ]

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
        panel.show(
            localeId: localeId,
            state: state,
            targetLocaleId: currentTranslationTargetId
        ) { [weak self] in
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
