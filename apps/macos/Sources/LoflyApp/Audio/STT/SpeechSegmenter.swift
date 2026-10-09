import Foundation
import AVFoundation

// MARK: - Preprocessing

/// Light-touch conditioning that preserves speech:
/// mono downmix → DC/rumble high-pass → boost-only slow AGC with a limiter.
/// Not thread-safe; owned by `SpeechSegmenter`.
struct AudioPreprocessor {
    let sampleRate: Double
    private let highPassEnabled: Bool
    private let hpAlpha: Float
    private var prevIn: Float = 0
    private var prevOut: Float = 0

    private let autoGain: Bool
    private let maxGain: Float
    /// Target speech RMS ≈ -20 dBFS.
    private let targetRms: Float = 0.1
    private var speechRms: Float = 0
    private(set) var gain: Float = 1
    private var appliedGain: Float = 1

    init(sampleRate: Double, config: STTConfig) {
        self.sampleRate = sampleRate
        highPassEnabled = config.highPassHz > 0
        let rc = 1.0 / (2.0 * Double.pi * Double(max(config.highPassHz, 1)))
        let dt = 1.0 / sampleRate
        hpAlpha = Float(rc / (rc + dt))
        autoGain = config.autoGain
        maxGain = pow(10, config.maxGainDb / 20)
    }

    /// Downmixes to mono without "stereo duplication" artefacts: channels far
    /// quieter than the loudest (e.g. a dead second input) are ignored instead
    /// of halving the level.
    static func downmix(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, let data = buffer.floatChannelData else { return [] }
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: data[0], count: frames))
        }
        var energies = [Float](repeating: 0, count: channels)
        for c in 0..<channels {
            var e: Float = 0
            let p = data[c]
            for i in 0..<frames { e += p[i] * p[i] }
            energies[c] = e
        }
        let maxEnergy = energies.max() ?? 0
        let active = (0..<channels).filter { energies[$0] >= maxEnergy * 0.1 }
        guard !active.isEmpty else { return [Float](repeating: 0, count: frames) }
        var out = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(active.count)
        for c in active {
            let p = data[c]
            for i in 0..<frames { out[i] += p[i] * scale }
        }
        return out
    }

    mutating func highPass(_ samples: inout [Float], range: Range<Int>) {
        guard highPassEnabled else { return }
        for i in range {
            let x = samples[i]
            let y = hpAlpha * (prevOut + x - prevIn)
            prevIn = x
            prevOut = y
            samples[i] = y
        }
    }

    /// Feeds the pre-gain RMS of a voiced block into the AGC.
    mutating func observeVoiced(rms: Float) {
        guard autoGain, rms > 0 else { return }
        speechRms = speechRms == 0 ? rms : speechRms * 0.9 + rms * 0.1
        let desired = min(max(targetRms / speechRms, 1), maxGain)
        gain += (desired - gain) * 0.05
    }

    /// Applies the current gain with a per-block ramp (no zipper noise) and a
    /// soft limiter so boosting can never clip.
    mutating func applyGain(_ samples: inout [Float], range: Range<Int>) {
        guard autoGain, !range.isEmpty else { return }
        let start = appliedGain
        let end = gain
        if abs(start - 1) < 0.001 && abs(end - 1) < 0.001 { return }
        let n = Float(range.count)
        var k: Float = 0
        for i in range {
            let g = start + (end - start) * (k / n)
            var y = samples[i] * g
            if abs(y) > 0.9 {
                // Smooth knee above 0.9, asymptotic to 1.0.
                let sign: Float = y < 0 ? -1 : 1
                let over = abs(y) - 0.9
                y = sign * (0.9 + 0.1 * tanh(over / 0.1))
            }
            samples[i] = y
            k += 1
        }
        appliedGain = end
    }
}

// MARK: - Voice activity detection

/// Energy VAD with an adaptive noise floor (minimum statistics), onset
/// confirmation and hysteresis. Pure value type: easy to reason about and
/// independent of AVFoundation.
struct VoiceActivityDetector {
    enum Event: Equatable {
        case speechStart(sample: Int)
        case speechEnd(sample: Int)
    }

    var onsetThresholdDb: Float
    var holdThresholdDb: Float
    var absoluteFloorDb: Float
    var onsetMs: Double

    private(set) var noiseFloorDb: Float = -60
    private(set) var isSpeech = false
    private(set) var everSpoke = false
    private(set) var totalSpeechMs: Double = 0

    private var recentDb: [Float] = []
    private var recentCapacity = 100
    private var calibrationBlocks = 0
    private var voicedRunMs: Double = 0
    private var silenceRunMs: Double = 0

    init(config: STTConfig) {
        onsetThresholdDb = config.onsetThresholdDb
        holdThresholdDb = config.holdThresholdDb
        absoluteFloorDb = config.absoluteSpeechFloorDbfs
        onsetMs = config.speechOnsetMs
    }

    static func dbfs(rms: Float) -> Float { 20 * log10(max(rms, 1e-7)) }

    /// UI meter value in [0, 1], relative to the noise floor.
    func level(forDb db: Float) -> Float {
        min(max((db - noiseFloorDb - 3) / 30, 0), 1)
    }

    mutating func process(db: Float, blockMs: Double, endSample: Int, sampleRate: Double, endSilenceMs: Double) -> Event? {
        updateNoiseFloor(db: db, blockMs: blockMs)

        let threshold = isSpeech ? holdThresholdDb : onsetThresholdDb
        let voiced = db > noiseFloorDb + threshold && db > absoluteFloorDb

        if !isSpeech {
            if voiced {
                voicedRunMs += blockMs
                if voicedRunMs >= onsetMs {
                    isSpeech = true
                    everSpoke = true
                    silenceRunMs = 0
                    totalSpeechMs += voicedRunMs
                    let back = Int(voicedRunMs / 1000 * sampleRate)
                    return .speechStart(sample: max(0, endSample - back))
                }
            } else {
                voicedRunMs = 0
            }
            return nil
        }

        if voiced {
            silenceRunMs = 0
            totalSpeechMs += blockMs
            return nil
        }

        silenceRunMs += blockMs
        if silenceRunMs >= endSilenceMs {
            isSpeech = false
            voicedRunMs = 0
            let back = Int(silenceRunMs / 1000 * sampleRate)
            silenceRunMs = 0
            return .speechEnd(sample: max(0, endSample - back))
        }
        return nil
    }

    /// Forget a rejected (too short) utterance but keep the noise estimate.
    mutating func resetUtterance() {
        isSpeech = false
        everSpoke = false
        totalSpeechMs = 0
        voicedRunMs = 0
        silenceRunMs = 0
    }

    private mutating func updateNoiseFloor(db: Float, blockMs: Double) {
        if recentDb.isEmpty {
            recentCapacity = max(20, Int(2000 / max(blockMs, 1)))  // ~2 s window
        }
        recentDb.append(db)
        if recentDb.count > recentCapacity { recentDb.removeFirst(recentDb.count - recentCapacity) }

        let windowMin = recentDb.min() ?? db
        if calibrationBlocks < 10 {
            // The user often starts talking the instant the key is held, so
            // the first blocks may already be speech: never trust a start-up
            // floor louder than a normal room (-42 dBFS). Minimum tracking
            // corrects it within ~2 s if the room really is that loud.
            calibrationBlocks += 1
            noiseFloorDb = min(windowMin, -42)
        } else {
            noiseFloorDb += (windowMin - noiseFloorDb) * 0.05
        }
        noiseFloorDb = min(max(noiseFloorDb, -90), -25)
    }
}

// MARK: - Segmenter

/// Owns one utterance: preprocesses captured audio, runs the VAD, keeps the
/// full mono recording for export, and hands conditioned buffers to the STT
/// engine. Called from the realtime audio thread; internally locked so the
/// main thread can safely read results and adjust the endpoint window.
final class SpeechSegmenter: @unchecked Sendable {
    struct Output {
        let buffer: AVAudioPCMBuffer
        let level: Float
        let events: [VoiceActivityDetector.Event]
        let maxDurationReached: Bool
    }

    let sampleRate: Double
    let monoFormat: AVAudioFormat
    private let config: STTConfig
    private let lock = NSLock()
    private var pre: AudioPreprocessor
    private var vad: VoiceActivityDetector
    private var samples: [Float] = []
    private var speechStart: Int?
    private var speechEnd: Int?
    private var clippedSamples = 0
    private var endSilenceMs: Double
    private let blockSize: Int
    private let maxSamples: Int

    init?(inputSampleRate: Double, config: STTConfig) {
        guard inputSampleRate > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputSampleRate, channels: 1, interleaved: false)
        else { return nil }
        self.sampleRate = inputSampleRate
        self.monoFormat = mono
        self.config = config
        self.pre = AudioPreprocessor(sampleRate: inputSampleRate, config: config)
        self.vad = VoiceActivityDetector(config: config)
        self.endSilenceMs = config.endSilenceMs
        self.blockSize = max(64, Int(inputSampleRate * 0.02))
        self.maxSamples = Int(inputSampleRate * config.maxUtteranceSeconds)
        samples.reserveCapacity(Int(inputSampleRate * 10))
    }

    // MARK: Main-thread accessors

    var speechDetected: Bool { lock.lock(); defer { lock.unlock() }; return vad.everSpoke }
    var totalSpeechMs: Double { lock.lock(); defer { lock.unlock() }; return vad.totalSpeechMs }
    var recordedMs: Double { lock.lock(); defer { lock.unlock() }; return Double(samples.count) / sampleRate * 1000 }
    var noiseFloorDb: Float { lock.lock(); defer { lock.unlock() }; return vad.noiseFloorDb }
    var currentGainDb: Float { lock.lock(); defer { lock.unlock() }; return 20 * log10(pre.gain) }
    var clippingRatio: Double {
        lock.lock(); defer { lock.unlock() }
        return samples.isEmpty ? 0 : Double(clippedSamples) / Double(samples.count)
    }

    func setEndSilence(ms: Double) { lock.lock(); endSilenceMs = ms; lock.unlock() }

    /// A too-short blip ended "speech": forget it and keep listening.
    func rejectCurrentUtterance() {
        lock.lock()
        vad.resetUtterance()
        speechStart = nil
        speechEnd = nil
        lock.unlock()
    }

    // MARK: Audio thread

    func process(_ input: AVAudioPCMBuffer) -> Output? {
        var mono = AudioPreprocessor.downmix(input)
        guard !mono.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }

        var events: [VoiceActivityDetector.Event] = []
        var lastDb: Float = -90
        var offset = 0
        let blockMsBase = 1000 / sampleRate
        while offset < mono.count {
            let end = min(offset + blockSize, mono.count)
            let range = offset..<end
            pre.highPass(&mono, range: range)

            var sum: Float = 0
            for i in range {
                let s = mono[i]
                sum += s * s
                if abs(s) >= 0.99 { clippedSamples += 1 }
            }
            let rms = sqrt(sum / Float(range.count))
            let db = VoiceActivityDetector.dbfs(rms: rms)
            lastDb = db

            let absoluteEnd = samples.count + end
            if let event = vad.process(db: db, blockMs: Double(range.count) * blockMsBase,
                                       endSample: absoluteEnd, sampleRate: sampleRate,
                                       endSilenceMs: endSilenceMs) {
                switch event {
                case .speechStart(let s): if speechStart == nil { speechStart = s }; speechEnd = nil
                case .speechEnd(let s): speechEnd = s
                }
                events.append(event)
            }
            if vad.isSpeech { pre.observeVoiced(rms: rms) }
            pre.applyGain(&mono, range: range)
            offset = end
        }

        samples.append(contentsOf: mono)

        guard let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(mono.count)),
              let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { src in
            dst.update(from: src.baseAddress!, count: mono.count)
        }

        return Output(buffer: out,
                      level: vad.level(forDb: lastDb),
                      events: events,
                      maxDurationReached: samples.count >= maxSamples)
    }

    // MARK: Export

    /// Writes the utterance (VAD-trimmed with pre-roll and tail) as 16 kHz
    /// mono 16-bit PCM WAV — the native input format of Whisper-class models.
    /// Resampling happens once here, offline, never in the live path.
    func exportWAV(to url: URL) throws -> URL? {
        lock.lock()
        let all = samples
        let start = speechStart
        let end = speechEnd
        lock.unlock()
        guard !all.isEmpty else { return nil }

        let preRoll = Int(config.preRollMs / 1000 * sampleRate)
        let tail = Int(0.2 * sampleRate)
        let from = max(0, (start ?? 0) - preRoll)
        let to = min(all.count, (end.map { $0 + tail }) ?? all.count)
        guard to > from else { return nil }
        let slice = Array(all[from..<to])

        guard let inBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(slice.count)),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: monoFormat, to: outFormat)
        else { return nil }
        inBuf.frameLength = AVAudioFrameCount(slice.count)
        slice.withUnsafeBufferPointer { src in
            inBuf.floatChannelData![0].update(from: src.baseAddress!, count: slice.count)
        }

        let ratio = 16_000 / sampleRate
        let capacity = AVAudioFrameCount(Double(slice.count) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var convError: NSError?
        converter.convert(to: outBuf, error: &convError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return inBuf
        }
        if let convError { throw convError }

        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: outFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try file.write(from: outBuf)
        return url
    }
}
