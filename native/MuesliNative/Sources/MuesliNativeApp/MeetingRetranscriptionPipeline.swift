import FluidAudio
import Foundation

enum MeetingRetranscriptionPipeline {
    enum TrackRole: Sendable, CustomStringConvertible {
        case mic
        case system

        var description: String {
            switch self {
            case .mic: return "mic"
            case .system: return "system"
            }
        }
    }

    struct AudioSegment: Equatable, Sendable {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let startSample: Int
        let endSample: Int
    }

    struct SegmentAudio: Sendable {
        let segment: AudioSegment
        let samples: [Float]
    }

    struct AudioLevelStats: Equatable, Sendable {
        let duration: TimeInterval
        let rms: Double
        let peak: Double
        let nonZeroRatio: Double
    }

    static let vadSegmentationConfig = VadSegmentationConfig(
        maxSpeechDuration: 10.0,
        speechPadding: 0.15
    )

    static func audioSegments(
        from vadSegments: [VadSegment],
        sampleCount: Int,
        sampleRate: Int = VadManager.sampleRate
    ) -> [AudioSegment] {
        guard sampleCount > 0, sampleRate > 0 else { return [] }
        return vadSegments.compactMap { segment -> AudioSegment? in
            let startSample = max(0, min(sampleCount, segment.startSample(sampleRate: sampleRate)))
            let endSample = max(startSample, min(sampleCount, segment.endSample(sampleRate: sampleRate)))
            guard endSample > startSample else { return nil }
            return AudioSegment(
                startTime: Double(startSample) / Double(sampleRate),
                endTime: Double(endSample) / Double(sampleRate),
                startSample: startSample,
                endSample: endSample
            )
        }.sorted { lhs, rhs in
            if lhs.startSample == rhs.startSample {
                return lhs.endSample < rhs.endSample
            }
            return lhs.startSample < rhs.startSample
        }
    }

    static func transcribeSegmentedAudio(
        samples: [Float],
        vadSegments: [VadSegment],
        trackRole: TrackRole = .system,
        diagnosticsLabel: String? = nil,
        logger: (String) -> Void = { _ in },
        transcribeSegment: (AudioSegment, [Float]) async throws -> SpeechTranscriptionResult
    ) async throws -> SpeechTranscriptionResult {
        try await transcribeSegmentedAudio(
            samples: samples,
            vadSegments: vadSegments,
            trackRole: trackRole,
            diagnosticsLabel: diagnosticsLabel,
            logger: logger
        ) { segmentAudio in
            var results: [SpeechTranscriptionResult] = []
            results.reserveCapacity(segmentAudio.count)
            for item in segmentAudio {
                results.append(try await transcribeSegment(item.segment, item.samples))
            }
            return results
        }
    }

    static func transcribeSegmentedAudio(
        samples: [Float],
        vadSegments: [VadSegment],
        trackRole: TrackRole = .system,
        diagnosticsLabel: String? = nil,
        logger: (String) -> Void = { _ in },
        transcribeSegments: ([SegmentAudio]) async throws -> [SpeechTranscriptionResult]
    ) async throws -> SpeechTranscriptionResult {
        let segmentAudio = audioSegments(from: vadSegments, sampleCount: samples.count).map { segment in
            SegmentAudio(
                segment: segment,
                samples: Array(samples[segment.startSample..<segment.endSample])
            )
        }
        let trimmedLabel = diagnosticsLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let label = trimmedLabel.isEmpty ? nil : trimmedLabel
        if let label {
            let covered = coveredDuration(segmentAudio.map(\.segment))
            logger("\(label) batch_start track=\(trackRole) segments=\(segmentAudio.count) covered=\(formatSeconds(covered))")
        }
        let results: [SpeechTranscriptionResult]
        do {
            results = try await transcribeSegments(segmentAudio)
        } catch {
            if let label {
                logger("\(label) batch_failed track=\(trackRole) segments=\(segmentAudio.count) error=\(error.localizedDescription)")
            }
            throw error
        }
        if let label {
            let chars = results.reduce(0) { $0 + $1.text.trimmingCharacters(in: .whitespacesAndNewlines).count }
            let empty = results.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            logger("\(label) batch_done track=\(trackRole) results=\(results.count) empty=\(empty) chars=\(chars)")
        }
        guard results.count == segmentAudio.count else {
            throw NSError(domain: "MeetingRetranscriptionPipeline", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Retranscription batch returned \(results.count) results for \(segmentAudio.count) segments.",
            ])
        }
        var transcriptSegments: [SpeechSegment] = []
        for (item, result) in zip(segmentAudio, results) {
            transcriptSegments.append(contentsOf: normalize(
                result: result,
                trackRole: trackRole,
                startTime: item.segment.startTime,
                endTime: item.segment.endTime
            ))
        }
        let ordered = transcriptSegments.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }
        let text = ordered
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return SpeechTranscriptionResult(text: text, segments: ordered)
    }

    static func audioLevelStats(
        samples: [Float],
        sampleRate: Int = VadManager.sampleRate
    ) -> AudioLevelStats {
        guard !samples.isEmpty else {
            return AudioLevelStats(duration: 0, rms: 0, peak: 0, nonZeroRatio: 0)
        }
        var sumSquares = 0.0
        var peak = 0.0
        var nonZero = 0
        for sample in samples {
            let value = Double(sample)
            let magnitude = abs(value)
            sumSquares += value * value
            peak = max(peak, magnitude)
            if magnitude > 0.000_001 {
                nonZero += 1
            }
        }
        return AudioLevelStats(
            duration: Double(samples.count) / Double(max(sampleRate, 1)),
            rms: sqrt(sumSquares / Double(samples.count)),
            peak: peak,
            nonZeroRatio: Double(nonZero) / Double(samples.count)
        )
    }

    static func coveredDuration(_ segments: [AudioSegment]) -> TimeInterval {
        segments.reduce(0) { total, segment in
            total + max(0, segment.endTime - segment.startTime)
        }
    }

    static func coveredDuration(_ segments: [SpeechSegment]) -> TimeInterval {
        segments.reduce(0) { total, segment in
            total + max(0, segment.end - segment.start)
        }
    }

    static func characterCount(_ segments: [SpeechSegment]) -> Int {
        segments.reduce(0) { total, segment in
            total + segment.text.trimmingCharacters(in: .whitespacesAndNewlines).count
        }
    }

    static func shouldRetryFullTrack(
        trackRole: TrackRole,
        segmentedCharacterCount: Int,
        sourceDuration: TimeInterval,
        coveredDuration: TimeInterval
    ) -> Bool {
        guard trackRole == .system else { return false }
        guard sourceDuration >= 900, coveredDuration >= 600 else { return false }
        return segmentedCharacterCount < minimumExpectedCharacters(coveredDuration: coveredDuration)
    }

    static func suspiciousTranscriptReason(
        transcript: String,
        meetingDuration: TimeInterval,
        systemSegmentCount: Int,
        systemCoveredDuration: TimeInterval
    ) -> String? {
        let chars = transcript.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard meetingDuration >= 900, systemSegmentCount >= 20, systemCoveredDuration >= 600 else { return nil }
        let minimumChars = minimumExpectedCharacters(coveredDuration: systemCoveredDuration)
        guard chars < minimumChars else { return nil }
        return "post-mode transcript suspiciously short chars=\(chars) minimum=\(minimumChars) duration=\(formatSeconds(meetingDuration)) system_segments=\(systemSegmentCount) system_covered=\(formatSeconds(systemCoveredDuration))"
    }

    static func applyTrackOffset(
        _ segments: [SpeechSegment],
        offset: TimeInterval
    ) -> [SpeechSegment] {
        guard offset != 0 else { return segments }
        return segments.map {
            SpeechSegment(
                start: $0.start + offset,
                end: $0.end + offset,
                text: $0.text
            )
        }
    }

    static func applyDiarizationOffset(
        _ segments: [TimedSpeakerSegment]?,
        offset: TimeInterval
    ) -> [TimedSpeakerSegment]? {
        guard let segments else { return nil }
        guard offset != 0 else { return segments }
        let floatOffset = Float(offset)
        return segments.map {
            TimedSpeakerSegment(
                speakerId: $0.speakerId,
                embedding: $0.embedding,
                startTimeSeconds: $0.startTimeSeconds + floatOffset,
                endTimeSeconds: $0.endTimeSeconds + floatOffset,
                qualityScore: $0.qualityScore
            )
        }
    }

    static func postModeOrderedSegments(
        micSegments: [SpeechSegment],
        micStartOffset: TimeInterval,
        systemSegments: [SpeechSegment],
        systemStartOffset: TimeInterval
    ) -> [SpeechSegment] {
        (
            applyTrackOffset(micSegments, offset: micStartOffset)
                + applyTrackOffset(systemSegments, offset: systemStartOffset)
        ).sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }
    }

    private static func normalize(
        result: SpeechTranscriptionResult,
        trackRole: TrackRole,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> [SpeechSegment] {
        switch trackRole {
        case .mic:
            return MicTurnNormalizer.normalize(
                result: result,
                startTime: startTime,
                endTime: endTime
            )
        case .system:
            return SystemTurnNormalizer.normalize(
                result: result,
                startTime: startTime,
                endTime: endTime
            )
        }
    }

    private static func minimumExpectedCharacters(coveredDuration: TimeInterval) -> Int {
        max(3_000, Int((coveredDuration / 60.0) * 180.0))
    }

    private static func formatSeconds(_ value: TimeInterval) -> String {
        String(format: "%.1fs", value)
    }
}

enum MeetingPostProcessingError: Error, LocalizedError {
    case suspiciouslyShortTranscript(String)

    var errorDescription: String? {
        switch self {
        case .suspiciouslyShortTranscript(let reason):
            return "Meeting transcript needs attention: \(reason)"
        }
    }
}
