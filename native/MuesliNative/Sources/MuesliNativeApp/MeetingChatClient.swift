// Purpose: Multi-turn LLM chat client for in-meeting and post-meeting transcript chat
// Created: 2026-05-22

import Foundation
import MuesliCore
import os

typealias MeetingChatMessage = LLMMessage

enum MeetingChatClient {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MeetingChat")
    private static let chatTimeout: TimeInterval = 120
    // ~90k token budget; rough char estimate at 4 chars/token
    private static let maxTranscriptChars = 360_000

    static func send(messages: [MeetingChatMessage], config: AppConfig) async throws -> String {
        try await LLMBackendClient.send(
            messages: trimmedMessages(messages),
            config: config,
            timeout: chatTimeout,
            maxTokens: nil
        )
    }

    // MARK: - Context window

    /// Returns a copy of messages with the system prompt's transcript trimmed to fit the budget.
    static func trimmedMessages(_ messages: [MeetingChatMessage]) -> [MeetingChatMessage] {
        guard let sysIdx = messages.firstIndex(where: { $0.role == .system }) else {
            return messages
        }
        let sysMsg = messages[sysIdx]
        guard sysMsg.content.count > maxTranscriptChars else { return messages }

        // Keep the newest chunks — trim from the top after any header text before the transcript.
        let trimmedContent: String
        if let range = sysMsg.content.range(of: "\n---\n") {
            let header = String(sysMsg.content[..<range.upperBound])
            let body = String(sysMsg.content[range.upperBound...])
            let allowedBodyChars = maxTranscriptChars - header.count
            if allowedBodyChars > 0 {
                let trimmedBody = String(body.suffix(allowedBodyChars))
                // Drop the first (likely partial) line
                let firstNewline = trimmedBody.firstIndex(of: "\n") ?? trimmedBody.startIndex
                trimmedContent = header + "[...earlier transcript trimmed...]\n" + String(trimmedBody[firstNewline...])
            } else {
                trimmedContent = header + "[transcript omitted — too long]"
            }
        } else {
            trimmedContent = String(sysMsg.content.suffix(maxTranscriptChars))
        }

        var result = messages
        result[sysIdx] = MeetingChatMessage(role: .system, content: trimmedContent)
        return result
    }
}
