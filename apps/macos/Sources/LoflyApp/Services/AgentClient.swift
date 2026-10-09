import Foundation

/// Where a query came from. Text queries belong in conversation history;
/// voice (push-to-talk) runs the same agent but never lands in history.
public enum QuerySource: String {
    case voice
    case text
}

public final class AgentClient: ObservableObject {
    public static let shared = AgentClient()

    private let baseURL: URL
    private let wsURL: URL
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession

    @Published public var isConnected = false

    public var onStateChanged: ((AssistantState) -> Void)?
    public var onConfirmationRequired: ((ConfirmationRequest) -> Void)?
    public var onSpeechStart: ((String) -> Void)?
    public var onSpeechEnd: ((String) -> Void)?
    public var onError: ((String) -> Void)?

    // Tool and task streaming. The desktop app renders progress from these
    // rather than from a second agent, so both surfaces agree.
    public var onToolStart: ((String, [String: Any]) -> Void)?
    public var onToolEnd: ((String, Bool, String?) -> Void)?
    public var onTaskUpdate: ((TaskSnapshot) -> Void)?
    public var onConversationUpdated: ((String, String?) -> Void)?

    /// Polls the server only when the socket is down. The socket remains the
    /// primary transport, so an idle app does no request traffic.
    private var reconnectProbe: Timer?
    private var healthCheckEnabled = false

    private init(host: String = "127.0.0.1", port: Int = 3847) {
        self.baseURL = URL(string: "http://\(host):\(port)")!
        self.wsURL = URL(string: "ws://\(host):\(port)/ws")!
        self.urlSession = URLSession(configuration: .default)
    }

    public func connect() {
        disconnect()
        webSocketTask = urlSession.webSocketTask(with: wsURL)
        webSocketTask?.resume()
        listenForMessages()
        DispatchQueue.main.async {
            self.isConnected = true
        }
    }

    public func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        DispatchQueue.main.async {
            self.isConnected = false
        }
    }

    private func listenForMessages() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleWebSocketMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleWebSocketMessage(text)
                    }
                @unknown default:
                    break
                }
                self.listenForMessages()

            case .failure(let error):
                print("WebSocket notice: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isConnected = false
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    self?.connect()
                }
            }
        }
    }

    private func handleWebSocketMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        DispatchQueue.main.async {
            switch type {
            case "state_change":
                if let payload = json["payload"] as? [String: Any],
                   let newStateStr = payload["newState"] as? String,
                   let state = AssistantState(rawValue: newStateStr) {
                    self.onStateChanged?(state)
                }

            case "confirmation_required":
                if let payload = json["payload"] as? [String: Any],
                   let payloadData = try? JSONSerialization.data(withJSONObject: payload),
                   let req = try? JSONDecoder().decode(ConfirmationRequest.self, from: payloadData) {
                    self.onConfirmationRequired?(req)
                }

            case "speech_start":
                if let payload = json["payload"] as? [String: Any],
                   let text = payload["text"] as? String {
                    self.onSpeechStart?(text)
                }

            case "speech_end":
                if let payload = json["payload"] as? [String: Any],
                   let text = payload["text"] as? String {
                    self.onSpeechEnd?(text)
                }

            case "error":
                if let payload = json["payload"] as? [String: Any],
                   let errorMsg = payload["error"] as? String {
                    self.onError?(errorMsg)
                }

            case "tool_start":
                if let payload = json["payload"] as? [String: Any],
                   let toolName = payload["toolName"] as? String {
                    self.onToolStart?(toolName, payload)
                }

            case "tool_end":
                if let payload = json["payload"] as? [String: Any],
                   let toolName = payload["toolName"] as? String {
                    let success = (payload["success"] as? Bool) ?? false
                    self.onToolEnd?(toolName, success, payload["error"] as? String)
                }

            case "task_update":
                if let payload = json["payload"] as? [String: Any],
                   let payloadData = try? JSONSerialization.data(withJSONObject: payload),
                   let task = try? JSONDecoder().decode(TaskSnapshot.self, from: payloadData) {
                    self.onTaskUpdate?(task)
                }

            case "conversation_updated":
                if let payload = json["payload"] as? [String: Any],
                   let convId = payload["conversationId"] as? String {
                    let title = payload["title"] as? String
                    self.onConversationUpdated?(convId, title)
                }

            default:
                break
            }
        }
    }

    /// Verifies the server is actually reachable rather than trusting that the
    /// socket was created. Used for the connection indicator in the sidebar.
    public func checkHealth(completion: @escaping (Bool) -> Void) {
        let endpoint = baseURL.appendingPathComponent("health")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.0

        urlSession.dataTask(with: request) { _, response, error in
            let ok = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }

    public func setHealthCheckEnabled(_ enabled: Bool) {
        healthCheckEnabled = enabled
        reconnectProbe?.invalidate()
        reconnectProbe = enabled
            ? Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                guard let self = self, !self.isConnected else { return }
                self.checkHealth { [weak self] ok in
                    guard let self = self, ok, !self.isConnected else { return }
                    self.connect()
                }
            }
            : nil
    }

    public func sendQuery(
        text: String,
        source: QuerySource = .text,
        reasoningLevel: String = "medium",
        attachments: [String] = [],
        conversationId: String? = nil,
        voiceSessionId: String? = nil,
        completion: @escaping (Result<AgentQueryResponse, Error>) -> Void
    ) {
        let endpoint = baseURL.appendingPathComponent("query")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "text": text,
            "source": source.rawValue,
            "reasoningLevel": reasoningLevel,
            "attachments": attachments
        ]
        if let conversationId = conversationId, !conversationId.isEmpty {
            payload["conversationId"] = conversationId
        }
        if let voiceSessionId = voiceSessionId, !voiceSessionId.isEmpty {
            payload["voiceSessionId"] = voiceSessionId
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        urlSession.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let data = data else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "AgentClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                }
                return
            }
            do {
                let res = try JSONDecoder().decode(AgentQueryResponse.self, from: data)
                DispatchQueue.main.async { completion(.success(res)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    /// Real-time incremental streaming query using Server-Sent Events (SSE).
    /// Delivers small token chunks continuously as the LLM generates them.
    @discardableResult
    public func sendStreamQuery(
        text: String,
        source: QuerySource = .text,
        reasoningLevel: String = "medium",
        attachments: [String] = [],
        conversationId: String? = nil,
        onChunk: @escaping (String) -> Void,
        completion: @escaping (Result<AgentQueryResponse, Error>) -> Void
    ) -> Task<Void, Never> {
        let endpoint = baseURL.appendingPathComponent("query")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 180.0

        var payload: [String: Any] = [
            "text": text,
            "source": source.rawValue,
            "reasoningLevel": reasoningLevel,
            "attachments": attachments,
            "stream": true
        ]
        if let conversationId = conversationId, !conversationId.isEmpty {
            payload["conversationId"] = conversationId
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        return Task {
            do {
                let (bytes, response) = try await urlSession.bytes(for: request)
                if let httpRes = response as? HTTPURLResponse, httpRes.statusCode != 200 {
                    throw NSError(
                        domain: "AgentClient",
                        code: httpRes.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "Server returned status \(httpRes.statusCode)"]
                    )
                }

                var fullText = ""
                var completed = true
                var errorString: String? = nil
                var taskId: String? = nil
                var returnConvId: String? = nil

                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.hasPrefix("data: ") else { continue }
                    let jsonText = String(trimmed.dropFirst(6))
                    guard let jsonData = jsonText.data(using: .utf8),
                          let event = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                          let type = event["type"] as? String else {
                        continue
                    }

                    if type == "chunk", let chunk = event["text"] as? String {
                        fullText += chunk
                        DispatchQueue.main.async {
                            onChunk(chunk)
                        }
                    } else if type == "done" {
                        completed = (event["completed"] as? Bool) ?? true
                        errorString = event["error"] as? String
                        taskId = event["taskId"] as? String
                        returnConvId = event["conversationId"] as? String
                        if let doneText = event["text"] as? String, !doneText.isEmpty {
                            fullText = doneText
                        }
                    } else if type == "error" {
                        errorString = event["error"] as? String ?? "Stream error"
                    }
                }

                if !Task.isCancelled {
                    let agentResponse = AgentQueryResponse(
                        text: fullText,
                        completed: completed,
                        error: errorString,
                        taskId: taskId,
                        conversationId: returnConvId
                    )
                    DispatchQueue.main.async {
                        completion(.success(agentResponse))
                    }
                }
            } catch {
                if !Task.isCancelled {
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    public func sendAudioFile(url: URL, completion: @escaping (Result<AgentQueryResponse, Error>) -> Void) {
        let endpoint = baseURL.appendingPathComponent("audio")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")

        guard let audioData = try? Data(contentsOf: url), !audioData.isEmpty else {
            completion(.failure(NSError(domain: "AgentClient", code: -2, userInfo: [NSLocalizedDescriptionKey: "Empty audio recording"])))
            return
        }

        request.httpBody = audioData

        urlSession.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let data = data else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "AgentClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                }
                return
            }
            do {
                let res = try JSONDecoder().decode(AgentQueryResponse.self, from: data)
                DispatchQueue.main.async { completion(.success(res)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    public func sendConfirmation(id: String, approved: Bool, reason: String? = nil) {
        let endpoint = baseURL.appendingPathComponent("confirm")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "id": id,
            "approved": approved
        ]
        if let reason = reason {
            payload["reason"] = reason
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        urlSession.dataTask(with: request).resume()
    }

    public func sendWake() {
        let endpoint = baseURL.appendingPathComponent("wake")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        urlSession.dataTask(with: request).resume()
    }

    public func sendReset() {
        let endpoint = baseURL.appendingPathComponent("reset")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        urlSession.dataTask(with: request).resume()
    }

    public func sendCancel() {
        let endpoint = baseURL.appendingPathComponent("cancel")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        urlSession.dataTask(with: request).resume()
    }

    // MARK: - Desktop control center

    private func send<T: Decodable>(
        _ method: String,
        _ path: String,
        body: [String: Any]? = nil,
        as type: T.Type,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        let endpoint = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8.0

        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        urlSession.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, (200..<300).contains(status) else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(
                        domain: "AgentClient",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Agent server returned HTTP \(status)."]
                    )))
                }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(T.self, from: data)
                DispatchQueue.main.async { completion(.success(decoded)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    private struct ConversationListResponse: Decodable {
        var conversations: [ConversationSummary]
        var activeConversationId: String?
    }

    private struct ConversationResponse: Decodable {
        var conversation: Conversation
    }

    private struct TaskListResponse: Decodable {
        var tasks: [TaskSnapshot]
        var activeTask: TaskSnapshot?
    }

    private struct TaskResponse: Decodable {
        var task: TaskSnapshot?
    }

    private struct MemoryResponse: Decodable {
        var memory: [MemoryItem]
    }

    private struct ActivityResponse: Decodable {
        var activity: [ActivityEntry]
    }

    private struct IntegrationsResponse: Decodable {
        var integrations: [IntegrationDescriptor]
    }

    private struct SkillsResponse: Decodable {
        var skills: [SkillDescriptor]
    }

    private struct SettingsResponse: Decodable {
        var settings: LoflySettings
    }

    private struct AccountResponse: Decodable {
        var account: AccountSession
    }

    private struct SimpleResponse: Decodable {
        var success: Bool?
    }

    public func listConversations(search: String? = nil, completion: @escaping (Result<[ConversationSummary], Error>) -> Void) {
        var path = "conversations"
        if let search, !search.isEmpty {
            path += "?q=\(search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        }
        send("GET", path, as: ConversationListResponse.self) { result in
            completion(result.map { $0.conversations })
        }
    }

    public func createConversation(completion: @escaping (Result<Conversation, Error>) -> Void) {
        send("POST", "conversations", body: [:], as: ConversationResponse.self) {
            completion($0.map { $0.conversation })
        }
    }

    public func resetConversation(completion: ((Result<Bool, Error>) -> Void)? = nil) {
        send("POST", "conversations/reset", body: [:], as: SimpleResponse.self) {
            completion?($0.map { $0.success ?? true })
        }
    }

    public func loadConversation(id: String, completion: @escaping (Result<Conversation, Error>) -> Void) {
        send("GET", "conversations/\(id)", as: ConversationResponse.self) {
            completion($0.map { $0.conversation })
        }
    }

    public func renameConversation(id: String, title: String, completion: ((Result<Conversation, Error>) -> Void)? = nil) {
        send("PATCH", "conversations/\(id)", body: ["title": title], as: ConversationResponse.self) {
            completion?($0.map { $0.conversation })
        }
    }

    public func deleteConversation(id: String, completion: ((Result<Bool, Error>) -> Void)? = nil) {
        send("DELETE", "conversations/\(id)", as: SimpleResponse.self) {
            completion?($0.map { $0.success ?? false })
        }
    }

    public func listTasks(completion: @escaping (Result<[TaskSnapshot], Error>) -> Void) {
        send("GET", "tasks", as: TaskListResponse.self) {
            completion($0.map { $0.tasks })
        }
    }

    public func cancelTask(id: String, completion: ((Result<TaskSnapshot?, Error>) -> Void)? = nil) {
        send("POST", "tasks/\(id)/cancel", as: TaskResponse.self) {
            completion?($0.map { $0.task })
        }
    }

    public func listMemory(completion: @escaping (Result<[MemoryItem], Error>) -> Void) {
        send("GET", "memory", as: MemoryResponse.self) {
            completion($0.map { $0.memory })
        }
    }

    public func updateMemory(id: String, content: String, completion: ((Result<Bool, Error>) -> Void)? = nil) {
        send("PATCH", "memory/\(id)", body: ["content": content], as: SimpleResponse.self) {
            completion?($0.map { $0.success ?? false })
        }
    }

    public func deleteMemory(id: String, completion: ((Result<Bool, Error>) -> Void)? = nil) {
        send("DELETE", "memory/\(id)", as: SimpleResponse.self) {
            completion?($0.map { $0.success ?? false })
        }
    }

    public func clearMemory(completion: ((Result<Bool, Error>) -> Void)? = nil) {
        send("DELETE", "memory", as: SimpleResponse.self) {
            completion?($0.map { $0.success ?? false })
        }
    }

    public func listActivity(limit: Int = 200, completion: @escaping (Result<[ActivityEntry], Error>) -> Void) {
        send("GET", "activity?limit=\(limit)", as: ActivityResponse.self) {
            completion($0.map { $0.activity })
        }
    }

    public func listIntegrations(completion: @escaping (Result<[IntegrationDescriptor], Error>) -> Void) {
        send("GET", "integrations", as: IntegrationsResponse.self) {
            completion($0.map { $0.integrations })
        }
    }

    /// The agent's own capability list, read from its tool registry.
    public func listSkills(completion: @escaping (Result<[SkillDescriptor], Error>) -> Void) {
        send("GET", "skills", as: SkillsResponse.self) {
            completion($0.map { $0.skills })
        }
    }

    public func loadSettings(completion: @escaping (Result<LoflySettings, Error>) -> Void) {
        send("GET", "settings", as: SettingsResponse.self) {
            completion($0.map { $0.settings })
        }
    }

    public func updateSettings(_ patch: [String: Any], completion: ((Result<LoflySettings, Error>) -> Void)? = nil) {
        send("PATCH", "settings", body: patch, as: SettingsResponse.self) {
            completion?($0.map { $0.settings })
        }
    }

    public func loadAccount(completion: @escaping (Result<AccountSession, Error>) -> Void) {
        send("GET", "account", as: AccountResponse.self) {
            completion($0.map { $0.account })
        }
    }

    public func signIn(displayName: String, completion: @escaping (Result<AccountSession, Error>) -> Void) {
        send("POST", "account/sign-in", body: ["displayName": displayName], as: AccountResponse.self) {
            completion($0.map { $0.account })
        }
    }

    public func signOut(completion: @escaping (Result<AccountSession, Error>) -> Void) {
        send("POST", "account/sign-out", as: AccountResponse.self) {
            completion($0.map { $0.account })
        }
    }
}
