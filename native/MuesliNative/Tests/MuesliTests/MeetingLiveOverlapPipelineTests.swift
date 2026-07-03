import FluidAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting live overlap pipeline")
struct MeetingLiveOverlapPipelineTests {
    @Test("meeting backend selection drives GigaAM chunking even when dictation backend differs")
    func meetingBackendSelectionDrivesChunking() throws {
        var config = AppConfig()
        config.sttBackend = BackendOption.whisperTinyEnglish.backend
        config.sttModel = BackendOption.whisperTinyEnglish.model
        config.meetingTranscriptionBackend = BackendOption.gigaAMV3Russian.backend
        config.meetingTranscriptionModel = BackendOption.gigaAMV3Russian.model

        let resolved = try #require(MuesliController.availableMeetingTranscriptionBackend(
            config: config,
            dictationBackend: .whisperTinyEnglish,
            downloadedOptions: [.whisperTinyEnglish, .gigaAMV3Russian]
        ))
        let chunking = MeetingSession.liveChunkingConfiguration(for: resolved)

        #expect(resolved == .gigaAMV3Russian)
        #expect(chunking.minChunkDuration == 3)
        #expect(chunking.maxChunkDuration == 20)
        #expect(chunking.overlapSampleCount == 32_000)
        #expect(chunking.deduplicatesText)
    }

    @Test("live checkpoint assembler deduplicates GigaAM overlap per speaker only")
    func liveCheckpointDeduplicatesPerSpeaker() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var overlapBySpeaker: [String: String] = [:]

        let firstMic = LiveTranscriptCheckpointAssembler.entries(
            segments: [SpeechSegment(start: 0, end: 10, text: "alpha beta gamma delta epsilon")],
            speaker: "You",
            meetingID: 42,
            liveTranscriptStart: start,
            shouldDeduplicate: true,
            overlapByMeetingSpeaker: &overlapBySpeaker
        )
        let secondMic = LiveTranscriptCheckpointAssembler.entries(
            segments: [SpeechSegment(start: 8, end: 18, text: "gamma delta epsilon zeta eta")],
            speaker: "You",
            meetingID: 42,
            liveTranscriptStart: start,
            shouldDeduplicate: true,
            overlapByMeetingSpeaker: &overlapBySpeaker
        )
        let firstSystem = LiveTranscriptCheckpointAssembler.entries(
            segments: [SpeechSegment(start: 8, end: 18, text: "gamma delta epsilon system words")],
            speaker: "Others",
            meetingID: 42,
            liveTranscriptStart: start,
            shouldDeduplicate: true,
            overlapByMeetingSpeaker: &overlapBySpeaker
        )

        #expect(firstMic.map(\.text) == ["alpha beta gamma delta epsilon"])
        #expect(secondMic.map(\.text) == ["zeta eta"])
        #expect(firstSystem.map(\.text) == ["gamma delta epsilon system words"])
    }

    @Test("live checkpoint assembler leaves duplicate text when overlap dedupe is disabled")
    func liveCheckpointDoesNotDeduplicateWithoutOverlap() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var overlapBySpeaker: [String: String] = [:]
        _ = LiveTranscriptCheckpointAssembler.entries(
            segments: [SpeechSegment(start: 0, end: 10, text: "alpha beta gamma delta epsilon")],
            speaker: "You",
            meetingID: 42,
            liveTranscriptStart: start,
            shouldDeduplicate: false,
            overlapByMeetingSpeaker: &overlapBySpeaker
        )
        let duplicate = LiveTranscriptCheckpointAssembler.entries(
            segments: [SpeechSegment(start: 8, end: 18, text: "gamma delta epsilon zeta eta")],
            speaker: "You",
            meetingID: 42,
            liveTranscriptStart: start,
            shouldDeduplicate: false,
            overlapByMeetingSpeaker: &overlapBySpeaker
        )

        #expect(duplicate.map(\.text) == ["gamma delta epsilon zeta eta"])
        #expect(overlapBySpeaker.isEmpty)
    }

    @Test("chunk collector releases live chunks in registration order under out-of-order completion")
    func chunkCollectorPreservesLiveOrder() async {
        let collector = MeetingChunkCollector()
        let slowFirst = Task { [SpeechSegment(start: 0, end: 1, text: "first")] }
        let fastSecond = Task { [SpeechSegment(start: 1, end: 2, text: "second")] }

        let first = collector.add(slowFirst)
        let second = collector.add(fastSecond)

        #expect(first.registered)
        #expect(second.registered)
        #expect(collector.retire(id: second.retireID, segments: await fastSecond.value)?.isEmpty == true)

        let ready = collector.retire(id: first.retireID, segments: await slowFirst.value)
        #expect(ready?.map { $0.map(\.text) } == [["first"], ["second"]])
    }

    @Test("chunk collector advances past empty earlier chunks")
    func chunkCollectorAdvancesPastEmptyChunks() async {
        let collector = MeetingChunkCollector()
        let emptyFirst = Task { [SpeechSegment]() }
        let second = Task { [SpeechSegment(start: 1, end: 2, text: "second")] }

        let firstRegistration = collector.add(emptyFirst)
        let secondRegistration = collector.add(second)

        #expect(collector.retire(id: secondRegistration.retireID, segments: await second.value)?.isEmpty == true)
        let ready = collector.retire(id: firstRegistration.retireID, segments: await emptyFirst.value)
        #expect(ready?.map { $0.map(\.text) } == [[], ["second"]])
    }

    @Test("GigaAM VAD controller config overrides the 5 second default")
    func gigaAMVadConfigOverridesDefault() {
        let chunking = MeetingSession.liveChunkingConfiguration(for: .gigaAMV3Russian)
        let controller = StreamingVadController(
            minChunkDuration: chunking.minChunkDuration,
            maxChunkDuration: chunking.maxChunkDuration,
            makeInitialState: { VadStreamState.initial() },
            processStreamChunk: { _, state in
                VadStreamResult(state: state, event: nil, probability: 0)
            }
        )

        #expect(controller.configuredMinChunkDurationForTesting == 3)
        #expect(controller.configuredMaxChunkDurationForTesting == 20)
    }

    @Test("synthetic overlapped chunks merge without duplicate markers or gaps")
    func syntheticOverlapTranscriptMergesWithoutDuplicatesOrGaps() {
        let transcripts = [
            "zero one two three four",
            "two three four five six seven",
            "five six seven eight nine",
        ]

        let merged = TranscriptOverlapMerger.merge(transcripts)

        #expect(merged == "zero one two three four five six seven eight nine")
    }
}
