import SwiftUI

// MARK: - Dynamic Island Shape

/// A capsule shape with flat top edge (merges into the MacBook notch bezel)
/// and rounded bottom corners. This gives the illusion that the notch itself
/// is expanding downward.
struct DynamicIslandShape: Shape {
    var cornerRadius: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Top-left — flush with bezel
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Top edge
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Right edge down to bottom-right arc start
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
        // Bottom-right corner
        path.addArc(
            center: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        // Bottom edge
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        // Bottom-left corner
        path.addArc(
            center: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        // Left edge back to top
        path.closeSubpath()
        return path
    }
}

/// Border shape — identical to DynamicIslandShape but with the top edge open
/// so the border doesn't draw across the bezel line.
struct DynamicIslandBorderShape: Shape {
    var cornerRadius: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Start at top-right
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Right edge
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
        // Bottom-right corner
        path.addArc(
            center: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        // Bottom edge
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        // Bottom-left corner
        path.addArc(
            center: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        // Left edge back to top
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        // Top edge open
        return path
    }
}

// MARK: - Notch Layout Configuration

/// Centralized state-to-layout mapping. Every visual property of the notch
/// is derived from the current `NotchLayoutMode`.
enum NotchLayoutMode: Equatable {
    case compact      // idle / completed — small pill
    case listening    // voice input active
    case expanded     // thinking / executing — wider + taller
    case dropdown     // output expanded — full panel

    var width: CGFloat {
        switch self {
        case .compact:   return 350
        case .listening: return 350
        case .expanded:  return 400
        case .dropdown:  return 420
        }
    }

    var height: CGFloat {
        switch self {
        case .compact:   return 36
        case .listening: return 36
        case .expanded:  return 48
        case .dropdown:  return 48 // content height is additive below
        }
    }

    var cornerRadius: CGFloat {
        // Always pill-shaped: radius ≈ height/2
        return height / 2.0
    }
}

// MARK: - Subtle Activity Pulse

/// A very subtle pulsing overlay used during thinking/executing states
/// to communicate that the agent is actively working.
struct ActivityPulseView: View {
    @State private var isPulsing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.white.opacity(isPulsing ? 0.06 : 0.0),
                        Color.white.opacity(0.0),
                        Color.white.opacity(isPulsing ? 0.04 : 0.0),
                    ]),
                    startPoint: isPulsing ? .leading : .trailing,
                    endPoint: isPulsing ? .trailing : .leading
                )
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}

// MARK: - Cancel Button

struct NotchCancelButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(isHovering ? 1.0 : 0.6))
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(isHovering ? 0.22 : 0.12))
                .clipShape(Circle())
                .scaleEffect(isHovering ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .help("Cancel")
    }
}

// MARK: - Floating Overlay View

public struct FloatingOverlayView: View {
    @ObservedObject public var appState: AppState
    @FocusState private var isInputFocused: Bool
    @State private var hasCopied: Bool = false
    @State private var isHoveringRight: Bool = false

    // Physical notch dimensions
    private var notchHeight: CGFloat {
        appState.notchTopInset > 0 ? appState.notchTopInset : 32.0
    }
    private let physicalNotchWidth: CGFloat = 179.0

    // Determine layout mode from state
    private var layoutMode: NotchLayoutMode {
        if appState.isOutputExpanded && !appState.lastResponse.isEmpty {
            return .dropdown
        }
        switch appState.state {
        case .listening:
            return .listening
        case .thinking, .executing:
            return .expanded
        case .error:
            return .expanded
        default:
            return .compact
        }
    }

    // Whether to show the cancel button
    private var showCancelButton: Bool {
        appState.state == .thinking || appState.state == .executing
    }

    // Whether the notch is in an "active" (non-compact) visual state
    private var isActiveState: Bool {
        appState.state == .listening ||
        appState.state == .thinking ||
        appState.state == .executing ||
        appState.state == .error
    }

    private var promptText: String {
        if appState.state == .listening {
            return appState.liveTranscript
        }
        if !appState.finalUserInput.isEmpty {
            return appState.finalUserInput
        }
        if !appState.liveTranscript.isEmpty {
            return appState.liveTranscript
        }
        return ""
    }

    // Wing width adapts to layout mode
    private var wingWidth: CGFloat {
        return (layoutMode.width - physicalNotchWidth) / 2.0
    }

    // The current bar height (between the notch physical height and the expanded height)
    private var barHeight: CGFloat {
        max(layoutMode.height, notchHeight)
    }

    // Spring animation used for all layout transitions
    private let layoutSpring = Animation.spring(response: 0.4, dampingFraction: 0.82)

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            // The Dynamic Island surface
            VStack(spacing: 0) {
                // Main Horizontal Notch Bar
                notchBar
                    .frame(height: barHeight)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !appState.lastResponse.isEmpty && appState.state == .idle {
                            appState.cancelAutoDismiss()
                            withAnimation(layoutSpring) {
                                appState.isOutputExpanded.toggle()
                            }
                        }
                    }

                // Expanded Output Panel
                if appState.isOutputExpanded && !appState.lastResponse.isEmpty {
                    expandedOutputPanel
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)).animation(.easeOut(duration: 0.25)),
                                removal: .opacity.animation(.easeIn(duration: 0.18))
                            )
                        )
                }
            }
            .frame(width: appState.isVisibleOnScreen ? layoutMode.width : physicalNotchWidth)
            .clipped()
            .background(
                ZStack {
                    DynamicIslandShape(cornerRadius: layoutMode.cornerRadius)
                        .fill(Color.black)

                    // Subtle activity pulse during thinking/executing
                    if appState.state == .thinking || appState.state == .executing {
                        ActivityPulseView()
                            .clipShape(DynamicIslandShape(cornerRadius: layoutMode.cornerRadius))
                            .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                    }
                }
            )
            .overlay(
                DynamicIslandBorderShape(cornerRadius: layoutMode.cornerRadius)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.6)
            )
            .shadow(color: Color.black.opacity(0.5), radius: 12, x: 0, y: 5)
            .animation(layoutSpring, value: layoutMode)
            .animation(layoutSpring, value: appState.isVisibleOnScreen)
            .animation(layoutSpring, value: appState.isOutputExpanded)
            .onHover { hovering in
                if hovering {
                    appState.cancelAutoDismiss()
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .edgesIgnoringSafeArea(.all)
        .onAppear {
            isInputFocused = true
        }
    }

    // MARK: - Notch Bar Content

    private var notchBar: some View {
        HStack(spacing: 0) {
            // Left Wing — status text
            leftWing
                .padding(.leading, 14)
                .frame(width: wingWidth, alignment: .leading)
                .opacity(appState.isVisibleOnScreen ? 1.0 : 0.0)
                .offset(x: appState.isVisibleOnScreen ? 0 : 30)

            // Center Gap (physical webcam notch cutout)
            Color.clear
                .frame(width: physicalNotchWidth, height: notchHeight)

            // Right Wing — controls / wave / spinner
            rightWing
                .padding(.trailing, 14)
                .frame(width: wingWidth, alignment: .trailing)
                .opacity(appState.isVisibleOnScreen ? 1.0 : 0.0)
                .offset(x: appState.isVisibleOnScreen ? 0 : -30)
        }
    }

    // MARK: - Left Wing (Status Label)

    private var leftWing: some View {
        HStack {
            Group {
                switch appState.state {
                case .listening:
                    Text(appState.liveTranscript.isEmpty ? "Listening" : appState.liveTranscript)
                        .font(.system(size: 12.5, weight: .medium, design: .default))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .id("listening-\(appState.liveTranscript.isEmpty)")

                case .thinking:
                    Text("Thinking...")
                        .font(.system(size: 12.5, weight: .medium, design: .default))
                        .foregroundColor(.white.opacity(0.9))
                        .id("thinking")

                case .executing:
                    Text("Executing...")
                        .font(.system(size: 12.5, weight: .medium, design: .default))
                        .foregroundColor(.white.opacity(0.9))
                        .id("executing")

                case .error:
                    Text(appState.errorMessage ?? "Error")
                        .font(.system(size: 11.5, weight: .medium, design: .default))
                        .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.45))
                        .lineLimit(1)
                        .id("error")

                default:
                    if !appState.lastResponse.isEmpty {
                        Text("Siap bos")
                            .font(.system(size: 13, weight: .medium, design: .default))
                            .foregroundColor(.white)
                            .id("siap-bos")
                    } else {
                        Text("Lofly")
                            .font(.system(size: 13, weight: .medium, design: .default))
                            .foregroundColor(.white.opacity(0.7))
                            .id("lofly")
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: appState.state)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Right Wing (Controls)

    private var rightWing: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            Group {
                switch appState.state {
                case .listening:
                    // Pure white audio wave
                    NotchAudioWaveView(
                        audioLevel: appState.audioLevel,
                        isListening: true
                    )
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))

                case .thinking, .executing:
                    // Compact activity indicator + cancel button
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.85)
                            .colorInvert()

                        NotchCancelButton {
                            appState.cancelCurrentTask()
                        }
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))

                case .error:
                    // Error dismiss
                    NotchCancelButton {
                        withAnimation(layoutSpring) {
                            appState.state = .idle
                            appState.errorMessage = nil
                        }
                        appState.scheduleAutoDismiss(delay: 3.0)
                    }
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))

                default:
                    if !appState.lastResponse.isEmpty {
                        // Dropdown toggle button
                        Button(action: {
                            appState.cancelAutoDismiss()
                            withAnimation(layoutSpring) {
                                appState.isOutputExpanded.toggle()
                            }
                        }) {
                            Image(systemName: appState.isOutputExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 24, height: 18)
                                .background(Color.white.opacity(isHoveringRight ? 0.25 : 0.14))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .onHover { h in
                            isHoveringRight = h
                            if h { appState.cancelAutoDismiss() }
                        }
                        .transition(.opacity.animation(.easeOut(duration: 0.2)))
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: appState.state)
        }
    }

    // MARK: - Expanded Output Panel

    private var expandedOutputPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: Output label + Copy + Collapse
            HStack {
                Text("Output")
                    .font(.system(size: 10.5, weight: .semibold, design: .default))
                    .foregroundColor(.white.opacity(0.5))

                Spacer()

                // Copy button
                Button(action: {
                    appState.cancelAutoDismiss()
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(appState.lastResponse, forType: .string)
                    hasCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        hasCopied = false
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                        Text(hasCopied ? "Disalin" : "Salin")
                            .font(.system(size: 9.5, weight: .medium))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(5)
                    .foregroundColor(hasCopied ? .green : .white.opacity(0.8))
                }
                .buttonStyle(.plain)

                // Collapse button
                Button(action: {
                    withAnimation(layoutSpring) {
                        appState.isOutputExpanded = false
                    }
                    appState.scheduleAutoDismiss(delay: 4.0)
                }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(5)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            // Prompt echo
            if !promptText.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if !appState.rawTranscript.isEmpty && !appState.normalizedTranscript.isEmpty && appState.rawTranscript != appState.normalizedTranscript {
                        Text("Raw: \(appState.rawTranscript)")
                            .font(.system(size: 9.5, weight: .regular))
                            .foregroundColor(.white.opacity(0.35))
                            .lineLimit(1)
                    }
                    Text("Prompt: \(promptText)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(2)
                }
            }

            // Response body
            ScrollView(.vertical, showsIndicators: true) {
                Text(appState.lastResponse)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundColor(.white.opacity(0.95))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineSpacing(3)
            }
            .frame(maxHeight: 160)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(Color.white.opacity(0.06))
        .cornerRadius(10)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}
