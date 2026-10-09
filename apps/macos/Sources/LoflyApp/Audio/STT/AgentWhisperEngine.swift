import Foundation

/// Cloud Whisper provider, reached through the local agent (`POST /transcribe`)
/// so API keys stay in the agent's `.env` and never in the app.
///
/// Whisper sees the complete VAD-trimmed utterance at 16 kHz mono and detects
/// the language itself, which handles Indonesian–English code-switching far
/// better than a single-locale recognizer. It is only used when the agent
/// reports a configured provider (`GET /stt/config`).
final class AgentWhisperEngine: STTEngine, @unchecked Sendable {
    let id = "whisper"
    private let baseURL: URL
    private let timeout: TimeInterval

    init(baseURL: URL = URL(string: "http://127.0.0.1:3847")!, timeout: TimeInterval) {
        self.baseURL = baseURL
        self.timeout = timeout
    }

    func transcribe(wavFile: URL, options: STTRequestOptions) async throws -> Transcript {
        var request = URLRequest(url: baseURL.appendingPathComponent("transcribe"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Data(contentsOf: wavFile)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "AgentWhisperEngine", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "transcribe failed: \(body.prefix(200))"])
        }
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        return Transcript(text: decoded.text.trimmingCharacters(in: .whitespacesAndNewlines),
                          confidence: decoded.confidence,
                          language: decoded.language,
                          durationMs: decoded.durationMs,
                          provider: decoded.provider ?? id,
                          lowConfidenceWords: [],
                          isFinal: true)
    }

    private struct Payload: Decodable {
        let text: String
        let confidence: Double?
        let language: String?
        let durationMs: Int?
        let provider: String?
    }
}

/// Speech settings served by the agent: the shared, configurable vocabulary
/// and whether a cloud final-pass provider is available.
struct AgentSTTSettings: Decodable {
    let cloudProvider: String?
    let contextualStrings: [String]

    static func fetch(baseURL: URL = URL(string: "http://127.0.0.1:3847")!) async -> AgentSTTSettings? {
        var request = URLRequest(url: baseURL.appendingPathComponent("stt/config"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(AgentSTTSettings.self, from: data)
    }
}
