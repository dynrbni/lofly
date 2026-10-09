import Foundation
import SwiftUI
import Combine

/// Presentation state for the desktop app.
///
/// Reads from `AppState.shared` and `AgentClient.shared` — the same singletons
/// the notch uses — so this is a view over the agent, never a second one. It
/// holds no agent logic of its own.
@MainActor
public final class DesktopStore: ObservableObject {
    /// One store shared by the window, the sidebar, and the voice session so
    /// every surface reads the same state.
    public static let shared = DesktopStore()

    // Connection + agent state, mirrored from the shared singletons.
    @Published public private(set) var isConnected = false
    @Published public private(set) var agentState: AssistantState = .idle
    @Published public private(set) var liveTranscript: String = ""

    // Sidebar & Layout State
    @Published public var isSidebarVisible: Bool = true
    @Published public var openThreadIds: [String] = []
    @Published public private(set) var navigationHistory: [String?] = []
    @Published public private(set) var navigationIndex: Int = -1

    // Typewriter & Animations
    @Published public var newlyArrivedMessageId: String?
    @Published public var messageRatings: [String: MessageRating] = [:]

    // Conversations
    @Published public private(set) var conversations: [ConversationSummary] = []
    @Published public private(set) var selectedConversationId: String?
    @Published public private(set) var messages: [ConversationMessage] = []
    @Published public var composerText: String = ""
    @Published public var attachments: [ChatAttachment] = []
    @Published public var reasoningLevel: String = "medium"

    // Tasks
    @Published public private(set) var tasks: [TaskSnapshot] = []
    @Published public private(set) var activeTask: TaskSnapshot?

    // Live voice session (push-to-talk while the desktop is open).
    // Echoes the shared speech pipeline so the chat panel can show what the
    // notch would have shown. Messages here are in-memory only — the server
    // never persists voice into conversation history.
    @Published public private(set) var voiceSession: VoiceSession?

    // Sidebar search over conversation history.
    @Published public var historySearch: String = "" {
        didSet { refreshConversations(search: normalizedSearch) }
    }

    // Control center data
    @Published public private(set) var integrations: [IntegrationDescriptor] = []
    @Published public private(set) var skills: [SkillDescriptor] = []
    @Published public private(set) var isLoadingSkills = false
    @Published public private(set) var memory: [MemoryItem] = []
    @Published public private(set) var activity: [ActivityEntry] = []
    @Published public private(set) var settings: LoflySettings = .default
    @Published public private(set) var account: AccountSession = AccountSession(
        signedIn: false, displayName: nil, storage: "none", updatedAt: nil
    )

    @Published public private(set) var isSending = false
    @Published public private(set) var isStreaming = false
    @Published public private(set) var activeStreamingMessageId: String?
    @Published public private(set) var banner: String?

    /// Bumped whenever a message arrives so the transcript view can scroll.
    @Published public private(set) var scrollTrigger = UUID()

    private var activeStreamTask: Task<Void, Never>?
    private var streamBuffer = ""
    private var streamFlushTimer: Timer?
    private var lastScrollTime: Date = .distantPast

    /// Set by the sidebar / root view so a push-to-talk started from any
    /// section can bring the chat surface forward.
    @Published public var activeSurface: DesktopSurface = .chat

    private let appState: AppState
    private let client: AgentClient
    private var cancellables = Set<AnyCancellable>()
    private var didBind = false

    private var normalizedSearch: String? {
        let trimmed = historySearch.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Defaults are resolved lazily because `AppState` and `AgentClient` are
    /// main-actor isolated singletons.
    public init(appState: AppState? = nil, client: AgentClient? = nil) {
        let resolvedAppState = appState ?? AppState.shared
        let resolvedClient = client ?? AgentClient.shared

        self.appState = resolvedAppState
        self.client = resolvedClient
        self.isConnected = resolvedAppState.isConnected
        self.agentState = resolvedAppState.state
        self.liveTranscript = resolvedAppState.liveTranscript
    }

    /// Wires the shared event streams exactly once.
    public func bind() {
        guard !didBind else { return }
        didBind = true

        appState.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isConnected = value }
            .store(in: &cancellables)

        appState.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.agentState = value }
            .store(in: &cancellables)

        appState.$liveTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.liveTranscript = value
                self?.updateVoiceTranscript(value)
            }
            .store(in: &cancellables)

        // Live task updates arrive over the same socket the notch uses.
        client.onTaskUpdate = { [weak self] task in
            Task { @MainActor in self?.applyTaskUpdate(task) }
        }

        // Live conversation updates (e.g. AI-generated title)
        client.onConversationUpdated = { [weak self] convId, title in
            Task { @MainActor in
                if let title = title {
                    self?.conversations = self?.conversations.map {
                        var summary = $0
                        if summary.id == convId { summary.title = title }
                        return summary
                    } ?? []
                }
                self?.refreshConversations()
            }
        }

        // Permission changes are already tracked by AppState; reflect them.
        appState.$isAccessibilityGranted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Tasks

    private func applyTaskUpdate(_ task: TaskSnapshot) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.insert(task, at: 0)
        }
        if task.isRunning {
            activeTask = task
        } else if activeTask?.id == task.id {
            activeTask = nil
        }
        NotificationService.shared.notifyTask(
            task,
            isForeground: NSApp.isActive
        )
    }

    public func refreshTasks() {
        client.listTasks { [weak self] result in
            if case .success(let list) = result {
                self?.tasks = list
                self?.activeTask = list.first(where: { $0.isRunning })
            }
        }
    }

    public func cancelActiveTask() {
        guard let task = activeTask else { return }
        // Cancel through the same path the notch uses.
        appState.cancelCurrentTask()
        client.cancelTask(id: task.id)
    }

    /// Cancels one specific task. The Activity screen can show more than one
    /// unfinished task, so a per-row action must not fall back to "whatever is
    /// active right now".
    public func cancelTask(_ task: TaskSnapshot) {
        client.cancelTask(id: task.id) { [weak self] _ in
            self?.refreshTasks()
            self?.refreshActivity()
        }
    }

    // MARK: - Sidebar & Layout

    public func toggleSidebar() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            isSidebarVisible.toggle()
        }
    }

    // MARK: - Ratings & Typewriter

    public func toggleRating(for messageId: String, rating: MessageRating) {
        if messageRatings[messageId] == rating {
            messageRatings.removeValue(forKey: messageId)
        } else {
            messageRatings[messageId] = rating
        }
    }

    public func clearNewlyArrivedMessage(_ id: String) {
        if newlyArrivedMessageId == id {
            newlyArrivedMessageId = nil
        }
    }

    // MARK: - Navigation History (Back / Forward)

    public var canGoBack: Bool {
        navigationIndex > 0
    }

    public var canGoForward: Bool {
        navigationIndex >= 0 && navigationIndex < navigationHistory.count - 1
    }

    private func recordNavigation(_ convId: String?) {
        if navigationIndex >= 0 && navigationIndex < navigationHistory.count {
            navigationHistory = Array(navigationHistory.prefix(navigationIndex + 1))
        }
        if navigationHistory.last != convId {
            navigationHistory.append(convId)
            navigationIndex = navigationHistory.count - 1
        }
    }

    public func goBack() {
        guard canGoBack else { return }
        navigationIndex -= 1
        let target = navigationHistory[navigationIndex]
        if let target {
            selectConversation(target, pushHistory: false)
        } else {
            newConversation(pushHistory: false)
        }
    }

    public func goForward() {
        guard canGoForward else { return }
        navigationIndex += 1
        let target = navigationHistory[navigationIndex]
        if let target {
            selectConversation(target, pushHistory: false)
        } else {
            newConversation(pushHistory: false)
        }
    }

    // MARK: - Conversations & Threads

    public func refreshConversations(search: String? = nil) {
        client.listConversations(search: search) { [weak self] result in
            if case .success(let list) = result {
                // Only show conversations that actually have messages in the history (ChatGPT behavior)
                self?.conversations = list.filter { $0.messageCount > 0 }
            }
        }
    }

    /// Prepares a new chat draft without creating an empty entry in history.
    /// History is only created when the first prompt is sent (like ChatGPT).
    public func newConversation(pushHistory: Bool = true) {
        selectedConversationId = nil
        messages = []
        composerText = ""
        attachments = []
        voiceSession = nil
        activeSurface = .chat
        client.resetConversation()
        if pushHistory {
            recordNavigation(nil)
        }
    }

    /// Selects a conversation and makes sure the chat surface is showing.
    public func openConversation(_ id: String) {
        activeSurface = .chat
        selectConversation(id)
    }

    public func selectConversation(_ id: String, pushHistory: Bool = true) {
        if !openThreadIds.contains(id) {
            openThreadIds.append(id)
        }
        selectedConversationId = id
        activeSurface = .chat
        if pushHistory {
            recordNavigation(id)
        }
        client.loadConversation(id: id) { [weak self] result in
            if case .success(let conversation) = result {
                self?.messages = conversation.messages
                self?.scrollTrigger = UUID()
            }
        }
    }

    public func closeThread(_ id: String) {
        openThreadIds.removeAll(where: { $0 == id })
        if selectedConversationId == id {
            if let last = openThreadIds.last {
                selectConversation(last)
            } else {
                newConversation()
            }
        }
    }

    public func renameConversation(_ id: String, to title: String) {
        client.renameConversation(id: id, title: title) { [weak self] result in
            if case .success(let conversation) = result {
                self?.conversations = self?.conversations.map {
                    var summary = $0
                    if summary.id == conversation.id { summary.title = conversation.title }
                    return summary
                } ?? []
            }
        }
    }

    public func deleteConversation(_ id: String) {
        openThreadIds.removeAll(where: { $0 == id })
        client.deleteConversation(id: id) { [weak self] _ in
            guard let self else { return }
            if self.selectedConversationId == id {
                if let last = self.openThreadIds.last {
                    self.selectConversation(last)
                } else {
                    self.newConversation()
                }
            }
            self.refreshConversations()
        }
    }

    // MARK: - Sending

    // MARK: - Sending

    public func addAttachment(url: URL) {
        if !attachments.contains(where: { $0.url == url }) {
            attachments.append(ChatAttachment(url: url))
        }
    }

    public func removeAttachment(id: UUID) {
        attachments.removeAll(where: { $0.id == id })
    }

    public func clearAttachments() {
        attachments.removeAll()
    }

    /// Sends the composer text and attachments. Prompts are streamed progressively in real-time
    /// with natural token typing animation, blinking cursor, and live auto-scroll.
    public func send() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingAttachments = attachments
        guard (!text.isEmpty || !pendingAttachments.isEmpty), !isSending, !isStreaming else { return }

        composerText = ""
        attachments.removeAll()
        isSending = true
        isStreaming = true

        var userDisplayText = text
        if !pendingAttachments.isEmpty {
            let names = pendingAttachments.map { $0.name }.joined(separator: ", ")
            if userDisplayText.isEmpty {
                userDisplayText = "📎 \(names)"
            } else {
                userDisplayText += "\n📎 \(names)"
            }
        }

        // 1. Optimistically append user message to the active chat
        let userMsg = ConversationMessage(
            id: "user-\(UUID().uuidString)",
            role: .user,
            text: userDisplayText,
            createdAt: Date().timeIntervalSince1970 * 1000,
            taskId: nil,
            error: nil
        )
        messages.append(userMsg)

        // 2. Add an assistant thinking placeholder
        let pendingId = "pending-\(UUID().uuidString)"
        activeStreamingMessageId = pendingId
        streamBuffer = ""
        let pendingMsg = ConversationMessage(
            id: pendingId,
            role: .assistant,
            text: "",
            createdAt: Date().timeIntervalSince1970 * 1000,
            taskId: nil,
            error: nil
        )
        messages.append(pendingMsg)
        scrollTrigger = UUID()

        // 3. Dispatch real incremental streaming query
        activeStreamTask = client.sendStreamQuery(
            text: text.isEmpty ? "Tolong analisa lampiran berikut." : text,
            source: .text,
            reasoningLevel: reasoningLevel,
            attachments: pendingAttachments.map { $0.url.path },
            conversationId: selectedConversationId,
            onChunk: { [weak self] chunk in
                guard let self = self else { return }
                self.appendStreamChunk(chunk, messageId: pendingId)
            },
            completion: { [weak self] result in
                guard let self = self else { return }
                self.finishStreaming(pendingId: pendingId, result: result)
            }
        )
    }

    private func appendStreamChunk(_ chunk: String, messageId: String) {
        streamBuffer += chunk
        startFlushTimer(for: messageId)
    }

    private func startFlushTimer(for messageId: String) {
        guard streamFlushTimer == nil else { return }
        streamFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            Task { @MainActor [weak self] in
                self?.flushStreamBuffer(for: messageId)
            }
        }
    }

    private func flushStreamBuffer(for messageId: String) {
        guard !streamBuffer.isEmpty else {
            if !isStreaming {
                streamFlushTimer?.invalidate()
                streamFlushTimer = nil
            }
            return
        }

        let count = streamBuffer.count
        let dynamicStep = max(2, count / 4)
        let step = max(1, min(count, dynamicStep))
        let chunk = String(streamBuffer.prefix(step))
        streamBuffer = String(streamBuffer.dropFirst(step))

        if let index = messages.firstIndex(where: { $0.id == messageId }) {
            messages[index].text += chunk
            throttleScroll()
        }
    }

    private func throttleScroll() {
        let now = Date()
        if now.timeIntervalSince(lastScrollTime) >= 0.08 {
            lastScrollTime = now
            scrollTrigger = UUID()
        }
    }

    private func finishStreaming(pendingId: String, result: Result<AgentQueryResponse, Error>) {
        activeStreamTask = nil
        streamFlushTimer?.invalidate()
        streamFlushTimer = nil

        // Flush any remaining buffer
        if !streamBuffer.isEmpty {
            if let index = messages.firstIndex(where: { $0.id == pendingId }) {
                messages[index].text += streamBuffer
            }
            streamBuffer = ""
        }

        if case .success(let response) = result {
            if let newConvId = response.conversationId, !newConvId.isEmpty {
                self.selectedConversationId = newConvId
                if !self.openThreadIds.contains(newConvId) {
                    self.openThreadIds.append(newConvId)
                }
                self.recordNavigation(newConvId)
            }
        }

        // Update or replace the pending message
        if let index = self.messages.firstIndex(where: { $0.id == pendingId }) {
            switch result {
            case .success(let response):
                let currentText = self.messages[index].text
                let finalText = !response.text.isEmpty ? response.text : currentText
                self.messages[index] = ConversationMessage(
                    id: pendingId,
                    role: .assistant,
                    text: finalText.isEmpty ? "✓ Perintah selesai dijalankan." : finalText,
                    createdAt: Date().timeIntervalSince1970 * 1000,
                    taskId: response.taskId,
                    error: response.error
                )
            case .failure(let error):
                self.banner = error.localizedDescription
                let currentText = self.messages[index].text
                self.messages[index] = ConversationMessage(
                    id: pendingId,
                    role: .assistant,
                    text: currentText.isEmpty ? "Gue nggak bisa menghubungi agent server." : currentText,
                    createdAt: Date().timeIntervalSince1970 * 1000,
                    taskId: nil,
                    error: error.localizedDescription
                )
            }
        } else {
            switch result {
            case .success(let response):
                self.messages.append(
                    ConversationMessage(
                        id: "assistant-\(UUID().uuidString)",
                        role: .assistant,
                        text: response.text.isEmpty ? "✓ Perintah selesai dijalankan." : response.text,
                        createdAt: Date().timeIntervalSince1970 * 1000,
                        taskId: response.taskId,
                        error: response.error
                    )
                )
            case .failure(let error):
                self.banner = error.localizedDescription
            }
        }

        self.isSending = false
        self.isStreaming = false
        self.activeStreamingMessageId = nil
        self.scrollTrigger = UUID()
        self.refreshConversations()
        self.refreshTasks()
        self.refreshActivity()
    }

    /// Stops the active generation immediately, preserves all already-streamed text,
    /// cancels the backend LLM task, and removes the blinking caret indicator.
    public func stopStreaming() {
        guard isStreaming || isSending else { return }
        activeStreamTask?.cancel()
        activeStreamTask = nil
        streamFlushTimer?.invalidate()
        streamFlushTimer = nil

        if let id = activeStreamingMessageId, let index = messages.firstIndex(where: { $0.id == id }) {
            if !streamBuffer.isEmpty {
                messages[index].text += streamBuffer
            }
            streamBuffer = ""
            if messages[index].text.isEmpty {
                messages[index].text = "(Response stopped)"
            }
        }
        streamBuffer = ""

        isSending = false
        isStreaming = false
        activeStreamingMessageId = nil
        scrollTrigger = UUID()

        // Inform backend to abort LLM completion
        client.sendCancel()
    }

    public func cancelCurrentTask() {
        cancelActiveTask()
    }

    // MARK: - Control center

    public func refreshIntegrations() {
        client.listIntegrations { [weak self] result in
            if case .success(let list) = result { self?.integrations = list }
        }
    }

    /// The agent's own capability list. Read-only by design: skills are
    /// declared on the server, so there is nothing to configure here.
    public func refreshSkills() {
        isLoadingSkills = true
        client.listSkills { [weak self] result in
            guard let self else { return }
            self.isLoadingSkills = false
            switch result {
            case .success(let list):
                self.skills = list
            case .failure(let error):
                self.banner = error.localizedDescription
            }
        }
    }

    public func refreshMemory() {
        client.listMemory { [weak self] result in
            if case .success(let list) = result { self?.memory = list }
        }
    }

    public func updateMemory(_ item: MemoryItem, content: String) {
        client.updateMemory(id: item.id, content: content) { [weak self] _ in
            self?.refreshMemory()
        }
    }

    public func deleteMemory(_ item: MemoryItem) {
        client.deleteMemory(id: item.id) { [weak self] _ in
            self?.refreshMemory()
        }
    }

    public func clearAllMemory() {
        client.clearMemory { [weak self] _ in
            self?.refreshMemory()
        }
    }

    public func refreshActivity() {
        client.listActivity { [weak self] result in
            if case .success(let list) = result { self?.activity = list }
        }
    }

    public func refreshSettings() {
        client.loadSettings { [weak self] result in
            if case .success(let value) = result { self?.settings = value }
        }
    }

    public func updateSettings(_ patch: [String: Any]) {
        client.updateSettings(patch) { [weak self] result in
            if case .success(let value) = result { self?.settings = value }
        }
    }

    public func refreshAccount() {
        client.loadAccount { [weak self] result in
            if case .success(let value) = result { self?.account = value }
        }
    }

    public func signIn(name: String) {
        client.signIn(displayName: name) { [weak self] result in
            switch result {
            case .success(let session): self?.account = session
            case .failure(let error): self?.banner = error.localizedDescription
            }
        }
    }

    public func signOut() {
        client.signOut { [weak self] result in
            if case .success(let session) = result { self?.account = session }
        }
    }

    // MARK: - Voice session (push-to-talk while the desktop is open)

    /// Called by AppState when push-to-talk starts with the desktop window
    /// open: the notch stays hidden and this surface takes over.
    func beginVoiceSession() {
        activeSurface = .chat
        liveTranscript = ""
        voiceSession = VoiceSession(transcript: "")
    }

    /// Live transcript while the mic is open.
    func updateVoiceTranscript(_ text: String) {
        guard voiceSession != nil else { return }
        voiceSession?.transcript = text
    }

    /// The agent answered. Shown inline, never persisted: the query already
    /// went to the server marked as voice, so history stays clean.
    func finishVoiceSession(response: String?, error: String?) {
        guard var session = voiceSession else { return }
        session.isRunning = false
        session.responseText = response
        session.errorMessage = error
        voiceSession = session
    }

    /// Dismisses the finished session card.
    public func dismissVoiceSession() {
        voiceSession = nil
    }

    public func dismissBanner() {
        banner = nil
    }
}

// MARK: - Chat Attachment

public struct ChatAttachment: Identifiable, Hashable {
    public let id: UUID
    public let url: URL
    public let name: String
    public let isImage: Bool
    public let fileSize: String

    public init(url: URL) {
        self.id = UUID()
        self.url = url
        self.name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        self.isImage = ["png", "jpg", "jpeg", "heic", "webp", "gif"].contains(ext)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            if size > 1_000_000 {
                self.fileSize = String(format: "%.1f MB", Double(size) / 1_000_000.0)
            } else {
                self.fileSize = "\(max(1, size / 1000)) KB"
            }
        } else {
            self.fileSize = ""
        }
    }
}
