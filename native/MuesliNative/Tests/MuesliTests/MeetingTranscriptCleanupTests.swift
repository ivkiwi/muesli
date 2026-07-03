import Foundation
import Testing
@testable import MuesliNativeApp

private struct StaticMeetingTranscriptCleaner: MeetingTranscriptCleaning {
    let output: String

    func cleanupMeetingTranscript(_ transcript: String, config: AppConfig) async throws -> String {
        output
    }
}

private struct ThrowingMeetingTranscriptCleaner: MeetingTranscriptCleaning {
    func cleanupMeetingTranscript(_ transcript: String, config: AppConfig) async throws -> String {
        throw NSError(domain: "MeetingTranscriptCleanupTests", code: 1)
    }
}

@Suite("Meeting transcript cleanup pipeline")
struct MeetingTranscriptCleanupTests {
    @Test("successful cleanup preserves original transcript")
    func successfulCleanupPreservesOriginalTranscript() async {
        var config = AppConfig()
        config.enableMeetingTranscriptCleanup = true
        config.meetingTranscriptCleanupProvider = MeetingTranscriptCleanupProviderOption.chatGPT.rawValue

        let result = await MeetingTranscriptCleanupPipeline.cleanIfNeeded(
            transcript: "[00:00:01] Speaker 1: um hello hello",
            config: config,
            isChatGPTAuthenticated: true,
            cleaner: StaticMeetingTranscriptCleaner(output: "[00:00:01] Speaker 1: Hello.")
        )

        #expect(result.transcript == "[00:00:01] Speaker 1: Hello.")
        #expect(result.originalTranscript == "[00:00:01] Speaker 1: um hello hello")
    }

    @Test("cleanup error falls back to raw transcript")
    func cleanupErrorFallsBackToRawTranscript() async {
        var config = AppConfig()
        config.enableMeetingTranscriptCleanup = true
        config.meetingTranscriptCleanupProvider = MeetingTranscriptCleanupProviderOption.chatGPT.rawValue

        let result = await MeetingTranscriptCleanupPipeline.cleanIfNeeded(
            transcript: "[00:00:01] Speaker 1: raw words",
            config: config,
            isChatGPTAuthenticated: true,
            cleaner: ThrowingMeetingTranscriptCleaner()
        )

        #expect(result.transcript == "[00:00:01] Speaker 1: raw words")
        #expect(result.originalTranscript == nil)
    }

    @Test("unauthenticated cleanup keeps raw transcript")
    func unauthenticatedCleanupKeepsRawTranscript() async {
        var config = AppConfig()
        config.enableMeetingTranscriptCleanup = true
        config.meetingTranscriptCleanupProvider = MeetingTranscriptCleanupProviderOption.chatGPT.rawValue

        let result = await MeetingTranscriptCleanupPipeline.cleanIfNeeded(
            transcript: "[00:00:01] Speaker 1: raw words",
            config: config,
            isChatGPTAuthenticated: false,
            cleaner: StaticMeetingTranscriptCleaner(output: "cleaned")
        )

        #expect(result.transcript == "[00:00:01] Speaker 1: raw words")
        #expect(result.originalTranscript == nil)
    }
}
