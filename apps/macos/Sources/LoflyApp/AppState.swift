import Foundation
import SwiftUI
import Combine

public func getNotchScreen() -> NSScreen {
    if let notchScreen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
        return notchScreen
    }
    if #available(macOS 12.0, *) {
        if let notchScreen = NSScreen.screens.first(where: { $0.auxiliaryTopLeftArea != nil }) {
            return notchScreen
        }
    }
    return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
}

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    @Published public var state: AssistantState = .idle
    @Published public var isConnected = false
    @Published public var lastResponse: String = ""
    @Published public var liveTranscript: String = ""
    @Published public var inputText: String = ""
    @Published public var finalUserInput: String = ""
    @Published public var rawTranscript: String = ""
    @Published public var normalizedTranscript: String = ""
    @Published public var currentVoiceSessionId: String? = nil
    @Published public var pendingConfirmation: ConfirmationRequest? = nil
    @Published public var isOverlayVisible = false
    @Published public var isVisibleOnScreen = false
    @Published public var isOutputExpanded = false
    @Published public var notchTopInset: CGFloat = 32.0
    @Published public var audioLevel: Float = 0.0
    @Published public var isAccessibilityGranted = false
    @Published public var isMicrophoneGranted = false
    @Published public var isSpeechGranted = false
    @Published public var errorMessage: String? = nil

    public var overlayWindow: NSPanel?

    private var cancellables = Set<AnyCancellable>()
    private let client = AgentClient.shared
    private let speechRecognizer = SpeechRecognizer.shared
    private let speechSynthesizer = NativeSpeechSynthesizer.shared
    private let hotkey = HotkeyManager.shared
    private let permissions = PermissionManager.shared
    private var autoDismissWorkItem: DispatchWorkItem?
    private var hideWorkItem: DispatchWorkItem?

    /// Pending transition from "hotkey pressed" to "actually push-to-talking".
    /// Cancelled on release so a tap never opens the microphone.
    private var hotkeyArmWorkItem: DispatchWorkItem?

    private init() {
        checkPermissions()
        updateNotchMetrics()
        setupClientHandlers()
        setupSpeechHandlers()
        setupHotkey()

        // Periodically monitor system permissions (e.g. user toggles Accessibility in System Settings)
        Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkPermissions()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.checkPermissions()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.repositionOverlayWindow()
            }
            .store(in: &cancellables)

        client.connect()
    }

    public func updateNotchMetrics() {
        let screen = getNotchScreen()
        let topInset = screen.safeAreaInsets.top
        self.notchTopInset = topInset > 0 ? topInset : 0.0
    }

    public func repositionOverlayWindow() {
        guard let panel = overlayWindow else { return }
        updateNotchMetrics()
        let notchScreen = getNotchScreen()
        let screenFrame = notchScreen.frame
        let windowWidth: CGFloat = 560.0
        let windowHeight: CGFloat = 320.0
        let x = screenFrame.midX - (windowWidth / 2.0)
        let y = screenFrame.maxY - windowHeight
        let targetFrame = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)
        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: true, animate: false)
        }
    }

    public func checkPermissions() {
        let prevAX = isAccessibilityGranted
        let currentAX = permissions.isAccessibilityGranted
        if prevAX != currentAX {
            print("[AppState] Accessibility permission updated: \(currentAX)")
        }
        isAccessibilityGranted = currentAX
        isMicrophoneGranted = permissions.isMicrophoneGranted
        isSpeechGranted = permissions.isSpeechRecognitionGranted
    }

    private func setupClientHandlers() {
        client.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.isConnected = connected
            }
            .store(in: &cancellables)

        client.onStateChanged = { [weak self] newState in
            self?.state = newState
        }

        client.onConfirmationRequired = { [weak self] req in
            print("[AppState] Confirmation received for \(req.toolName). Auto-approving immediately...")
            self?.resolveConfirmation(id: req.id, approved: true)
        }

        client.onSpeechStart = { [weak self] _ in
            // User explicitly requested no robot voice - completely silent operation!
            self?.state = .idle
        }

        client.onSpeechEnd = { [weak self] _ in
            self?.state = .idle
            self?.scheduleAutoDismiss(delay: 4.0)
        }

        client.onError = { [weak self] errorMsg in
            self?.state = .error
            self?.lastResponse = "Error: \(errorMsg)"
            self?.scheduleAutoDismiss(delay: 3.0)
        }
    }

    private func setupSpeechHandlers() {
        speechRecognizer.$liveTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcript in
                guard let self = self else { return }
                self.liveTranscript = transcript
                if !transcript.isEmpty {
                    self.inputText = transcript
                }
            }
            .store(in: &cancellables)

        speechRecognizer.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.audioLevel = level
            }
            .store(in: &cancellables)

        speechRecognizer.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] err in
                if let err = err {
                    self?.errorMessage = err
                    self?.state = .error
                }
            }
            .store(in: &cancellables)

        speechRecognizer.onTranscriptFinalized = { [weak self] finalTranscript, sessionId in
            guard let self = self else { return }
            guard !self.speechRecognizer.isInAppDictation else { return }

            print("\n========================================")
            print("[VOICE]")
            print("audio session id: \(sessionId)")
            print("\n[STT_RAW]")
            print("\"\(finalTranscript)\"")
            print("\n[STT_FINAL]")
            print("\"\(finalTranscript)\"")

            // Strict session isolation: ignore any result that does not match active voice session
            guard let activeId = self.currentVoiceSessionId, sessionId == activeId else {
                print("[AppState] Discarding stale transcript from session \(sessionId) (current active: \(self.currentVoiceSessionId ?? "none"))")
                return
            }

            let query = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return }

            self.rawTranscript = query
            self.finalUserInput = query
            self.liveTranscript = query
            self.inputText = query
            print("\n[TRANSCRIPT_STATE]")
            print("\"\(query)\"")
            print("========================================\n")

            self.sendQuery(text: query, voiceSessionId: sessionId)
        }

        speechRecognizer.onAudioRecorded = { [weak self] audioURL, sessionId in
            guard let self = self else { return }
            guard let activeId = self.currentVoiceSessionId, sessionId == activeId else {
                print("[AppState] Discarding stale audio recording from session \(sessionId)")
                return
            }
            print("[AppState] Sending recorded voice audio to agent runtime (session: \(sessionId))...")
            self.autoDismissWorkItem?.cancel()
            self.state = .thinking
            self.client.sendAudioFile(url: audioURL) { [weak self] result in
                switch result {
                case .success(let res):
                    self?.lastResponse = res.text
                    self?.state = .idle
                    if DesktopWindowController.shared.isVisible {
                        DesktopStore.shared.finishVoiceSession(response: res.text, error: res.error)
                    }
                    self?.scheduleAutoDismiss(delay: 4.0)
                case .failure(let err):
                    self?.state = .error
                    self?.errorMessage = err.localizedDescription
                    self?.lastResponse = ""
                    if DesktopWindowController.shared.isVisible {
                        DesktopStore.shared.finishVoiceSession(response: nil, error: err.localizedDescription)
                    }
                    self?.scheduleAutoDismiss(delay: 4.5)
                }
            }
        }
    }

    private func setupHotkey() {
        hotkey.onHotkeyPressed = { [weak self] in
            self?.handleHotkeyPress()
        }
        hotkey.onHotkeyReleased = { [weak self] duration in
            self?.handleHotkeyRelease(duration: duration)
        }
        hotkey.registerHotkey()
    }

    // MARK: - Push to talk

    /**
     * How long Control + Option must stay down before the mic opens. Long enough
     * to discard an accidental brush against the keys, short enough that a
     * deliberate press feels immediate.
     */
    public static let pushToTalkThreshold: TimeInterval = 0.2

    /**
     * Control + Option was pressed. This only *arms* push-to-talk: nothing is
     * shown and the microphone stays closed until the key is actually held.
     */
    public func handleHotkeyPress() {
        hotkeyArmWorkItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            self?.beginPushToTalk()
        }
        hotkeyArmWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.pushToTalkThreshold,
            execute: item
        )
    }

    /// The key was genuinely held, so the capture starts.
    /// The notch overlay always appears so the user has immediate visual feedback.
    private func beginPushToTalk() {
        hotkeyArmWorkItem?.cancel()
        hotkeyArmWorkItem = nil
        autoDismissWorkItem?.cancel()

        if DesktopWindowController.shared.isVisible {
            DesktopStore.shared.beginVoiceSession()
        }

        showOverlay()
        startListening()
    }

    /// Hands-free listening, for anyone who would rather not hold the hotkey.
    /// Submission is handled by the VAD trailing-silence detector.
    public func startHandsFreeListening() {
        hotkeyArmWorkItem?.cancel()
        hotkeyArmWorkItem = nil

        if DesktopWindowController.shared.isVisible {
            DesktopStore.shared.beginVoiceSession()
        }

        showOverlay()
        startListening()
    }

    public func handleHotkeyRelease(duration: TimeInterval) {
        hotkeyArmWorkItem?.cancel()
        hotkeyArmWorkItem = nil

        // A tap is not a command. It must never leave the notch on screen or
        // leave the microphone open.
        if duration < Self.pushToTalkThreshold {
            if state == .listening || isVisibleOnScreen {
                print("[AppState] Control + Option tapped for \(String(format: "%.2f", duration))s — ignoring")
                cancelPushToTalk()
            }
            return
        }

        guard state == .listening else { return }

        let transcript = speechRecognizer.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if speechRecognizer.hasSpoken || !transcript.isEmpty {
            print("[AppState] Push-to-talk released with speech (\(transcript)). Submitting query...")
            // stopListening() finalises the transcript, which submits it.
            stopListening()
        } else {
            print("[AppState] Push-to-talk released without speech. Discarding prompt and hiding notch.")
            cancelPushToTalk()
        }
    }

    /// Tears down a capture without submitting anything.
    private func cancelPushToTalk() {
        speechRecognizer.cancelListening()
        currentVoiceSessionId = nil
        state = .idle
        finalUserInput = ""
        rawTranscript = ""
        normalizedTranscript = ""
        liveTranscript = ""
        inputText = ""
        errorMessage = nil
        pendingConfirmation = nil
        DesktopStore.shared.dismissVoiceSession()
        hideOverlay()
    }

    public func startListening() {
        cancelAutoDismiss()
        isOutputExpanded = false
        checkPermissions()
        state = .listening

        let newSessionId = UUID().uuidString
        currentVoiceSessionId = newSessionId

        // Authoritative reset: never retain previous utterance state
        finalUserInput = ""
        rawTranscript = ""
        normalizedTranscript = ""
        liveTranscript = ""
        inputText = ""
        errorMessage = nil

        speechRecognizer.startListening(sessionId: newSessionId)
        client.sendWake()
    }

    public func stopListening() {
        state = .thinking
        speechRecognizer.stopListening()
    }

    public func sendQuery(text: String, voiceSessionId: String? = nil) {
        autoDismissWorkItem?.cancel()
        state = .thinking
        lastResponse = ""
        finalUserInput = text
        rawTranscript = text
        liveTranscript = text
        inputText = text
        errorMessage = nil

        // Voice submissions — both the recognizer path and the audio-file
        // path — are marked as voice so the agent server keeps them out of
        // conversation history. Typed desktop input goes through
        // DesktopStore.send() with source text instead.
        client.sendQuery(text: text, source: .voice, voiceSessionId: voiceSessionId) { [weak self] result in
            switch result {
            case .success(let res):
                self?.lastResponse = res.text
                self?.state = .idle
                if DesktopWindowController.shared.isVisible {
                    DesktopStore.shared.finishVoiceSession(response: res.text, error: res.error)
                }
                self?.scheduleAutoDismiss(delay: 4.0)
            case .failure(let err):
                self?.state = .error
                self?.lastResponse = "Error: \(err.localizedDescription)"
                if DesktopWindowController.shared.isVisible {
                    DesktopStore.shared.finishVoiceSession(response: nil, error: err.localizedDescription)
                }
                self?.scheduleAutoDismiss(delay: 4.5)
            }
        }
    }

    public func resolveConfirmation(id: String, approved: Bool) {
        client.sendConfirmation(id: id, approved: approved)
        pendingConfirmation = nil
        scheduleAutoDismiss(delay: 2.0)
    }

    public func resetConversation() {
        client.sendReset()
        lastResponse = ""
        liveTranscript = ""
        inputText = ""
        errorMessage = nil
        state = .idle
        pendingConfirmation = nil
    }

    /// Cancel the currently running task and return to idle.
    /// Called by the cancel button in the notch UI during thinking/executing states.
    public func cancelCurrentTask() {
        print("[AppState] User cancelled current task")
        speechRecognizer.cancelListening()
        // Send cancel signal to agent server
        client.sendCancel()
        // Briefly show "Cancelled" status before returning to idle
        state = .error
        errorMessage = "Cancelled"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            if self.errorMessage == "Cancelled" {
                self.state = .idle
                self.errorMessage = nil
                self.scheduleAutoDismiss(delay: 3.0)
            }
        }
    }


    public func toggleOverlay() {
        if isVisibleOnScreen {
            hideOverlay()
        } else {
            showOverlay()
        }
    }

    public func showOverlay() {
        autoDismissWorkItem?.cancel()
        hideWorkItem?.cancel()
        hideWorkItem = nil

        repositionOverlayWindow()

        isOverlayVisible = true
        overlayWindow?.makeKeyAndOrderFront(nil)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.76)) {
            isVisibleOnScreen = true
        }
    }

    public func hideOverlay() {
        cancelAutoDismiss()
        hideWorkItem?.cancel()

        withAnimation(.spring(response: 0.35, dampingFraction: 0.76)) {
            isVisibleOnScreen = false
            isOutputExpanded = false
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if !self.isVisibleOnScreen {
                self.isOverlayVisible = false
                self.overlayWindow?.orderOut(nil)
            }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    public func cancelAutoDismiss() {
        autoDismissWorkItem?.cancel()
        autoDismissWorkItem = nil
    }

    public func scheduleAutoDismiss(delay: Double = 5.0) {
        cancelAutoDismiss()
        guard !isOutputExpanded else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard !self.isOutputExpanded else { return }
            // Only auto-dismiss if task completed (idle) or failed (error), never during execution or listening
            if (self.state == .idle || self.state == .error) && self.pendingConfirmation == nil {
                print("[AppState] Auto-dismissing Notch island back into bezel...")
                self.hideOverlay()
            }
        }
        autoDismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
