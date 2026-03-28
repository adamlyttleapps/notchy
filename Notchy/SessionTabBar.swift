import SwiftUI

struct SessionTabBar: View {
    @Bindable var sessionStore: SessionStore

    var body: some View {
        HStack(spacing: 2) {
            ForEach(sessionStore.sessions) { session in
                SessionTab(
                    session: session,
                    isActive: session.id == sessionStore.activeSessionId,
                    terminalStatus: session.terminalStatus,
                    foregroundOpacity: sessionStore.isWindowFocused ? 1.0 : 0.6,
                    onSelect: { sessionStore.selectSession(session.id) },
                    onFocus: { sessionStore.focusSession(session.id) }
                )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct SessionTab: View {
    let session: TerminalSession
    let isActive: Bool
    var terminalStatus: TerminalStatus = .idle
    var foregroundOpacity: Double = 1.0
    let onSelect: () -> Void
    let onFocus: () -> Void

    @State private var isHovering = false

    private var name: String { session.sessionName }

    @ViewBuilder
    private var statusIndicator: some View {
        switch terminalStatus {
        case .working:
            TabSpinnerView()
                .frame(width: 8, height: 8)
        case .waitingForInput:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.yellow)
        case .taskCompleted:
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.green)
        case .idle, .interrupted:
            Circle()
                .fill(Color.gray.opacity(0.4))
                .frame(width: 6, height: 6)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            statusIndicator

            ZStack {
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .opacity(0)

                Text(name)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundColor(.white.opacity(foregroundOpacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive
                    ? Color.accentColor.opacity(0.15)
                    : isHovering ? Color.white.opacity(0.05) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.arrow.push()
            } else {
                NSCursor.pop()
            }
        }
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Focus in iTerm2") {
                onFocus()
            }
        }
    }
}

struct TabSpinnerView: View {
    @State private var isAnimating = false

    var body: some View {
        Circle()
            .trim(from: 0.05, to: 0.8)
            .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: isAnimating)
            .onAppear { isAnimating = true }
    }
}
