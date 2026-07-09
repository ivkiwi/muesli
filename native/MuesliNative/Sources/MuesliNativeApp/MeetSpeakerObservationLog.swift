import Foundation
import MuesliCore

enum MeetSpeakerObservationLog {
    private struct Entry: Codable {
        let observedAt: String
        let meetingURL: String?
        let speakerName: String?
        let activeSpeakers: [String]?
        let participants: [Participant]
        let source: String
    }

    private struct Participant: Codable {
        let name: String
        let email: String?
        let isOrganizer: Bool
        let isSelf: Bool
    }

    private static let directoryName = "meet-speaker-events"
    private static let lock = NSLock()

    static func fileURL(
        meetingID: Int64,
        supportDirectory: URL = AppIdentity.supportDirectoryURL
    ) -> URL {
        supportDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("meeting-\(meetingID).jsonl")
    }

    static func append(
        _ observation: MeetSpeakerObservation,
        meetingID: Int64,
        supportDirectory: URL = AppIdentity.supportDirectoryURL,
        fileManager: FileManager = .default
    ) throws {
        try lock.withLock {
            let fileURL = fileURL(meetingID: meetingID, supportDirectory: supportDirectory)
            MuesliPaths.preconditionSafeForTestWrite(fileURL)
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let entry = Entry(
                observedAt: isoString(from: observation.observedAt),
                meetingURL: observation.meetingURL,
                speakerName: observation.speakerName,
                activeSpeakers: observation.activeSpeakers.isEmpty ? nil : observation.activeSpeakers,
                participants: observation.participants.map {
                    Participant(
                        name: $0.name,
                        email: $0.email,
                        isOrganizer: $0.isOrganizer,
                        isSelf: $0.isSelf
                    )
                },
                source: observation.source
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(entry)
            data.append(0x0A)

            if !fileManager.fileExists(atPath: fileURL.path) {
                guard fileManager.createFile(
                    atPath: fileURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
                }
            }

            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try securePermissions(at: fileURL, fileManager: fileManager)
        }
    }

    static func load(
        meetingID: Int64,
        supportDirectory: URL = AppIdentity.supportDirectoryURL,
        fileManager: FileManager = .default
    ) throws -> [MeetSpeakerObservation] {
        let fileURL = fileURL(meetingID: meetingID, supportDirectory: supportDirectory)
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        let decoder = JSONDecoder()
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let lineData = String(line).data(using: .utf8),
                      let entry = try? decoder.decode(Entry.self, from: lineData),
                      let observedAt = date(from: entry.observedAt) else {
                    return nil
                }
                return MeetSpeakerObservation(
                    meetingURL: entry.meetingURL,
                    speakerName: entry.speakerName,
                    activeSpeakers: entry.activeSpeakers ?? [],
                    participants: entry.participants.map {
                        MeetingParticipant(
                            name: $0.name,
                            email: $0.email,
                            isOrganizer: $0.isOrganizer,
                            isSelf: $0.isSelf
                        )
                    },
                    observedAt: observedAt,
                    source: entry.source
                )
            }
    }

    private static func securePermissions(at fileURL: URL, fileManager: FileManager) throws {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}
