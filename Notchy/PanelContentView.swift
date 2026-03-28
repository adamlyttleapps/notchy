import SwiftUI
import AppKit

/// A transparent view that initiates window dragging on mouseDown
/// and triggers a callback on double-click.
struct WindowDragArea: NSViewRepresentable {
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> DragAreaView {
        let view = DragAreaView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: DragAreaView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }

    class DragAreaView: NSView {
        var onDoubleClick: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onDoubleClick?()
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}

struct PanelContentView: View {
    @Bindable var sessionStore: SessionStore
    var onClose: () -> Void
    var onToggleExpand: (() -> Void)?

    private var foregroundOpacity: Double {
        sessionStore.isWindowFocused ? 1.0 : 0.6
    }

    private var chromeBackgroundOpacity: Double {
        (!sessionStore.isWindowFocused && sessionStore.isTerminalExpanded) ? 0.5 : 1.0
    }

    var body: some View {
        VStack(spacing: 0) {
            // Black top border
            Rectangle()
                .fill(Color.black)
                .frame(height: 10)

            // Top bar: tabs + controls
            HStack(spacing: 8) {
                ZStack {
                    Button(action: { sessionStore.isPinned.toggle() }) {
                        Image(systemName: sessionStore.isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 12, weight: .medium))
                            .rotationEffect(.degrees(sessionStore.isPinned ? 0 : 45))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(foregroundOpacity))
                    .help(sessionStore.isPinned ? "Unpin panel" : "Pin panel open")
                }
                .padding(.trailing, -4)
                .padding(.leading, -10)

                Rectangle()
                    .foregroundColor(.clear)
                    .frame(height: 12)
                    .overlay(
                        WindowDragArea(onDoubleClick: {
                            sessionStore.isTerminalExpanded.toggle()
                            onToggleExpand?()
                        })
                        .frame(height: 200)
                    )

                SessionTabBar(sessionStore: sessionStore)

                Rectangle()
                    .foregroundColor(.clear)
                    .frame(height: 12)
                    .overlay(
                        WindowDragArea(onDoubleClick: {
                            sessionStore.isTerminalExpanded.toggle()
                            onToggleExpand?()
                        })
                        .frame(height: 200)
                    )
            }
            .padding(.horizontal, 12)
            .background(Color(nsColor: NSColor(white: 0.14, alpha: 1.0)).opacity(chromeBackgroundOpacity))

            if sessionStore.isTerminalExpanded {
                Divider()

                // Session detail area
                if let session = sessionStore.activeSession {
                    SessionDetailView(session: session)
                        .onTapGesture {
                            sessionStore.focusSession(session.id)
                        }
                } else if sessionStore.sessions.isEmpty {
                    placeholderView("No Claude Code sessions detected.\nRun claude in any iTerm2 tab.")
                } else {
                    placeholderView("Select a session")
                }
            }
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8.5, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 8.5))
        .background(Color(nsColor: NSColor(white: 0.1, alpha: 1.0)).opacity(chromeBackgroundOpacity))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8.5, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 8.5))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if notification.object is TerminalPanel {
                sessionStore.isWindowFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if notification.object is TerminalPanel {
                sessionStore.isWindowFocused = false
            }
        }
    }

    private func placeholderView(_ message: String) -> some View {
        Color(nsColor: NSColor(white: 0.1, alpha: 1.0))
            .frame(minHeight: 80)
            .overlay {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
    }
}

// MARK: - Session Detail View

struct SessionDetailView: View {
    let session: TerminalSession

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.sessionName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundColor(statusColor.opacity(0.9))
                }
                Spacer()
                Text("Click to focus in iTerm2")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: NSColor(white: 0.1, alpha: 1.0)))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch session.terminalStatus {
        case .working:
            DetailSpinnerView()
                .frame(width: 18, height: 18)
        case .waitingForInput:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundColor(.yellow)
        case .taskCompleted:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(.green)
        case .interrupted:
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(.orange)
        case .idle:
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundColor(.gray.opacity(0.5))
                .frame(width: 18, height: 18)
        }
    }

    private var statusText: String {
        switch session.terminalStatus {
        case .working: return "Working..."
        case .waitingForInput: return "Waiting for input"
        case .taskCompleted: return "Task completed"
        case .interrupted: return "Interrupted"
        case .idle: return "Idle"
        }
    }

    private var statusColor: Color {
        switch session.terminalStatus {
        case .working: return .white
        case .waitingForInput: return .yellow
        case .taskCompleted: return .green
        case .interrupted: return .orange
        case .idle: return .gray
        }
    }
}

struct DetailSpinnerView: View {
    @State private var isAnimating = false

    var body: some View {
        Circle()
            .trim(from: 0.05, to: 0.8)
            .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: isAnimating)
            .onAppear { isAnimating = true }
    }
}
