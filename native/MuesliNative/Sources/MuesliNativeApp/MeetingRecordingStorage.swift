import AVFoundation
import Foundation

enum MeetingRecordingStorage {
    private static let defaultDirectoryName = "meeting-recordings"
    private static let temporaryDecodeDirectoryName = "guesli-retranscription"

    static func defaultDirectory(supportDirectory: URL = AppIdentity.supportDirectoryURL) -> URL {
        supportDirectory.appendingPathComponent(defaultDirectoryName, isDirectory: true)
    }

    static func directory(
        config: AppConfig,
        supportDirectory: URL = AppIdentity.supportDirectoryURL
    ) -> URL {
        let configuredPath = config.meetingRecordingFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredPath.isEmpty else {
            return defaultDirectory(supportDirectory: supportDirectory)
        }
        return URL(fileURLWithPath: configuredPath, isDirectory: true).standardizedFileURL
    }

    static func persistTemporaryRecording(
        from tempWAVURL: URL,
        meetingTitle: String,
        startedAt: Date,
        config: AppConfig,
        supportDirectory: URL = AppIdentity.supportDirectoryURL
    ) throws -> URL {
        try persistTemporaryRecording(
            from: tempWAVURL,
            meetingTitle: meetingTitle,
            startedAt: startedAt,
            destinationDirectory: directory(config: config, supportDirectory: supportDirectory)
        )
    }

    static func persistTemporaryRecording(
        from tempWAVURL: URL,
        meetingTitle: String,
        startedAt: Date,
        destinationDirectory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        let destinationURL = destinationDirectory.appendingPathComponent(
            "\(fileNamePrefix(for: startedAt, title: meetingTitle)).m4a"
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        do {
            try encodeWAVToM4A(sourceURL: tempWAVURL, destinationURL: destinationURL)
            try? FileManager.default.removeItem(at: tempWAVURL)
            return destinationURL
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    static func temporaryWAVForTranscription(from savedRecordingURL: URL) async throws -> URL {
        let (wavURL, _) = try await AudioFileImportController.convertToWAV(sourceURL: savedRecordingURL)
        return wavURL
    }

    static func cleanupTemporaryTranscriptionFiles() {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(temporaryDecodeDirectoryName)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func encodeWAVToM4A(sourceURL: URL, destinationURL: URL) throws {
        let inputFile = try AVAudioFile(forReading: sourceURL)
        let inputFormat = inputFile.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: Int(inputFormat.channelCount),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let outputFile = try AVAudioFile(forWriting: destinationURL, settings: settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 16_384) else {
            throw NSError(
                domain: "MeetingRecordingStorage",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate an audio conversion buffer."]
            )
        }

        while inputFile.framePosition < inputFile.length {
            let remainingFrames = AVAudioFrameCount(inputFile.length - inputFile.framePosition)
            let framesToRead = min(buffer.frameCapacity, remainingFrames)
            try inputFile.read(into: buffer, frameCount: framesToRead)
            guard buffer.frameLength > 0 else { break }
            try outputFile.write(from: buffer)
        }
    }

    private static func fileNamePrefix(for date: Date, title: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let timestamp = formatter.string(from: date)

        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let normalized = title.unicodeScalars.map { allowed.contains($0) ? String($0) : " " }.joined()
        let slug = normalized
            .split(whereSeparator: \.isWhitespace)
            .prefix(6)
            .joined(separator: "-")
            .lowercased()

        return slug.isEmpty ? timestamp : "\(timestamp)-\(slug)"
    }
}
