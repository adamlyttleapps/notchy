import SwiftUI
import AppKit

/// A transparent view that initiates window dragging on mouseDown
/// and triggers a callback on double-click.
/// Place this behind interactive controls so it only catches clicks on empty space.
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
    @State private var showRestoreConfirmation = false

    private var foregroundOpacity: Double {
        sessionStore.isWindowFocused ? 1.0 : 0.6
    }

    /// When expanded + unfocused, make chrome backgrounds semi-transparent
    /// so the user can see through to things like Xcode build status.
    private var chromeBackgroundOpacity: Double {
        (!sessionStore.isWindowFocused && sessionStore.isTerminalExpanded) ? 0.5 : 1.0
    }

    var body: some View {
        VStack(spacing: 0) {
            // Black top border — separate element so it pushes content down
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

                ZStack {
                    Button(action: { sessionStore.createQuickSession() }) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(foregroundOpacity))
                    .help("New session")
                }
                .padding(.leading, -4)
                .padding(.trailing, -10)
            }
            .padding(.horizontal, 12)
            .background(Color(nsColor: NSColor(white: 0.14, alpha: 1.0)).opacity(chromeBackgroundOpacity))

            if sessionStore.isTerminalExpanded, sessionStore.checkpointStatus != nil || sessionStore.lastCheckpoint != nil {
                HStack(spacing: 6) {
                    if let status = sessionStore.checkpointStatus {
                        Image(systemName: "progress.indicator")
                            .font(.system(size: 10, weight: .semibold))
                        Text(status)
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Button {
                            showRestoreConfirmation = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "clock.arrow.circlepath")
                                Text("Restore last checkpoint")
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(nsColor: NSColor(white: 0.18, alpha: 1.0)))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .padding(.trailing, 6)
                        .opacity(0)
                        
                    } else if let checkpoint = sessionStore.lastCheckpoint {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Checkpoint Saved")
                            .font(.system(size: 11, weight: .medium))
                        Text(checkpoint.displayName)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))

                        Spacer()

                        Button {
                            showRestoreConfirmation = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "clock.arrow.circlepath")
                                Text("Restore last checkpoint")
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(nsColor: NSColor(white: 0.18, alpha: 1.0)))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .padding(.trailing, 6)

                        Button(action: { sessionStore.lastCheckpoint = nil }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.white.opacity(0.4))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(nsColor: NSColor(white: 0.18, alpha: 1.0)).opacity(chromeBackgroundOpacity))
                .foregroundColor(.white.opacity(0.8))
            }

            if sessionStore.isTerminalExpanded {
                Divider()

                // Terminal area
                if let session = sessionStore.activeSession {
                    if session.hasStarted {
                        SplitPaneView(
                            node: session.splitRoot,
                            launchClaude: session.projectPath != nil,
                            generation: session.generation,
                            sessionStore: sessionStore
                        )
                    } else if session.projectPath != nil && !sessionStore.activeXcodeProjects.contains(session.projectName) {
                        // Xcode closed for this project
                        placeholderView("Xcode project not open")
                            .overlay {
                                if let projectPath = session.projectPath {
                                    Button("Open in Xcode") {
                                        NSWorkspace.shared.open(URL(fileURLWithPath: projectPath))
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .padding(.top, 28)
                                }
                            }
                    } else {
                        placeholderView("Click a project tab to start a terminal session")
                            .onTapGesture {
                                sessionStore.startSessionIfNeeded(session.id)
                            }
                    }
                } else if sessionStore.sessions.isEmpty {
                    placeholderView("No Xcode projects detected.\nClick + to create a new session.")
                } else {
                    placeholderView("Select a project to begin")
                }
            }
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8.5, bottomLeadingRadius: 9.5, bottomTrailingRadius: 9.5, topTrailingRadius: 8.5))
        .background(Color(nsColor: NSColor(white: 0.1, alpha: 1.0)).opacity(chromeBackgroundOpacity))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8.5, bottomLeadingRadius: 9.5, bottomTrailingRadius: 9.5, topTrailingRadius: 8.5))
        .onAppear {
            sessionStore.refreshLastCheckpoint()
        }
        .onChange(of: sessionStore.hasCompletedInitialDetection) {
            if sessionStore.hasCompletedInitialDetection && sessionStore.sessions.isEmpty {
                sessionStore.createQuickSession()
            }
        }
        .onChange(of: sessionStore.activeSessionId) {
            sessionStore.refreshLastCheckpoint()
        }
        .onChange(of: showRestoreConfirmation) {
            sessionStore.isShowingDialog = showRestoreConfirmation
        }
        .alert("Restore last checkpoint", isPresented: $showRestoreConfirmation) {
            Button("Restore last checkpoint", role: .destructive) {
                sessionStore.restoreLastCheckpoint()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will overwrite your current working directory with the checkpoint. Are you sure?")
        }
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
            .overlay {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .opacity(0)
            }
    }
}
