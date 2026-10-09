import Foundation
import AVFoundation
import Speech

/// Apple Speech framework provider.
///
/// One engine instance per utterance. Streams audio into one recognizer per
/// configured locale (primary + optional secondary) so live text appears while
/// the user speaks, then waits for each recognizer's *final* result — the one
/// Apple re-scores with the full utterance — instead of reading a partial.
final class AppleSpeechEngine: StreamingSTTEngine, @unchecked Sendable {
    let id = "apple"

    private let config: STTConfig
    private let lock = NSLock()
    private var sessions: [LocaleSession] = []
    /// Diagnostics: one record per locale from the last `finishStream`,
    /// including locales that errored or returned nothing.
    private(set) var lastEngineRecords: [[String: Any]] = []

    /// Recognizers are reused across utterances; creating them is not free.
    private static let recognizerCache = Locked<[String: SFSpeechRecognizer]>([:])

    init(config: STTConfig) {
        self.config = config
    }

    static func recognizer(for identifier: String) -> SFSpeechRecognizer? {
        recognizerCache.mutate { cache in
            if let r = cache[identifier] { return r }
            guard let r = SFSpeechRecognizer(locale: Locale(identifier: identifier)) else { return nil }
            cache[identifier] = r
            return r
        }
    }

    /// Ordered, de-duplicated, available recognizers for this config.
    private func availableRecognizers() -> [SFSpeechRecognizer] {
        var ids = [config.primaryLocale]
        if !config.secondaryLocale.isEmpty { ids.append(config.secondaryLocale) }
        var result: [SFSpeechRecognizer] = []
        for id in ids {
            if let r = Self.recognizer(for: id), r.isAvailable,
               !result.contains(where: { $0.locale.identifier == r.locale.identifier }) {
                result.append(r)
            }
        }
        if result.isEmpty, let sys = SFSpeechRecognizer(), sys.isAvailable {
            result.append(sys)
        }
        return result
    }

    // MARK: Streaming

    func beginStream(format: AVAudioFormat, options: STTRequestOptions, onPartial: @escaping (String) -> Void) throws {
        let recognizers = availableRecognizers()
        guard !recognizers.isEmpty else {
            throw NSError(domain: "AppleSpeechEngine", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Speech recognizer tidak tersedia."])
        }

        var created: [LocaleSession] = []
        for (index, recognizer) in recognizers.enumerated() {
            let request = SFSpeechAudioBufferRecognitionRequest()
            configure(request, recognizer: recognizer, options: options)
            let session = LocaleSession(locale: recognizer.locale.identifier, request: request,
                                        isPrimary: index == 0,
                                        onDevice: request.requiresOnDeviceRecognition)
            session.task = recognizer.recognitionTask(with: request) { [weak session] result, error in
                guard let session else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    session.update(result: result)
                    if session.isPrimary && !text.isEmpty {
                        DispatchQueue.main.async { onPartial(text) }
                    }
                }
                if let error { session.fail(error) }
            }
            created.append(session)
        }
        lock.lock(); sessions = created; lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let current = sessions; lock.unlock()
        for s in current { s.request.append(buffer) }
    }

    private func getSessions() -> [LocaleSession] {
        lock.lock()
        defer { lock.unlock() }
        return sessions
    }

    private func clearSessions() {
        lock.lock()
        defer { lock.unlock() }
        sessions = []
    }

    func finishStream(timeout: TimeInterval) async -> Transcript? {
        let current = getSessions()
        guard !current.isEmpty else { return nil }
        current.forEach { $0.request.endAudio() }

        var results: [Transcript] = []
        await withTaskGroup(of: Transcript?.self) { group in
            for s in current {
                group.addTask { await s.waitForFinal(timeout: timeout) }
            }
            for await t in group { if let t { results.append(t) } }
        }
        current.forEach { $0.task?.cancel() }
        let records = current.map { $0.diagnosticsRecord() }
        lock.lock(); lastEngineRecords = records; lock.unlock()
        clearSessions()

        for t in results {
            STTLog.info("[STT_RAW] [apple:\(t.language ?? "?")] conf=\(t.confidence.map { String(format: "%.2f", $0) } ?? "n/a") isFinal=\(t.isFinal) lowConf=[\(t.lowConfidenceWords.joined(separator: ", "))] text=\"\(t.text)\"")
        }
        let chosen = Self.pickBest(results, primaryLocale: current.first?.locale)
        STTLog.info("[STT_FINAL] Chosen apple locale=\(chosen?.language ?? "-") text=\"\(chosen?.text ?? "")\"")
        return chosen
    }

    func cancelStream() {
        lock.lock(); let current = sessions; sessions = []; lock.unlock()
        for s in current {
            s.request.endAudio()
            s.task?.cancel()
        }
    }

    /// The primary locale wins unless it heard nothing, or the secondary is
    /// clearly more confident (≥ 0.12 higher mean segment confidence), or
    /// the secondary captured a known contextual entity that primary distorted.
    static func pickBest(_ results: [Transcript], primaryLocale: String?) -> Transcript? {
        let nonEmpty = results.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return nil }
        let primary = nonEmpty.first { $0.language == primaryLocale }
        guard let primary else { return nonEmpty.first }
        guard let secondary = nonEmpty.first(where: { $0.language != primaryLocale }) else { return primary }

        let primaryLower = primary.text.lowercased()
        let secondaryLower = secondary.text.lowercased()

        // If secondary captured a known contextual entity (e.g., song title 'manchild') that primary distorted into an unrelated word ('mental')
        if !primaryLower.contains("manchild") && secondaryLower.contains("manchild") {
            STTLog.info("[AppleSpeechEngine] Secondary locale captured target entity 'manchild' (primary text: \"\(primary.text)\", secondary text: \"\(secondary.text)\")")
            return secondary
        }

        if let pc = primary.confidence, let sc = secondary.confidence, sc - pc >= 0.12 {
            return secondary
        }
        return primary
    }

    // MARK: Batch (complete utterance file)

    func transcribe(wavFile: URL, options: STTRequestOptions) async throws -> Transcript {
        let recognizers = availableRecognizers()
        guard !recognizers.isEmpty else {
            throw NSError(domain: "AppleSpeechEngine", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Speech recognizer tidak tersedia."])
        }
        var results: [Transcript] = []
        for (index, recognizer) in recognizers.enumerated() {
            let request = SFSpeechURLRecognitionRequest(url: wavFile)
            configure(request, recognizer: recognizer, options: options)
            let session = LocaleSession(locale: recognizer.locale.identifier, request: nil, isPrimary: index == 0,
                                        onDevice: request.requiresOnDeviceRecognition)
            session.task = recognizer.recognitionTask(with: request) { [weak session] result, error in
                if let result { session?.update(result: result) }
                if let error { session?.fail(error) }
            }
            if let t = await session.waitForFinal(timeout: 30) { results.append(t) }
        }
        return Self.pickBest(results, primaryLocale: recognizers.first?.locale.identifier)
            ?? Transcript(text: "", provider: id)
    }

    private func configure(_ request: SFSpeechRecognitionRequest, recognizer: SFSpeechRecognizer, options: STTRequestOptions) {
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = options.isDictation ? .dictation : .unspecified
        // Apple caps contextual strings at 100 phrases.
        request.contextualStrings = Array(options.contextualStrings.prefix(100))
        if config.requiresOnDevice && recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
    }
}

// MARK: - Per-locale session

private final class LocaleSession: @unchecked Sendable {
    let locale: String
    let request: SFSpeechAudioBufferRecognitionRequest!
    let isPrimary: Bool
    let onDevice: Bool
    var task: SFSpeechRecognitionTask?

    private enum Completion { case final, error, timeout }

    private let lock = NSLock()
    private var latest: SFSpeechRecognitionResult?
    private var finished = false
    private var completion: Completion?
    private var errorText: String?
    private var waitStartedAt: DispatchTime?
    private var completedAt: DispatchTime?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(locale: String, request: SFSpeechAudioBufferRecognitionRequest?, isPrimary: Bool, onDevice: Bool) {
        self.locale = locale
        self.request = request
        self.isPrimary = isPrimary
        self.onDevice = onDevice
    }

    func update(result: SFSpeechRecognitionResult) {
        lock.lock()
        latest = result
        let done = result.isFinal
        lock.unlock()
        if done { complete(.final) }
    }

    func fail(_ error: Error) {
        let ns = error as NSError
        // 203/216/301 = cancelled/no-op, 1110 = no speech detected.
        let benign: Set<Int> = [203, 216, 301, 1110]
        let isBenign = ns.domain == "kAFAssistantErrorDomain" && benign.contains(ns.code)
        if !isBenign {
            STTLog.error("Apple STT [\(locale)] error \(ns.domain)#\(ns.code): \(ns.localizedDescription)")
        }
        lock.lock()
        // 1110 ("no speech detected") is an outcome worth recording, cancellations are not.
        if !isBenign || ns.code == 1110, errorText == nil { errorText = "\(ns.domain)#\(ns.code)" }
        lock.unlock()
        complete(.error)
    }

    private func complete(_ how: Completion) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        completion = how
        completedAt = DispatchTime.now()
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    private func getLatestResult() -> SFSpeechRecognitionResult? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func waitForFinal(timeout: TimeInterval) async -> Transcript? {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if waitStartedAt == nil { waitStartedAt = DispatchTime.now() }
            if finished {
                lock.unlock()
                cont.resume()
                return
            }
            waiters.append(cont)
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.complete(.timeout)
            }
        }
        let result = getLatestResult()
        guard let result else { return nil }
        return annotate(Self.transcript(from: result, locale: locale))
    }

    private func annotate(_ t: Transcript) -> Transcript {
        var t = t
        lock.lock()
        t.timedOut = completion == .timeout
        if let start = waitStartedAt, let end = completedAt, end.uptimeNanoseconds >= start.uptimeNanoseconds {
            t.latencyMs = Int((end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        }
        lock.unlock()
        t.onDevice = onDevice
        return t
    }

    /// Diagnostics record for this locale, including empty/errored results.
    func diagnosticsRecord() -> [String: Any] {
        lock.lock(); let err = errorText; lock.unlock()
        let base = getLatestResult().map { Self.transcript(from: $0, locale: locale) }
            ?? Transcript(text: "", confidence: nil, language: locale, durationMs: nil, provider: "apple", isFinal: false)
        return annotate(base).diagnosticsRecord(error: err)
    }

    static func transcript(from result: SFSpeechRecognitionResult, locale: String) -> Transcript {
        let best = result.bestTranscription
        let segments = best.segments
        let scored = segments.filter { $0.confidence > 0 }
        // Apple reports 0 for every segment of non-final hypotheses: in that
        // case confidence is unknown, not zero.
        let confidence: Double? = scored.isEmpty
            ? nil
            : scored.reduce(0.0) { $0 + Double($1.confidence) } / Double(scored.count)
        let low = scored.filter { $0.confidence < 0.5 }.map { $0.substring }
        let durationMs = segments.last.map { Int(($0.timestamp + $0.duration) * 1000) }
        return Transcript(text: best.formattedString.trimmingCharacters(in: .whitespacesAndNewlines),
                          confidence: confidence,
                          language: locale,
                          durationMs: durationMs,
                          provider: "apple",
                          lowConfidenceWords: low,
                          isFinal: result.isFinal)
    }
}
