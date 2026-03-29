import SwiftUI

struct TabFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct SessionTabBar: View {
    @Bindable var sessionStore: SessionStore
    @State private var draggingSessionId: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var tabFrames: [UUID: CGRect] = [:]
    @State private var dragAccumulatedShift: CGFloat = 0
    @State private var lastSwapDate: Date = .distantPast

    var body: some View {
        HStack(spacing: 2) {
            ForEach(sessionStore.sessions) { session in
                let index = sessionStore.sessions.firstIndex(where: { $0.id == session.id })
                SessionTab(
                    session: session,
                    isActive: session.id == sessionStore.activeSessionId,
                    terminalActive: session.hasStarted && sessionStore.activeXcodeProjects.contains(session.projectName),
                    terminalStatus: session.terminalStatus,
                    foregroundOpacity: sessionStore.isWindowFocused ? 1.0 : 0.6,
                    canMoveLeft: (index ?? 0) > 0,
                    canMoveRight: (index ?? 0) < sessionStore.sessions.count - 1,
                    onSelect: {
                        if draggingSessionId == nil {
                            sessionStore.selectSession(session.id)
                        }
                    },
                    onClose: { sessionStore.closeSession(session.id) },
                    onRename: { newName in
                        sessionStore.renameSession(session.id, to: newName)
                    },
                    onMoveLeft: { sessionStore.moveSessionLeft(session.id) },
                    onMoveRight: { sessionStore.moveSessionRight(session.id) }
                )
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: TabFramePreferenceKey.self,
                            value: [session.id: geo.frame(in: .named("tabBar"))]
                        )
                    }
                )
                .offset(x: draggingSessionId == session.id ? dragOffset - dragAccumulatedShift : 0)
                .zIndex(draggingSessionId == session.id ? 1 : 0)
                .opacity(draggingSessionId == session.id ? 0.8 : 1.0)
                .scaleEffect(draggingSessionId == session.id ? 1.05 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: draggingSessionId)
                .gesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named("tabBar"))
                        .onChanged { value in
                            if draggingSessionId == nil {
                                draggingSessionId = session.id
                                dragAccumulatedShift = 0
                            }
                            dragOffset = value.translation.width

                            // Cooldown: skip if last swap was < 250ms ago
                            guard Date().timeIntervalSince(lastSwapDate) > 0.25 else { return }
                            guard let currentIndex = sessionStore.sessions.firstIndex(where: { $0.id == session.id }) else { return }

                            let visualOffset = dragOffset - dragAccumulatedShift

                            // Only check immediate neighbors
                            if visualOffset > 0, currentIndex < sessionStore.sessions.count - 1 {
                                let rightNeighbor = sessionStore.sessions[currentIndex + 1]
                                if let neighborFrame = tabFrames[rightNeighbor.id],
                                   visualOffset > neighborFrame.width * 0.5 {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        sessionStore.sessions.swapAt(currentIndex, currentIndex + 1)
                                    }
                                    dragAccumulatedShift += neighborFrame.width + 2
                                    lastSwapDate = Date()
                                }
                            } else if visualOffset < 0, currentIndex > 0 {
                                let leftNeighbor = sessionStore.sessions[currentIndex - 1]
                                if let neighborFrame = tabFrames[leftNeighbor.id],
                                   -visualOffset > neighborFrame.width * 0.5 {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        sessionStore.sessions.swapAt(currentIndex, currentIndex - 1)
                                    }
                                    dragAccumulatedShift -= neighborFrame.width + 2
                                    lastSwapDate = Date()
                                }
                            }
                        }
                        .onEnded { _ in
                            withAnimation(.easeOut(duration: 0.15)) {
                                dragOffset = 0
                                dragAccumulatedShift = 0
                            }
                            draggingSessionId = nil
                            sessionStore.saveSessions()
                        }
                )
            }
        }
        .coordinateSpace(name: "tabBar")
        .onPreferenceChange(TabFramePreferenceKey.self) { frames in
            tabFrames = frames
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct SessionTab: View {
    let session: TerminalSession
    let isActive: Bool
    let terminalActive: Bool
    var terminalStatus: TerminalStatus = .idle
    var foregroundOpacity: Double = 1.0
    var canMoveLeft: Bool = false
    var canMoveRight: Bool = false
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void
    var onMoveLeft: (() -> Void)?
    var onMoveRight: (() -> Void)?

    @State private var isHovering = false
    @State private var showRenameDialog = false
    @State private var renameText = ""
    @State private var latestCheckpoint: Checkpoint?
    @State private var showRestoreConfirmation = false

    private var name: String { session.projectName }

    private func refreshLatestCheckpoint() {
        guard let dir = session.projectPath else { return }
        let projectDir = (dir as NSString).deletingLastPathComponent
        latestCheckpoint = CheckpointManager.shared.checkpoints(for: session.projectName, in: projectDir).first
    }

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
                // Hidden semibold text prevents tab width change on selection
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
            if session.projectPath != nil {
                Button("Save Checkpoint") {
                    SessionStore.shared.createCheckpoint(for: session.id)
                }

                if latestCheckpoint != nil {
                    Button("Restore Last Checkpoint") {
                        showRestoreConfirmation = true
                    }
                }

                Divider()
            }

            Button("Restart") {
                SessionStore.shared.restartSession(session.id)
            }

            if canMoveLeft {
                Button("Move Left") {
                    onMoveLeft?()
                }
            }
            if canMoveRight {
                Button("Move Right") {
                    onMoveRight?()
                }
            }

            Divider()

            Button("Rename Tab") {
                renameText = name
                showRenameDialog = true
            }

            Button("Close", role: .destructive) {
                onClose()
            }
        }
        .onAppear {
            refreshLatestCheckpoint()
        }
        .onChange(of: isHovering) {
            if isHovering {
                refreshLatestCheckpoint()
            }
        }
        .alert("Restore Last Checkpoint", isPresented: $showRestoreConfirmation) {
            Button("Restore", role: .destructive) {
                if let checkpoint = latestCheckpoint {
                    guard let dir = session.projectPath else { return }
                    let projectDir = (dir as NSString).deletingLastPathComponent
                    try? CheckpointManager.shared.restoreCheckpoint(checkpoint, to: projectDir)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will overwrite your current working directory with the checkpoint. Are you sure?")
        }
        .alert("Rename Tab", isPresented: $showRenameDialog) {
            TextField("Tab name", text: $renameText)
            Button("Rename") {
                if !renameText.isEmpty {
                    onRename(renameText)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: showRenameDialog) {
            SessionStore.shared.isShowingDialog = showRenameDialog || showRestoreConfirmation
        }
        .onChange(of: showRestoreConfirmation) {
            SessionStore.shared.isShowingDialog = showRenameDialog || showRestoreConfirmation
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

