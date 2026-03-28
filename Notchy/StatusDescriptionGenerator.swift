import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

class StatusDescriptionGenerator {
    static let shared = StatusDescriptionGenerator()

    private var inFlightSessions: Set<UUID> = []

    func generateStatus(
        for sessionId: UUID,
        visibleText: String,
        terminalStatus: TerminalStatus,
        projectName: String
    ) async -> String? {
#if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return nil }

        // Skip if already generating for this session
        guard !inFlightSessions.contains(sessionId) else { return nil }
        inFlightSessions.insert(sessionId)
        defer { inFlightSessions.remove(sessionId) }

        let context: String
        switch terminalStatus {
        case .working:
            context = "Currently working on a task."
        case .waitingForInput:
            context = "Finished a task and waiting for the user to respond or give the next instruction."
        case .idle:
            context = "Momentarily idle — likely about to start the next task. Do NOT say the task is done, completed, or finished. Focus on what was just happening or what's coming next."
        case .interrupted:
            context = "Was interrupted by the user."
        case .taskCompleted:
            context = "Just finished a task successfully."
        }

        let prompt = """
        You are reading a terminal screen dump of Claude Code running in project "\(projectName)".

        IMPORTANT: The terminal may contain output from MULTIPLE tasks. You must identify the LATEST \
        user request — look for the last "❯" or ">" prompt where the user typed a message, or the last \
        Claude Code response block. Everything before the most recent user request is OLD and irrelevant. \
        Only report on what is happening in response to the MOST RECENT request.

        Write a short, direct first-person status (max 8 words) about what you're doing RIGHT NOW. \
        Be specific about the actual task from the LATEST terminal activity. Never say you're idle, \
        done, completed, or finished. Focus on what you just did or are actively doing. \
        No quotes or ending punctuation.

        Your current state: \(context)

        Terminal screen dump (most recent action is at the bottom):
        \(visibleText.suffix(2000))

        Status update (about the LATEST task only):
        """

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : String(text.prefix(60))
        } catch {
            // Error generating status
            return nil
        }
#else
        return nil
#endif
    }

    func generateWaitingForInputStatus(
        for sessionId: UUID,
        visibleText: String,
        projectName: String
    ) async -> String? {
#if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return nil }

        guard !inFlightSessions.contains(sessionId) else { return nil }
        inFlightSessions.insert(sessionId)
        defer { inFlightSessions.remove(sessionId) }

        let prompt = """
        You are reading a terminal screen dump of Claude Code running in project "\(projectName)". \
        Claude has stopped and is waiting for the user to respond.

        Your job: find the SPECIFIC question or action Claude is asking the user to take. Look at the \
        LAST few lines of output — Claude may be asking the user to approve a tool call, answer a \
        question, confirm a change, or provide input.

        Write a short summary (max 8 words) of what the user needs to do, phrased as an action. \
        Examples: "Approve file edit", "Answer: which database?", "Confirm deploy to staging", \
        "Review pending tool call", "Respond to permission prompt". \
        Be specific to the actual question. No quotes or ending punctuation.

        Terminal screen dump (most recent output at the bottom):
        \(visibleText.suffix(2000))

        What the user needs to do:
        """

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : String(text.prefix(60))
        } catch {
            // Error generating status
            return nil
        }
#else
        return nil
#endif
    }

    func generateTaskCompletedStatus(
        for sessionId: UUID,
        visibleText: String,
        projectName: String
    ) async -> String? {
#if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return nil }

        guard !inFlightSessions.contains(sessionId) else { return nil }
        inFlightSessions.insert(sessionId)
        defer { inFlightSessions.remove(sessionId) }

        let prompt = """
        You are reading a terminal screen dump of Claude Code running in project "\(projectName)". \
        A task just finished.

        IMPORTANT: The terminal may contain output from MULTIPLE tasks. You must identify the LATEST \
        user request — look for the last "❯" or ">" prompt where the user typed a message, or the last \
        Claude Code response block. Only describe what was done for the MOST RECENT request. Ignore \
        all previous completed tasks.

        Write a short, direct first-person message (max 10 words) stating the task is done. \
        Be specific to what was actually completed. No quotes or ending punctuation.

        Terminal screen dump (most recent action is at the bottom):
        \(visibleText.suffix(2000))

        Completion message (about the LATEST task only):
        """

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : String(text.prefix(60))
        } catch {
            // Error generating status
            return nil
        }
#else
        return nil
#endif
    }

    func expiryDuration(for status: TerminalStatus) -> TimeInterval? {
        switch status {
        case .taskCompleted:
            return 6
        case .idle:
            return 6
        case .waitingForInput:
            return 120
        case .working:
            return 6
        case .interrupted:
            return 6
        }
    }
}
