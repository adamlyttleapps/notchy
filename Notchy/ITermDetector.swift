import AppKit
import Foundation

struct ClaudeSession: Equatable {
    let pid: Int32
    let tty: String
    let itermSessionId: String
    let sessionName: String
    var contents: String

    static func == (lhs: ClaudeSession, rhs: ClaudeSession) -> Bool {
        lhs.pid == rhs.pid && lhs.tty == rhs.tty
    }
}

nonisolated class ITermDetector {
    static let shared = ITermDetector()

    // MARK: - Shell helpers

    /// Runs a command with args using posix_spawn (thread-safe, no Foundation Process)
    private func spawn(_ executable: String, args: [String]) -> String? {
        var readFD: Int32 = 0
        var writeFD: Int32 = 0

        // Create pipe for stdout
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        readFD = fds[0]
        writeFD = fds[1]

        // Set up file actions: redirect stdout to pipe
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, writeFD, STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, readFD)
        // Redirect stderr to /dev/null
        posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + args).map { strdup($0) } + [nil]
        defer { for arg in argv { if let arg { free(arg) } } }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &fileActions, nil, argv, environ)
        posix_spawn_file_actions_destroy(&fileActions)
        close(writeFD)

        guard status == 0 else {
            close(readFD)
            return nil
        }

        // Read all output
        var output = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while true {
            let n = read(readFD, buf, bufSize)
            if n <= 0 { break }
            output.append(buf, count: n)
        }
        close(readFD)

        var exitStatus: Int32 = 0
        waitpid(pid, &exitStatus, 0)

        return String(data: output, encoding: .utf8)
    }

    /// Runs osascript and returns stdout, or nil on failure.
    private func runAppleScript(_ script: String) -> String? {
        guard let result = spawn("/usr/bin/osascript", args: ["-e", script]) else { return nil }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Finds all running `claude` processes and their TTYs via `ps`
    private func findClaudeProcesses() -> [(pid: Int32, tty: String)] {
        guard let output = spawn("/bin/ps", args: ["-eo", "pid,tty,comm"]) else { return [] }

        var results: [(pid: Int32, tty: String)] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix("/claude") || trimmed.hasSuffix(" claude") else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = Int32(parts[0]) else { continue }
            let tty = String(parts[1])
            guard tty != "??" else { continue }
            results.append((pid: pid, tty: tty))
        }
        return results
    }

    private func isITermRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.googlecode.iterm2"
        }
    }

    /// Queries iTerm2 for all sessions, maps by TTY, reads contents for matching ones.
    /// When `skipITermCheck` is true, caller has already verified iTerm2 is running.
    func detectClaudeSessions(skipITermCheck: Bool = false) -> [ClaudeSession] {
        let claudeProcesses = findClaudeProcesses()
        guard !claudeProcesses.isEmpty else { return [] }
        if !skipITermCheck {
            guard isITermRunning() else { return [] }
        }

        let ttySet = Set(claudeProcesses.map { tty -> String in
            tty.tty.hasPrefix("/dev/") ? tty.tty : "/dev/\(tty.tty)"
        })
        let pidByTty = Dictionary(claudeProcesses.map { (key: $0.tty.hasPrefix("/dev/") ? $0.tty : "/dev/\($0.tty)", value: $0.pid) },
                                   uniquingKeysWith: { first, _ in first })


        let script = """
        tell application "iTerm2"
            set output to ""
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set sessionTTY to tty of s
                        set sessionId to unique ID of s
                        set sessionName to name of s
                        set output to output & sessionId & "|||" & sessionTTY & "|||" & sessionName & ":::"
                    end repeat
                end repeat
            end repeat
            return output
        end tell
        """

        guard let resultString = runAppleScript(script), !resultString.isEmpty else {
            return []
        }

        var matchedSessions: [(id: String, tty: String, name: String, pid: Int32)] = []
        let entries = resultString.components(separatedBy: ":::")
        for entry in entries where !entry.isEmpty {
            let parts = entry.components(separatedBy: "|||")
            guard parts.count == 3 else { continue }
            let sessionId = parts[0]
            let sessionTTY = parts[1]
            let sessionName = parts[2]

            if ttySet.contains(sessionTTY), let pid = pidByTty[sessionTTY] {
                matchedSessions.append((id: sessionId, tty: sessionTTY, name: sessionName, pid: pid))
            }
        }

        guard !matchedSessions.isEmpty else { return [] }

        // Read contents for each matched session
        var claudeSessions: [ClaudeSession] = []
        for session in matchedSessions {
            let contents = readSessionContents(sessionId: session.id) ?? ""
            claudeSessions.append(ClaudeSession(
                pid: session.pid,
                tty: session.tty,
                itermSessionId: session.id,
                sessionName: session.name,
                contents: contents
            ))
        }

        return claudeSessions
    }

    /// Reads the visible contents of a specific iTerm2 session
    private func readSessionContents(sessionId: String) -> String? {
        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if unique ID of s is "\(sessionId)" then
                            return contents of s
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
        return runAppleScript(script)
    }

    /// Activates (focuses) a specific iTerm2 session
    func activateSession(sessionId: String) {
        let script = """
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if unique ID of s is "\(sessionId)" then
                            select t
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
        _ = runAppleScript(script)
    }

    // MARK: - Status Detection

    private static let spinnerCharacters: Set<Character> = ["·", "✢", "✳", "✶", "✻", "✽"]

    static func classifyStatus(from contents: String) -> TerminalStatus {
        let lines = contents.components(separatedBy: "\n")
        let nonBlankLines = lines.filter { !$0.allSatisfy({ $0 == " " || $0 == "\0" }) }
        let lastLines = nonBlankLines.suffix(30)

        let separator = "────────"
        let visibleText: String
        if let lastSepIndex = lastLines.lastIndex(where: { $0.contains(separator) }) {
            visibleText = lastLines.prefix(upTo: lastSepIndex).joined(separator: "\n")
        } else {
            visibleText = lastLines.joined(separator: "\n")
        }
        let fullText = lastLines.joined(separator: "\n")

        if hasTokenCounterLine(visibleText) || fullText.contains("esc to interrupt") {
            return .working
        } else if fullText.contains("Esc to cancel") || hasUserPrompt(fullText) {
            return .waitingForInput
        } else if visibleText.contains("Interrupted") {
            return .interrupted
        } else {
            return .idle
        }
    }

    private static func hasUserPrompt(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.contains { line in
            let trimmed = line.drop(while: { $0 == " " })
            return trimmed.hasPrefix("❯") &&
                trimmed.dropFirst().first == " " &&
                trimmed.dropFirst(2).first?.isNumber == true
        }
    }

    private static func hasTokenCounterLine(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.contains { line in
            guard let first = line.first, spinnerCharacters.contains(first) else { return false }
            guard line.dropFirst().first == " " else { return false }
            return line.contains("…")
        }
    }
}
