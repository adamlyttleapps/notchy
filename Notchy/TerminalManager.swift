import AppKit
import SwiftTerm

class ClickThroughTerminalView: LocalProcessTerminalView {
    var sessionId: UUID?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var statusDebounceTimer: Timer?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        installArrowKeyMonitor()
        installClickMonitor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
        installArrowKeyMonitor()
        installClickMonitor()
    }

    deinit {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func installClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let id = self.sessionId,
                  let eventWindow = event.window,
                  eventWindow === self.window else { return event }
            let locationInView = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(locationInView) {
                DispatchQueue.main.async {
                    SessionStore.shared.focusPane(id)
                }
            }
            return event
        }
    }

    /// Intercept arrow key events locally and send standard VT100/xterm sequences
    /// to avoid kitty keyboard protocol (CSI u) encoding issues.
    private func installArrowKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.window?.firstResponder === self else { return event }

            // Shift+Enter → send newline sequence for Claude Code multiline input
            if event.keyCode == 36 && event.modifierFlags.contains(.shift) {
                self.send(txt: "\u{1b}[13;2u")
                return nil
            }

            let arrowCode: String?
            switch event.keyCode {
            case 126: arrowCode = "A" // Up
            case 125: arrowCode = "B" // Down
            case 124: arrowCode = "C" // Right
            case 123: arrowCode = "D" // Left
            default: arrowCode = nil
            }

            guard let code = arrowCode else { return event }

            let mods = event.modifierFlags.intersection([.shift, .option, .control])
            if mods.isEmpty {
                self.send(txt: "\u{1b}[\(code)")
            } else {
                var modifier = 1
                if mods.contains(.shift) { modifier += 1 }
                if mods.contains(.option) { modifier += 2 }
                if mods.contains(.control) { modifier += 4 }
                self.send(txt: "\u{1b}[1;\(modifier)\(code)")
            }
            return nil // consume the event
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return false
        }
        let paths = items.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        send(txt: paths)
        return true
    }

    /// Returns all visible lines from the terminal buffer.
    private func extractAllLines() -> [String]? {
        let terminal = getTerminal()
        guard terminal.rows >= 20 else { return nil }
        var lineTexts: [String] = []
        for row in 0..<terminal.rows {
            var line = ""
            for col in 0..<terminal.cols {
                let ch = terminal.getCharacter(col: col, row: row) ?? " "
                line.append(ch == "\u{0}" ? " " : ch)
            }
            lineTexts.append(line)
        }
        return lineTexts
    }

    /// Returns the last 20 non-blank lines from the given lines, joined by newlines.
    private func relevantText(from lines: [String]) -> String {
        let nonBlankLines = lines.filter { !$0.allSatisfy({ $0 == " " }) }
        return nonBlankLines.suffix(20).joined(separator: "\n")
    }

    /// Returns the last 20 non-blank lines of terminal output above the prompt separator.
    func extractVisibleText() -> String? {
        guard var lineTexts = extractAllLines() else { return nil }

        // Find the last horizontal rule separator (────...) which divides
        // Claude's output from the user's current prompt input area.
        // Only consider text above it so we don't capture the in-progress prompt.
        let separator = "────────"
        if let lastSeparatorIndex = lineTexts.lastIndex(where: { $0.contains(separator) }) {
            lineTexts = Array(lineTexts.prefix(lastSeparatorIndex))
        }

        return relevantText(from: lineTexts)
    }

    /// Returns the last 20 non-blank lines of the full terminal output (including prompt area).
    func extractFullVisibleText() -> String? {
        guard let lineTexts = extractAllLines() else { return nil }
        return relevantText(from: lineTexts)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)

        guard let id = sessionId else { return }

        // Debounce status checks — the buffer can be mid-render when
        // dataReceived fires, causing transient misreads that flicker
        // between .working and .idle.
        statusDebounceTimer?.invalidate()
        statusDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.evaluateStatus(for: id)
        }
    }

    private func evaluateStatus(for id: UUID) {
        guard let visibleText = extractVisibleText() else { return }
        let fullText = extractFullVisibleText() ?? visibleText

        let newStatus: TerminalStatus

        if Self.hasTokenCounterLine(visibleText) || fullText.contains("esc to interrupt") {
            newStatus = .working
        }
        else if fullText.contains("Esc to cancel") {
            // Claude needs a decision (tool permission, file edit, etc.)
            newStatus = .waitingForInput
        } else if visibleText.contains("Interrupted") {
            newStatus = .interrupted
        } else {
            // Includes Claude's ❯ prompt (task finished) and shell prompt
            newStatus = .idle
        }

        DispatchQueue.main.async {
            SessionStore.shared.updateTerminalStatus(id, status: newStatus)
        }
    }

    /// Checks whether the text contains a Claude spinner character (visible during working state)
    private static let spinnerCharacters: Set<Character> = ["·", "✢", "✳", "✶", "✻", "✽"]

    /// Checks for a line like "Idle for 30s" — must contain " for " and end with "s",
    /// but must NOT contain parentheses (which indicate thinking duration, not true idle).
    private static func hasIdleForLine(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains(" for ") else { return false }
            guard trimmed.hasSuffix("s") else { return false }
            guard !trimmed.contains("(") && !trimmed.contains(")") else { return false }
            return true
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

class TerminalManager: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = TerminalManager()

    private var terminals: [UUID: LocalProcessTerminalView] = [:]

    func terminal(for sessionId: UUID, workingDirectory: String, launchClaude: Bool = true) -> LocalProcessTerminalView {
        if let existing = terminals[sessionId] {
            return existing
        }

        let terminal = ClickThroughTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 460))
        terminal.sessionId = sessionId
        terminal.processDelegate = self

        // Match macOS Terminal default font size
        terminal.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(white: 0.1, alpha: 1.0)
        terminal.nativeForegroundColor = NSColor(white: 0.9, alpha: 1.0)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let environment = buildEnvironment()

        terminal.startProcess(
            executable: shell,
            args: ["--login"],
            environment: environment,
            execName: "-" + (shell as NSString).lastPathComponent
        )

        // cd to working directory, launch claude only if CLAUDE.md exists
        let escapedDir = shellEscape(workingDirectory)
        let hasClaude = launchClaude && FileManager.default.fileExists(atPath: (workingDirectory as NSString).appendingPathComponent("CLAUDE.md"))
        if hasClaude {
            terminal.send(txt: "cd \(escapedDir) && clear && claude\r")
        } else {
            terminal.send(txt: "cd \(escapedDir) && clear\r")
        }

        terminals[sessionId] = terminal
        return terminal
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let dir = directory,
              let terminal = source as? ClickThroughTerminalView,
              let sessionId = terminal.sessionId else { return }
        // OSC 7 sends directory as file://hostname/path — extract just the path
        let path: String
        if let url = URL(string: dir), url.scheme == "file" {
            path = url.path
        } else {
            path = dir
        }
        DispatchQueue.main.async {
            SessionStore.shared.updateWorkingDirectory(sessionId, directory: path)
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {}

    /// Returns the visible text from a terminal's buffer
    func visibleText(for sessionId: UUID) -> String? {
        guard let terminal = terminals[sessionId] as? ClickThroughTerminalView else { return nil }
        return terminal.extractVisibleText()
    }

    func focusTerminal(for paneId: UUID) {
        guard let terminal = terminals[paneId] else { return }
        terminal.window?.makeFirstResponder(terminal)
    }

    func destroyTerminal(for sessionId: UUID) {
        terminals.removeValue(forKey: sessionId)
    }

    private func buildEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        // Enable OSC 7 directory reporting — macOS /etc/zshrc only sends it
        // when TERM_PROGRAM is "Apple_Terminal"
        env["TERM_PROGRAM"] = "Apple_Terminal"
        return env.map { "\($0.key)=\($0.value)" }
    }

    private func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
