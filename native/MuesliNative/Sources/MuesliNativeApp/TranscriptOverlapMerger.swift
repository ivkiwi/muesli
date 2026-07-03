import Foundation

enum TranscriptOverlapMerger {
    /// Merge transcripts from overlapping audio chunks by deduplicating shared content.
    /// Uses hash-based trigram matching near the previous tail and next head.
    static func merge(_ transcripts: [String]) -> String {
        guard transcripts.count > 1 else {
            return transcripts.first ?? ""
        }

        var merged = transcripts[0]
        for transcript in transcripts.dropFirst() {
            let addition = uniqueAddition(previous: merged, next: transcript)
            if !addition.isEmpty {
                merged += (merged.isEmpty ? "" : " ") + addition
            }
        }

        return merged
    }

    static func uniqueAddition(previous: String, next: String) -> String {
        let prevWords = previous.split(separator: " ").map(String.init)
        let nextWords = next.split(separator: " ").map(String.init)
        guard !prevWords.isEmpty, !nextWords.isEmpty else {
            return next
        }

        let normalize: (String) -> String = { $0.lowercased().filter(\.isLetter) }

        let tailSize = min(prevWords.count, 40)
        let tail = prevWords.suffix(tailSize).map { normalize($0) }
        var trigramIndex: [String: Int] = [:]
        if tail.count >= 3 {
            for j in 0...(tail.count - 3) {
                let key = "\(tail[j])|\(tail[j + 1])|\(tail[j + 2])"
                trigramIndex[key] = j
            }
        }

        let headSize = min(nextWords.count, 40)
        let head = nextWords.prefix(headSize).map { normalize($0) }
        var bestAnchorStart = -1
        var bestRunEnd = 0

        if head.count >= 3 {
            for j in 0...(head.count - 3) {
                let key = "\(head[j])|\(head[j + 1])|\(head[j + 2])"
                if let tailPos = trigramIndex[key] {
                    var run = 3
                    var ti = tailPos + 3
                    var hi = j + 3
                    while ti < tail.count && hi < head.count && tail[ti] == head[hi] {
                        run += 1
                        ti += 1
                        hi += 1
                    }
                    if bestAnchorStart < 0 {
                        bestAnchorStart = j
                        bestRunEnd = j + run
                    }
                }
            }
        }

        guard bestAnchorStart >= 0 else { return next }

        let preAnchor = nextWords.prefix(bestAnchorStart).joined(separator: " ")
        let postOverlap = nextWords.dropFirst(bestRunEnd).joined(separator: " ")
        return [preAnchor, postOverlap].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func deduplicateSegments(_ segments: [SpeechSegment]) -> [SpeechSegment] {
        guard !segments.isEmpty else { return [] }
        var mergedText = ""
        var result: [SpeechSegment] = []

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let addition = uniqueAddition(previous: mergedText, next: text)
            guard !addition.isEmpty else { continue }
            mergedText += (mergedText.isEmpty ? "" : " ") + addition
            result.append(SpeechSegment(start: segment.start, end: segment.end, text: addition))
        }

        return result
    }
}
