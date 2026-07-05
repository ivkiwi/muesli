import Foundation

enum TranscriptOverlapMerger {
    private static let overlapSearchWordLimit = 15
    private static let retainedContextWordLimit = 80

    static func merge(_ transcripts: [String]) -> String {
        guard transcripts.count > 1 else {
            return transcripts.first ?? ""
        }

        var merged = transcripts[0]
        var context = retainedContext(from: merged)
        for transcript in transcripts.dropFirst() {
            let addition = uniqueAddition(previous: context, next: transcript)
            if !addition.isEmpty {
                merged += (merged.isEmpty ? "" : " ") + addition
            }
            context = retainedContextAfterAppending(addition, to: context)
        }

        return merged
    }

    static func uniqueAddition(previous: String, next: String) -> String {
        let previousWords = previous.split(separator: " ").map(String.init)
        let nextWords = next.split(separator: " ").map(String.init)
        guard !previousWords.isEmpty, !nextWords.isEmpty else {
            return next
        }

        let tailSize = min(previousWords.count, overlapSearchWordLimit)
        let tail = previousWords.suffix(tailSize).map(normalizedWord)
        var trigramIndex: [String: Int] = [:]
        if tail.count >= 3 {
            for index in 0...(tail.count - 3) {
                trigramIndex["\(tail[index])|\(tail[index + 1])|\(tail[index + 2])"] = index
            }
        }

        let headSize = min(nextWords.count, overlapSearchWordLimit)
        let head = nextWords.prefix(headSize).map(normalizedWord)
        var bestAnchorStart = -1
        var bestRunEnd = 0

        if head.count >= 3 {
            for index in 0...(head.count - 3) {
                let key = "\(head[index])|\(head[index + 1])|\(head[index + 2])"
                guard let tailPosition = trigramIndex[key] else { continue }

                var run = 3
                var tailIndex = tailPosition + 3
                var headIndex = index + 3
                while tailIndex < tail.count, headIndex < head.count, tail[tailIndex] == head[headIndex] {
                    run += 1
                    tailIndex += 1
                    headIndex += 1
                }
                if bestAnchorStart < 0 {
                    bestAnchorStart = index
                    bestRunEnd = index + run
                }
            }
        }

        guard bestAnchorStart >= 0 else {
            let overlap = suffixPrefixOverlap(previousWords, nextWords)
            return nextWords.dropFirst(overlap).joined(separator: " ")
        }

        let preAnchor = nextWords.prefix(bestAnchorStart).joined(separator: " ")
        let postOverlap = nextWords.dropFirst(bestRunEnd).joined(separator: " ")
        return [preAnchor, postOverlap].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func deduplicateSegments(_ segments: [SpeechSegment]) -> [SpeechSegment] {
        var previousText = ""
        return segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let addition = uniqueAddition(previous: previousText, next: text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            previousText = retainedContextAfterAppending(addition, to: previousText)
            guard !addition.isEmpty else { return nil }
            return SpeechSegment(start: segment.start, end: segment.end, text: addition)
        }
    }

    static func retainedContextAfterAppending(_ addition: String, to previous: String) -> String {
        guard !addition.isEmpty else {
            return retainedContext(from: previous)
        }
        return retainedContext(from: [previous, addition].filter { !$0.isEmpty }.joined(separator: " "))
    }

    private static func normalizedWord(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func suffixPrefixOverlap(_ left: [String], _ right: [String]) -> Int {
        let limit = min(overlapSearchWordLimit, left.count, right.count)
        guard limit >= 2 else { return 0 }

        for count in stride(from: limit, through: 2, by: -1) {
            let leftSuffix = left.suffix(count).map(normalizedWord)
            let rightPrefix = right.prefix(count).map(normalizedWord)
            if !leftSuffix.contains(""), leftSuffix == rightPrefix {
                return count
            }
        }

        return 0
    }

    private static func retainedContext(from text: String) -> String {
        let words = text.split(separator: " ")
        guard words.count > retainedContextWordLimit else { return text }
        return words.suffix(retainedContextWordLimit).joined(separator: " ")
    }
}
