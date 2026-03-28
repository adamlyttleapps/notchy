import AppKit
import AVFoundation
import SwiftUI

extension Notification.Name {
    static let NotchyHidePanel = Notification.Name("NotchyHidePanel")
    static let NotchyExpandPanel = Notification.Name("NotchyExpandPanel")
    static let NotchyNotchStatusChanged = Notification.Name("NotchyNotchStatusChanged")
}

@Observable
class SessionStore {
    static let shared = SessionStore()

    var sessions: [TerminalSession] = []
    var activeSessionId: UUID?
    var isPinned: Bool = {
        if UserDefaults.standard.object(forKey: "isPinned") == nil { return true }
        return UserDefaults.standard.bool(forKey: "isPinned")
    }() {
        didSet {
            UserDefaults.standard.set(isPinned, forKey: "isPinned")
        }
    }
    var isTerminalExpanded = true
    var isWindowFocused = true
    var isShowingDialog = false

    /// Activity token to prevent macOS idle sleep while Claude is working
    private var sleepActivity: NSObjectProtocol?

    /// Sound playback
    private var audioPlayer: AVAudioPlayer?
    private var lastSoundPlayedAt: Date = .distantPast

    /// Timer that periodically polls for Claude sessions in iTerm2
    private var pollingTimer: Timer?
    private static let pollingInterval: TimeInterval = 1.5

    var activeSession: TerminalSession? {
        sessions.first { $0.id == activeSessionId }
    }

    init() {
        // Defer timer setup to next run loop iteration
        DispatchQueue.main.async { [weak self] in
            self?.startPolling()
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: Self.pollingInterval, repeats: true) { [weak self] _ in
            self?.pollITermSessions()
        }
        pollITermSessions()
    }

    private var isPolling = false

    private func pollITermSessions() {
        guard !isPolling else { return }
        // Check iTerm2 running status on main thread (NSWorkspace requires main thread)
        let itermRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.googlecode.iterm2"
        }
        guard itermRunning else { return }

        isPolling = true
        Thread.detachNewThread { [weak self] in
            let detected = ITermDetector.shared.detectClaudeSessions(skipITermCheck: true)
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyDetectedSessions(detected)
                self.isPolling = false
            }
        }
    }

    private func applyDetectedSessions(_ detected: [ClaudeSession]) {
        let detectedTTYs = Set(detected.map(\.tty))

        // Remove sessions whose claude process is gone
        let removedIds = sessions.filter { !detectedTTYs.contains($0.tty) }.map(\.id)
        sessions.removeAll { removedIds.contains($0.id) }
        if let activeId = activeSessionId, removedIds.contains(activeId) {
            activeSessionId = sessions.first?.id
        }

        // Update existing sessions and add new ones
        for claudeSession in detected {
            if let index = sessions.firstIndex(where: { $0.tty == claudeSession.tty }) {
                // Update name if it changed
                sessions[index].sessionName = claudeSession.sessionName
                sessions[index].itermSessionId = claudeSession.itermSessionId

                // Classify status from contents
                let newStatus = ITermDetector.classifyStatus(from: claudeSession.contents)
                updateTerminalStatus(sessions[index].id, status: newStatus)
            } else {
                // New Claude session detected
                var session = TerminalSession(claudeSession: claudeSession)
                let newStatus = ITermDetector.classifyStatus(from: claudeSession.contents)
                session.terminalStatus = newStatus
                sessions.append(session)

                // Auto-select if it's the only session
                if sessions.count == 1 {
                    activeSessionId = session.id
                }
            }
        }
    }

    // MARK: - Session Actions

    func selectSession(_ id: UUID) {
        activeSessionId = id
    }

    func focusSession(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        ITermDetector.shared.activateSession(sessionId: session.itermSessionId)
    }

    // MARK: - Status Management

    func updateTerminalStatus(_ id: UUID, status: TerminalStatus) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions[index].terminalStatus != status {
            let previous = sessions[index].terminalStatus
            sessions[index].terminalStatus = status
            updateSleepPrevention()

            if status == .working && previous != .working {
                sessions[index].workingStartedAt = Date()
            }
            if status == .waitingForInput && previous != .waitingForInput {
                playSound(named: "waitingForInput")
            }
            else if status == .taskCompleted && previous != .taskCompleted {
                playSound(named: "taskCompleted")
            }
            else if status == .idle && previous == .working {
                // Delay 3s before treating as "task completed"
                let workingStartedAt = sessions[index].workingStartedAt
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    guard let idx = self.sessions.firstIndex(where: { $0.id == id }),
                          self.sessions[idx].terminalStatus == .idle else { return }
                    // Only trigger taskCompleted for tasks that ran >10s
                    if let started = workingStartedAt, Date().timeIntervalSince(started) < 10 {
                        return
                    }
                    SessionStore.shared.updateTerminalStatus(id, status: .taskCompleted)
                    // Auto-clear taskCompleted after 3 seconds
                    try? await Task.sleep(for: .seconds(3))
                    guard let idx2 = self.sessions.firstIndex(where: { $0.id == id }),
                          self.sessions[idx2].terminalStatus == .taskCompleted else { return }
                    self.sessions[idx2].terminalStatus = .idle
                    NotificationCenter.default.post(name: .NotchyNotchStatusChanged, object: nil)
                }
            }
        }
    }

    private func playSound(named name: String) {
        let now = Date()
        guard now.timeIntervalSince(lastSoundPlayedAt) >= 1.0 else { return }
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else { return }
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.play()
            lastSoundPlayedAt = now
        } catch {}
    }

    private func updateSleepPrevention() {
        let anyWorking = sessions.contains { $0.terminalStatus == .working }
        if anyWorking && sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                reason: "Claude is working"
            )
        } else if !anyWorking, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }
}
