import SwiftUI

struct PaneControlsView: View {
    let paneId: UUID
    @Bindable var sessionStore: SessionStore
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 2) {
            controlButton(icon: "square.split.2x1", help: "Split Right (⌘D)") {
                sessionStore.splitFocusedPane(direction: .horizontal)
            }
            controlButton(icon: "square.split.1x2", help: "Split Down (⇧⌘D)") {
                sessionStore.splitFocusedPane(direction: .vertical)
            }
            controlButton(icon: "xmark", help: "Close Pane (⇧⌘W)") {
                sessionStore.closeFocusedPane()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial.opacity(isHovering ? 1 : 0.7))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(isHovering ? 1 : 0.4)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    private func controlButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.white)
        .help(help)
    }
}

struct SplitPaneView: View {
    let node: SplitNode
    let launchClaude: Bool
    let generation: Int
    @Bindable var sessionStore: SessionStore

    private var focusedPaneId: UUID? {
        sessionStore.activeSession?.focusedPaneId
    }

    private var hasMultiplePanes: Bool {
        (sessionStore.activeSession?.splitRoot.allPaneIds.count ?? 0) > 1
    }

    var body: some View {
        switch node {
        case .pane(let paneId, let workingDirectory):
            TerminalSessionView(
                sessionId: paneId,
                workingDirectory: workingDirectory,
                launchClaude: launchClaude,
                generation: generation
            )
            .overlay(alignment: .topTrailing) {
                if focusedPaneId == paneId {
                    PaneControlsView(paneId: paneId, sessionStore: sessionStore)
                        .padding(6)
                }
            }
            .overlay {
                if hasMultiplePanes && focusedPaneId == paneId {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }

        case .split(_, let direction, let first, let second, _):
            if direction == .horizontal {
                HStack(spacing: 0) {
                    SplitPaneView(node: first, launchClaude: launchClaude, generation: generation, sessionStore: sessionStore)
                        .frame(maxWidth: .infinity)
                    Rectangle()
                        .fill(Color(white: 0.25))
                        .frame(width: 1)
                    SplitPaneView(node: second, launchClaude: launchClaude, generation: generation, sessionStore: sessionStore)
                        .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    SplitPaneView(node: first, launchClaude: launchClaude, generation: generation, sessionStore: sessionStore)
                        .frame(maxHeight: .infinity)
                    Rectangle()
                        .fill(Color(white: 0.25))
                        .frame(height: 1)
                    SplitPaneView(node: second, launchClaude: launchClaude, generation: generation, sessionStore: sessionStore)
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }
}
