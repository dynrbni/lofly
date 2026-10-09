import Foundation

public enum AssistantState: String, Codable {
    case idle
    case listening
    case thinking
    case executing
    case speaking
    case error

    public var title: String {
        switch self {
        case .idle: return "LOFLY"
        case .listening: return "Listening..."
        case .thinking: return "Thinking..."
        case .executing: return "Executing..."
        case .speaking: return "Speaking..."
        case .error: return "Error"
        }
    }
}

public struct ConfirmationRequest: Codable, Identifiable {
    public let id: String
    public let toolName: String
    public let parameters: [String: AnyCodable]
    public let permissionLevel: String
    public let description: String
    public let timestamp: Double
}

public struct ConfirmationResponse: Codable {
    public let id: String
    public let approved: booleanValue
    public let reason: String?

    public typealias booleanValue = Bool
}

public struct AnyCodable: Codable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self.value = intVal
        } else if let doubleVal = try? container.decode(Double.self) {
            self.value = doubleVal
        } else if let stringVal = try? container.decode(String.self) {
            self.value = stringVal
        } else if let boolVal = try? container.decode(Bool.self) {
            self.value = boolVal
        } else if let dictVal = try? container.decode([String: AnyCodable].self) {
            self.value = dictVal.mapValues { $0.value }
        } else if let arrayVal = try? container.decode([AnyCodable].self) {
            self.value = arrayVal.map { $0.value }
        } else {
            self.value = ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let intVal = value as? Int {
            try container.encode(intVal)
        } else if let doubleVal = value as? Double {
            try container.encode(doubleVal)
        } else if let stringVal = value as? String {
            try container.encode(stringVal)
        } else if let boolVal = value as? Bool {
            try container.encode(boolVal)
        } else {
            try container.encode(String(describing: value))
        }
    }
}

public struct AgentQueryResponse: Codable, Sendable {
    public let text: String
    public let completed: Bool
    public let error: String?
    public let taskId: String?
    public let conversationId: String?
    public let rawTranscript: String?
    public let normalizedTranscript: String?

    public init(text: String, completed: Bool, error: String? = nil, taskId: String? = nil, conversationId: String? = nil, rawTranscript: String? = nil, normalizedTranscript: String? = nil) {
        self.text = text
        self.completed = completed
        self.error = error
        self.taskId = taskId
        self.conversationId = conversationId
        self.rawTranscript = rawTranscript
        self.normalizedTranscript = normalizedTranscript
    }
}
