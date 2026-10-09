import Foundation
import AVFoundation
import os

// MARK: - Configuration

/// Every tunable of the speech pipeline in one place.
///
/// Values resolve in this order: environment variable `LOFLY_STT_<KEY>` →
/// `UserDefaults` key `stt.<key>` (e.g. `defaults write com.dynrbni.lofly
/// stt.endSilenceMs -float 900`) → built-in default.
public struct STTConfig {
    /// Primary recognition locale. Indonesian, with English app names and
    /// verbs biased in through contextual strings.
    public var primaryLocale = "id-ID"
    /// Optional second recognizer run in parallel on the same audio. Its
    /// result only wins when it is clearly more confident (pure English
    /// commands). Empty string disables it.
    public var secondaryLocale = "en-US"
    /// Force on-device recognition (private, no network, slightly less
    /// accurate for id-ID on most Macs).
    public var requiresOnDevice = false

    /// Audio kept before the VAD speech onset when exporting the utterance.
    public var preRollMs: Double = 300
    /// Trailing silence that ends an utterance in hands-free mode.
    public var endSilenceMs: Double = 800
    /// Trailing silence tolerated when the last recognized word is a
    /// connective ("terus", "lalu", "and", …) — the user is mid-sentence.
    public var continuationSilenceMs: Double = 1600
    /// Minimum voiced audio for an utterance to count (filters coughs/pops).
    public var minSpeechMs: Double = 250
    /// Consecutive voiced audio needed to declare speech onset.
    public var speechOnsetMs: Double = 60
    /// Safety cap for a single utterance.
    public var maxUtteranceSeconds: Double = 45
    /// Audio still captured after push-to-talk release so the final syllable
    /// is not clipped.
    public var releaseTailMs: Double = 250
    /// How long to wait for the recognizer's final (`isFinal`) result.
    public var finalResultTimeoutSeconds: Double = 2.0

    /// Onset threshold above the tracked noise floor.
    public var onsetThresholdDb: Float = 9
    /// Hold threshold above the noise floor (hysteresis).
    public var holdThresholdDb: Float = 5
    /// Anything quieter than this is never speech.
    public var absoluteSpeechFloorDbfs: Float = -58

    /// High-pass corner (DC + rumble removal). 0 disables.
    public var highPassHz: Float = 80
    /// Boost-only slow AGC for quiet microphones.
    public var autoGain = true
    public var maxGainDb: Float = 12
    /// Apple voice processing (noise suppression + AGC + echo cancel).
    /// Off by default: it ducks other audio output on macOS.
    public var voiceProcessing = false

    /// Use the agent's cloud Whisper provider for the final transcript when
    /// the agent reports one is configured. Apple still drives live text.
    public var cloudFinalPass = true
    public var cloudTimeoutSeconds: Double = 8

    /// Opt-in diagnostics (timings, formats, raw + final transcripts).
    public var debug = false
    /// Opt-in per-utterance diagnostics record (every engine's transcript,
    /// confidence, timings, noise floor, clipping) sent to the agent, which
    /// appends it to ~/.lofly/stt/diagnostics.jsonl.
    public var diagnostics = false
    /// With `diagnostics`: also keep each utterance's 16 kHz WAV in
    /// ~/.lofly/stt/audio/ to build a correction dataset.
    public var saveAudio = false
    /// Saved WAVs beyond this count are deleted, oldest first.
    public var maxSavedAudioFiles = 500

    public static func load() -> STTConfig {
        var c = STTConfig()
        let r = Resolver()
        c.primaryLocale = r.string("primaryLocale", c.primaryLocale)
        c.secondaryLocale = r.string("secondaryLocale", c.secondaryLocale)
        c.requiresOnDevice = r.bool("requiresOnDevice", c.requiresOnDevice)
        c.preRollMs = r.double("preRollMs", c.preRollMs)
        c.endSilenceMs = r.double("endSilenceMs", c.endSilenceMs)
        c.continuationSilenceMs = r.double("continuationSilenceMs", c.continuationSilenceMs)
        c.minSpeechMs = r.double("minSpeechMs", c.minSpeechMs)
        c.speechOnsetMs = r.double("speechOnsetMs", c.speechOnsetMs)
        c.maxUtteranceSeconds = r.double("maxUtteranceSeconds", c.maxUtteranceSeconds)
        c.releaseTailMs = r.double("releaseTailMs", c.releaseTailMs)
        c.finalResultTimeoutSeconds = r.double("finalResultTimeoutSeconds", c.finalResultTimeoutSeconds)
        c.onsetThresholdDb = Float(r.double("onsetThresholdDb", Double(c.onsetThresholdDb)))
        c.holdThresholdDb = Float(r.double("holdThresholdDb", Double(c.holdThresholdDb)))
        c.absoluteSpeechFloorDbfs = Float(r.double("absoluteSpeechFloorDbfs", Double(c.absoluteSpeechFloorDbfs)))
        c.highPassHz = Float(r.double("highPassHz", Double(c.highPassHz)))
        c.autoGain = r.bool("autoGain", c.autoGain)
        c.maxGainDb = Float(r.double("maxGainDb", Double(c.maxGainDb)))
        c.voiceProcessing = r.bool("voiceProcessing", c.voiceProcessing)
        c.cloudFinalPass = r.bool("cloudFinalPass", c.cloudFinalPass)
        c.cloudTimeoutSeconds = r.double("cloudTimeoutSeconds", c.cloudTimeoutSeconds)
        c.debug = r.bool("debug", c.debug)
        c.diagnostics = r.bool("diagnostics", c.diagnostics)
        c.saveAudio = r.bool("saveAudio", c.saveAudio)
        c.maxSavedAudioFiles = Int(r.double("maxSavedAudioFiles", Double(c.maxSavedAudioFiles)))
        return c
    }

    private struct Resolver {
        let env = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard

        private func envKey(_ key: String) -> String {
            // primaryLocale -> LOFLY_STT_PRIMARY_LOCALE
            var out = ""
            for ch in key {
                if ch.isUppercase { out += "_" }
                out += String(ch).uppercased()
            }
            return "LOFLY_STT_" + out
        }

        private func raw(_ key: String) -> String? {
            if let v = env[envKey(key)] { return v }
            if let v = defaults.object(forKey: "stt.\(key)") { return "\(v)" }
            return nil
        }

        func string(_ key: String, _ fallback: String) -> String { raw(key) ?? fallback }
        func double(_ key: String, _ fallback: Double) -> Double { raw(key).flatMap(Double.init) ?? fallback }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            guard let v = raw(key)?.lowercased() else { return fallback }
            return ["1", "true", "yes", "on"].contains(v)
        }
    }
}

// MARK: - Transcript

/// Provider-independent recognition result.
public struct Transcript {
    public var text: String
    /// Mean provider confidence in [0, 1]. `nil` when the provider gives none
    /// — never synthesized.
    public var confidence: Double?
    public var language: String?
    public var durationMs: Int?
    public var provider: String
    /// Words the provider itself scored below 0.5.
    public var lowConfidenceWords: [String] = []
    /// Whether this is the provider's final hypothesis (vs. a timed-out partial).
    public var isFinal: Bool = true
    /// Diagnostics: the final result never arrived before the timeout.
    public var timedOut: Bool = false
    /// Diagnostics: end of audio → result.
    public var latencyMs: Int?
    public var onDevice: Bool?

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Metadata forwarded to the agent with voice queries.
    public var agentMetadata: [String: Any] {
        var m: [String: Any] = ["provider": provider, "isFinal": isFinal]
        if let confidence { m["confidence"] = confidence }
        if let language { m["language"] = language }
        if let durationMs { m["durationMs"] = durationMs }
        if !lowConfidenceWords.isEmpty { m["lowConfidenceWords"] = lowConfidenceWords }
        return m
    }

    /// Shape of `SttEngineResult` in packages/core/src/stt/diagnostics.ts.
    func diagnosticsRecord(error: String? = nil) -> [String: Any] {
        var m: [String: Any] = ["engine": provider, "text": text, "isFinal": isFinal, "timedOut": timedOut]
        if let language { m["locale"] = language }
        if let confidence { m["confidence"] = confidence }
        if let latencyMs { m["latencyMs"] = latencyMs }
        if let onDevice { m["onDevice"] = onDevice }
        if !lowConfidenceWords.isEmpty { m["lowConfidenceWords"] = lowConfidenceWords }
        if let error { m["error"] = error }
        return m
    }
}

// MARK: - Engine abstraction

public struct STTRequestOptions {
    public var contextualStrings: [String] = []
    public var isDictation = false
}

/// A recognizer that transcribes one complete utterance.
public protocol STTEngine: AnyObject {
    var id: String { get }
    func transcribe(wavFile: URL, options: STTRequestOptions) async throws -> Transcript
}

/// A recognizer that additionally accepts audio while the user is speaking
/// and can show live partial text. The final transcript is still produced
/// from the complete utterance.
public protocol StreamingSTTEngine: STTEngine {
    func beginStream(format: AVAudioFormat, options: STTRequestOptions, onPartial: @escaping (String) -> Void) throws
    /// Called on the realtime audio thread.
    func append(_ buffer: AVAudioPCMBuffer)
    func finishStream(timeout: TimeInterval) async -> Transcript?
    func cancelStream()
}

// MARK: - Logging

/// STT logging. Non-sensitive lifecycle events go to the unified log at info
/// level; transcripts and detailed timings only when `STTConfig.debug` is on.
enum STTLog {
    static let logger = Logger(subsystem: "com.dynrbni.lofly", category: "stt")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    /// Only emitted when debug mode is enabled; may contain transcripts.
    static func debug(_ config: STTConfig, _ message: @autoclosure () -> String) {
        guard config.debug else { return }
        let text = message()
        logger.notice("[debug] \(text, privacy: .public)")
        print("[STT] \(text)")
    }
}

// MARK: - Small thread-safe box

final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    func mutate<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

// MARK: - Vocabulary

/// Phrases used to bias recognition. The agent serves the configurable list
/// (`GET /stt/config`); this is the offline fallback.
enum STTVocabulary {
    static let fallbackContextualStrings: [String] = [
        "Lofly", "WhatsApp", "Spotify", "Safari", "Chrome", "Google Chrome", "CapCut",
        "Finder", "Terminal", "GitHub", "VS Code", "Visual Studio Code", "Discord",
        "Telegram", "Slack", "Notion", "OpenAI", "ChatGPT", "MacBook", "RTX", "localhost",
        "git status", "git push", "Microsoft Word", "YouTube", "Google",
        "buka", "tutup", "putar", "kirim pesan", "cari", "jalankan", "terus", "lalu",
        "open", "play", "search", "send message", "lagu terakhir", "gue", "bilang", "telat",
        "reminder", "screenshot", "volume", "playlist", "lagu",
        // Music entities & titles
        "Manchild", "manchild", "Sabrina Carpenter", "Radiohead", "Creep", "creep",
        "Bruno Mars", "Taylor Swift", "Billie Eilish", "Dongker", "Feast", "Hindia"
    ]

    /// Words after which a pause usually means "I'm not done yet".
    static let continuationWords: Set<String> = [
        "terus", "lalu", "dan", "habis", "abis", "kemudian", "sama", "ke", "yang",
        "untuk", "buat", "di", "dari", "trus", "tapi", "atau", "bilang", "kalau", "kalo",
        "and", "then", "to", "the", "or", "but", "with", "for", "a", "an", "of", "lofly"
    ]

    static func endsWithContinuation(_ text: String) -> Bool {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard let last = words.last else { return false }
        return continuationWords.contains(last)
    }
}
