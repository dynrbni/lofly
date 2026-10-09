import Foundation
import AVFoundation
import Speech

/// How an utterance ends.
public enum EndpointingMode {
    /// Hands-free: the VAD ends the utterance after trailing silence.
    case voiceActivity
    /// Push-to-talk / dictation: the user ends it (key release, confirm
    /// button). The VAD still measures speech but never cuts the user off.
    case manual
}

/// Voice input orchestrator.
///
/// ```text
/// mic → AVAudioEngine tap (native rate) → SpeechSegmenter
///        (mono · high-pass · AGC · VAD · recording)
///     → AppleSpeechEngine stream (live partials)
/// end → wait for final result  [+ optional cloud Whisper on the 16 kHz WAV]
///     → Transcript → AppState / ChatView → agent (normalization + safety)
/// ```
///
/// The public surface (`isListening`, `liveTranscript`, `audioLevel`,
/// `startListening`, `stopListening`, `cancelListening`, callbacks) is what
/// the UI binds to; providers can be swapped without touching it.
@MainActor
public final class SpeechRecognizer: ObservableObject {
    public static let shared = SpeechRecognizer()

    public private(set) var config = STTConfig.load()

    @Published public var isListening = false
    @Published public var liveTranscript = ""
    @Published public var audioLevel: Float = 0.0
    @Published public var errorMessage: String? = nil
    @Published public var hasSpoken = false
    /// Recognition is running on a finished utterance.
    @Published public private(set) var isFinalizing = false
    @Published public var isInAppDictation: Bool = false
    @Published public private(set) var currentSessionId: String = ""

    /// Final text of a command utterance along with session ID.
    public var onTranscriptFinalized: ((String, String) -> Void)?
    /// Final transcript with provider metadata (confidence, language, …) and session ID.
    /// Called right before `onTranscriptFinalized`.
    public var onTranscriptResult: ((Transcript, String) -> Void)?
    /// No recognizer text, but speech was captured: the WAV is handed over
    /// for server-side transcription (`POST /audio`) along with session ID.
    public var onAudioRecorded: ((URL, String) -> Void)?
    public var onDictationCompleted: ((String) -> Void)?
    /// The utterance contained no recognizable speech.
    public var onNoSpeech: (() -> Void)?

    public private(set) var lastTranscript: Transcript?

    private var session: Session?
    private var sessionCounter = 0
    private var agentSettings: AgentSTTSettings?

    private init() {
        refreshAgentSettings()
    }

    /// Re-reads `STTConfig` (env / defaults) — used by the evaluator and
    /// handy after `defaults write`.
    public func reloadConfig() { config = STTConfig.load() }

    private func refreshAgentSettings() {
        Task { [weak self] in
            let settings = await AgentSTTSettings.fetch()
            await MainActor.run { if let settings { self?.agentSettings = settings } }
        }
    }

    private var contextualStrings: [String] {
        let fromAgent = agentSettings?.contextualStrings ?? []
        return fromAgent.isEmpty ? STTVocabulary.fallbackContextualStrings : fromAgent
    }

    // MARK: - Permissions

    public func requestSpeechAuthorization(completion: @escaping (Bool) -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            completion(true)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async { completion(status == .authorized) }
            }
        default:
            completion(false)
        }
    }

    // MARK: - Lifecycle

    public func startListening(sessionId: String? = nil, endpointing: EndpointingMode? = nil) {
        guard !isListening else { return }

        // A previous utterance may still be finalizing; cancel it immediately so it cannot emit stale results.
        if let previous = session {
            previous.cancelled = true
            previous.stopCapture()
            previous.engine.cancelStream()
            session = nil
        }

        let assignedSessionId = sessionId ?? UUID().uuidString
        currentSessionId = assignedSessionId

        let mode = endpointing ?? (isInAppDictation ? .manual : .voiceActivity)
        liveTranscript = ""
        errorMessage = nil
        hasSpoken = false
        audioLevel = 0
        if agentSettings == nil { refreshAgentSettings() }

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .denied || micStatus == .restricted {
            errorMessage = "Izin mikrofon belum diberikan. Buka System Settings > Privacy & Security > Microphone."
            return
        }
        if micStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.verifySpeechAndBegin(mode, sessionId: assignedSessionId) } else { self?.errorMessage = "Izin mikrofon ditolak." }
                }
            }
            return
        }
        verifySpeechAndBegin(mode, sessionId: assignedSessionId)
    }

    private func verifySpeechAndBegin(_ mode: EndpointingMode, sessionId: String) {
        requestSpeechAuthorization { [weak self] granted in
            guard let self else { return }
            if !granted {
                self.errorMessage = "Izin Speech Recognition belum aktif. Buka System Settings > Privacy & Security > Speech Recognition."
            }
            self.beginSession(sessionId: sessionId, recognizerEnabled: granted, endpointing: mode)
        }
    }

    private func beginSession(sessionId: String, recognizerEnabled: Bool, endpointing: EndpointingMode) {
        sessionCounter += 1
        let audioEngine = AVAudioEngine()
        let input = audioEngine.inputNode

        if config.voiceProcessing {
            do { try input.setVoiceProcessingEnabled(true) } catch {
                STTLog.error("Voice processing unavailable: \(error.localizedDescription)")
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let segmenter = SpeechSegmenter(inputSampleRate: format.sampleRate, config: config) else {
            errorMessage = "Mikrofon tidak aktif atau sample rate 0."
            return
        }

        let engine = AppleSpeechEngine(config: config)
        let s = Session(uuid: sessionId, id: sessionCounter, audioEngine: audioEngine, segmenter: segmenter, engine: engine,
                        endpointing: endpointing, isDictation: isInAppDictation,
                        recognizerEnabled: recognizerEnabled, inputFormat: format)
        s.deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "Default input"

        if recognizerEnabled {
            do {
                var options = STTRequestOptions()
                options.contextualStrings = contextualStrings
                options.isDictation = isInAppDictation
                let sid = s.uuid
                try engine.beginStream(format: segmenter.monoFormat, options: options) { [weak self] text in
                    self?.handlePartial(text, sessionID: sid)
                }
            } catch {
                STTLog.error("Recognizer unavailable: \(error.localizedDescription)")
                s.recognizerEnabled = false
            }
        }

        // Realtime audio thread: touch only the thread-safe segmenter/engine.
        let sid = s.uuid
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let out = segmenter.process(buffer) else { return }
            engine.append(out.buffer)
            DispatchQueue.main.async { self?.handleFrame(out, sessionID: sid) }
        }

        s.configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
        ) { [weak self] _ in
            // Input device changed (AirPods connected, mic unplugged, …):
            // keep what was captured instead of failing silently.
            MainActor.assumeIsolated {
                guard let self, self.session?.uuid == sid, self.isListening else { return }
                STTLog.info("Audio configuration changed mid-utterance; finalizing")
                self.finishListening(reason: .deviceChange)
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            errorMessage = "Gagal menyalakan mikrofon: \(error.localizedDescription)"
            s.stopCapture()
            engine.cancelStream()
            return
        }

        session = s
        isListening = true
        STTLog.info("Listening #\(s.id) [\(s.uuid)] (\(endpointing == .manual ? "manual" : "vad") endpointing, \(Int(format.sampleRate)) Hz × \(format.channelCount) ch)")
        STTLog.debug(config, """
            session #\(s.id) [\(s.uuid)] start device="\(s.deviceName)" input=\(Int(format.sampleRate))Hz/\(format.channelCount)ch/\(Self.describe(format)) \
            → mono float32 \(Int(format.sampleRate))Hz (no live resampling) locales=\(config.primaryLocale)\(config.secondaryLocale.isEmpty ? "" : "+" + config.secondaryLocale) \
            onDevice=\(config.requiresOnDevice) endSilence=\(Int(config.endSilenceMs))ms preRoll=\(Int(config.preRollMs))ms \
            cloud=\(agentSettings?.cloudProvider ?? "none")
            """)
    }

    // MARK: - Audio / recognizer events (main thread)

    private func handleFrame(_ out: SpeechSegmenter.Output, sessionID: String) {
        guard let s = session, s.uuid == sessionID, isListening else { return }
        audioLevel = audioLevel * 0.25 + out.level * 0.75

        for event in out.events {
            switch event {
            case .speechStart:
                if s.vadStartMs == nil { s.vadStartMs = s.elapsedMs() }
                hasSpoken = true
            case .speechEnd:
                s.vadEndMs = s.elapsedMs()
                guard s.endpointing == .voiceActivity else { continue }
                if s.segmenter.totalSpeechMs >= config.minSpeechMs {
                    finishListening(reason: .vadEndOfSpeech)
                    return
                }
                // Cough / click: ignore and keep listening.
                s.segmenter.rejectCurrentUtterance()
                s.vadStartMs = nil
                hasSpoken = !liveTranscript.isEmpty
            }
        }

        if out.maxDurationReached {
            STTLog.info("Maximum utterance length reached; finalizing")
            finishListening(reason: .maxDuration)
        }
    }

    private func handlePartial(_ text: String, sessionID: String) {
        guard let s = session, s.uuid == sessionID, !s.cancelled else { return }
        liveTranscript = text
        if !hasSpoken { hasSpoken = true }
        // Mid-sentence pause ("buka Spotify… terus") must not end the utterance.
        let hold = STTVocabulary.endsWithContinuation(text)
        s.segmenter.setEndSilence(ms: hold ? config.continuationSilenceMs : config.endSilenceMs)
    }

    // MARK: - Ending

    enum FinishReason: String {
        case manual, vadEndOfSpeech = "vad", maxDuration = "max-duration", deviceChange = "device-change"
    }

    public func stopListening() {
        guard isListening else { return }
        finishListening(reason: .manual)
    }

    public func cancelListening() {
        guard let s = session, isListening || isFinalizing else { return }
        STTLog.info("Listening #\(s.id) cancelled")
        s.cancelled = true
        s.stopCapture()
        s.engine.cancelStream()
        isListening = false
        isFinalizing = false
        audioLevel = 0
        liveTranscript = ""
    }

    /// Releases the microphone and recognizer without delivering anything.
    public func stopAndCleanUp() {
        if let s = session {
            s.cancelled = true
            s.stopCapture()
            s.engine.cancelStream()
        }
        isListening = false
        isFinalizing = false
        audioLevel = 0
    }

    private func finishListening(reason: FinishReason) {
        guard isListening, let s = session else { return }
        isListening = false
        isFinalizing = true
        audioLevel = 0
        s.finishReason = reason

        // Push-to-talk release usually lands on the last syllable: keep the
        // mic open briefly so it is not clipped.
        let tailMs = reason == .manual ? config.releaseTailMs : 0
        Task { @MainActor [weak self] in
            if tailMs > 0 { try? await Task.sleep(nanoseconds: UInt64(tailMs * 1_000_000)) }
            s.stopCapture()
            s.captureStoppedMs = s.elapsedMs()
            await self?.finalize(s)
        }
    }

    private func finalize(_ s: Session) async {
        guard !s.cancelled, self.currentSessionId == s.uuid, self.session === s else {
            STTLog.info("[STT] Session #\(s.id) [\(s.uuid)] discarded before finalize (active: \(self.currentSessionId))")
            s.cleanupWAV()
            return
        }
        let speechDetected = s.segmenter.speechDetected || !liveTranscript.isEmpty
        let cloudProvider = config.cloudFinalPass ? agentSettings?.cloudProvider : nil

        var wav: URL? = nil
        if speechDetected {
            do { wav = try s.segmenter.exportWAV(to: s.wavURL) } catch {
                STTLog.error("WAV export failed: \(error.localizedDescription)")
            }
        }

        s.sttStartMs = s.elapsedMs()
        let config = self.config
        let engine = s.engine
        let recognizerEnabled = s.recognizerEnabled
        let appleTask = Task<Transcript?, Never> {
            recognizerEnabled ? await engine.finishStream(timeout: config.finalResultTimeoutSeconds) : nil
        }

        var cloud: Transcript? = nil
        if let cloudProvider, let wav {
            do {
                var options = STTRequestOptions()
                options.contextualStrings = contextualStrings
                let t = try await AgentWhisperEngine(timeout: config.cloudTimeoutSeconds).transcribe(wavFile: wav, options: options)
                cloud = t.isEmpty ? nil : t
            } catch {
                STTLog.error("Cloud STT (\(cloudProvider)) failed, using Apple result: \(error.localizedDescription)")
            }
        }
        let apple = await appleTask.value
        s.sttEndMs = s.elapsedMs()

        guard !s.cancelled, self.currentSessionId == s.uuid, self.session === s else {
            STTLog.info("[STT] Session #\(s.id) [\(s.uuid)] superseded during STT processing; dropping result")
            s.cleanupWAV()
            return
        }

        if session === s { isFinalizing = false }

        let final = cloud ?? apple
        logSummary(s, apple: apple, cloud: cloud, final: final)

        let text = final?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if s.isDictation {
            isInAppDictation = false
            if !text.isEmpty { onDictationCompleted?(text) }
            s.cleanupWAV()
            return
        }

        if let final, !text.isEmpty {
            lastTranscript = final
            if session === s { liveTranscript = text }
            STTLog.info("\n[VOICE]\naudio session id: \(s.uuid)\n[STT_FINAL]\n\"\(text)\"")
            onTranscriptResult?(final, s.uuid)
            onTranscriptFinalized?(text, s.uuid)
        } else if speechDetected, cloudProvider == nil, let wav {
            STTLog.info("Recognizer returned no text; sending audio to the agent")
            onAudioRecorded?(wav, s.uuid)
        } else {
            STTLog.info("Utterance #\(s.id) contained no recognizable speech")
            onNoSpeech?()
        }
        s.cleanupWAV()
    }

    // MARK: - Diagnostics

    private func logSummary(_ s: Session, apple: Transcript?, cloud: Transcript?, final: Transcript?) {
        let latency = s.sttEndMs.flatMap { end in s.sttStartMs.map { end - $0 } } ?? 0
        STTLog.info("Utterance #\(s.id) done: reason=\(s.finishReason?.rawValue ?? "?") provider=\(final?.provider ?? "none") sttLatency=\(Int(latency))ms")
        guard config.debug else { return }
        func fmt(_ v: Double?) -> String { v.map { "\(Int($0))ms" } ?? "-" }
        func conf(_ t: Transcript?) -> String { t?.confidence.map { String(format: "%.2f", $0) } ?? "n/a" }
        STTLog.debug(config, """
            utterance #\(s.id) reason=\(s.finishReason?.rawValue ?? "?") device="\(s.deviceName)" \
            format=\(Int(s.inputFormat.sampleRate))Hz/\(s.inputFormat.channelCount)ch→mono wav=16kHz/16-bit \
            recorded=\(Int(s.segmenter.recordedMs))ms speech=\(Int(s.segmenter.totalSpeechMs))ms \
            vadStart=\(fmt(s.vadStartMs)) vadEnd=\(fmt(s.vadEndMs)) captureStop=\(fmt(s.captureStoppedMs)) \
            sttStart=\(fmt(s.sttStartMs)) sttEnd=\(fmt(s.sttEndMs)) sttLatency=\(Int(latency))ms \
            noiseFloor=\(String(format: "%.1f", s.segmenter.noiseFloorDb))dBFS gain=+\(String(format: "%.1f", s.segmenter.currentGainDb))dB \
            clipping=\(String(format: "%.3f", s.segmenter.clippingRatio * 100))%
            """)
        STTLog.debug(config, "apple: lang=\(apple?.language ?? "-") conf=\(conf(apple)) final=\(apple?.isFinal ?? false) raw=\"\(apple?.text ?? "")\" low=\(apple?.lowConfidenceWords ?? [])")
        if let cloud { STTLog.debug(config, "cloud: provider=\(cloud.provider) lang=\(cloud.language ?? "-") conf=\(conf(cloud)) raw=\"\(cloud.text)\"") }
        STTLog.debug(config, "final: provider=\(final?.provider ?? "none") lang=\(final?.language ?? "-") conf=\(conf(final)) text=\"\(final?.text ?? "")\" (normalization runs in the agent; see agent debug log)")
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        switch format.commonFormat {
        case .pcmFormatFloat32: return "float32"
        case .pcmFormatInt16: return "int16"
        case .pcmFormatInt32: return "int32"
        case .pcmFormatFloat64: return "float64"
        default: return "other"
        }
    }
}

// MARK: - Session

/// Everything belonging to one utterance. Finalization of one session never
/// blocks the microphone for the next one.
@MainActor
private final class Session {
    let uuid: String
    let id: Int
    let audioEngine: AVAudioEngine
    let segmenter: SpeechSegmenter
    let engine: AppleSpeechEngine
    let endpointing: EndpointingMode
    let isDictation: Bool
    var recognizerEnabled: Bool
    let inputFormat: AVAudioFormat
    let startedAt = DispatchTime.now()
    let wavURL: URL

    var deviceName = ""
    var cancelled = false
    var captureActive = true
    var finishReason: SpeechRecognizer.FinishReason?
    var configObserver: NSObjectProtocol?

    var vadStartMs: Double?
    var vadEndMs: Double?
    var captureStoppedMs: Double?
    var sttStartMs: Double?
    var sttEndMs: Double?

    init(uuid: String, id: Int, audioEngine: AVAudioEngine, segmenter: SpeechSegmenter, engine: AppleSpeechEngine,
         endpointing: EndpointingMode, isDictation: Bool, recognizerEnabled: Bool, inputFormat: AVAudioFormat) {
        self.uuid = uuid
        self.id = id
        self.audioEngine = audioEngine
        self.segmenter = segmenter
        self.engine = engine
        self.endpointing = endpointing
        self.isDictation = isDictation
        self.recognizerEnabled = recognizerEnabled
        self.inputFormat = inputFormat
        self.wavURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lofly-utterance-\(uuid).wav")
    }

    func cleanupWAV() {
        try? FileManager.default.removeItem(at: wavURL)
    }

    func elapsedMs() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000
    }

    func stopCapture() {
        guard captureActive else { return }
        captureActive = false
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
    }
}
