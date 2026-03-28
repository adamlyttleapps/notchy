import Foundation

enum TerminalStatus: Equatable {
    /// Default — no special activity detected
    case idle
    /// Claude is working (status line matches token counter pattern)
    case working
    /// Claude is waiting for user input ("Esc to cancel")
    case waitingForInput
    /// Claude was interrupted by the user (Esc pressed)
    case interrupted
    /// Claude finished a task (confirmed via idle timer after working)
    case taskCompleted
}

struct TerminalSession: Identifiable {
    let id: UUID
    var sessionName: String
    var tty: String
    var itermSessionId: String
    var pid: Int32
    var terminalStatus: TerminalStatus
    /// When the session most recently entered the .working state
    var workingStartedAt: Date?

    init(claudeSession: ClaudeSession) {
        self.id = UUID()
        self.sessionName = claudeSession.sessionName
        self.tty = claudeSession.tty
        self.itermSessionId = claudeSession.itermSessionId
        self.pid = claudeSession.pid
        self.terminalStatus = .idle
    }
}
