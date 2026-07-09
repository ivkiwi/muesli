import Foundation
import Network

struct MeetSpeakerObservation: Equatable, Sendable {
    let meetingURL: String?
    let speakerName: String?
    let activeSpeakers: [String]
    let participants: [MeetingParticipant]
    let observedAt: Date
    let source: String

    init(
        meetingURL: String?,
        speakerName: String?,
        activeSpeakers: [String] = [],
        participants: [MeetingParticipant],
        observedAt: Date,
        source: String
    ) {
        self.meetingURL = meetingURL
        self.speakerName = speakerName
        self.activeSpeakers = activeSpeakers
        self.participants = participants
        self.observedAt = observedAt
        self.source = source
    }
}

struct MeetSpeakerObservationStats: Equatable, Sendable {
    var observationsReceived = 0
    var speakerEvents = 0
    var participantSnapshots = 0

    mutating func record(_ observation: MeetSpeakerObservation) {
        observationsReceived += 1
        if observation.speakerName != nil || !observation.activeSpeakers.isEmpty {
            speakerEvents += 1
        }
        if !observation.participants.isEmpty {
            participantSnapshots += 1
        }
    }

    static func make(from observations: [MeetSpeakerObservation]) -> MeetSpeakerObservationStats {
        var stats = MeetSpeakerObservationStats()
        observations.forEach { stats.record($0) }
        return stats
    }
}

final class MeetSpeakerBridgeServer {
    static let port: NWEndpoint.Port = 1477
    static let path = "/v1/meet-speaker"
    private static let maxRequestBytes = 128 * 1024

    private var listener: NWListener?
    var onObservation: ((MeetSpeakerObservation) -> Void)?

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: Self.port)
        guard let listener = try? NWListener(using: params) else {
            DiagnosticsLog.write("[meet-speaker] bridge start failed port=\(Self.port)")
            return
        }

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            self?.receiveRequest(on: connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                DiagnosticsLog.write("[meet-speaker] bridge failed error=\(error)")
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        DiagnosticsLog.write("[meet-speaker] bridge start port=\(Self.port)")
    }

    func stop() {
        guard let listener else { return }
        listener.cancel()
        self.listener = nil
        DiagnosticsLog.write("[meet-speaker] bridge stop port=\(Self.port)")
    }

    private func handle(_ data: Data?) -> String {
        guard let data, let request = String(data: data, encoding: .utf8) else {
            return Self.http(status: "400 Bad Request")
        }
        if request.hasPrefix("OPTIONS ") {
            return Self.http(status: "204 No Content")
        }
        guard request.hasPrefix("POST \(Self.path) ") else {
            return Self.http(status: "404 Not Found")
        }
        guard let body = Self.bodyData(from: data) else {
            return Self.http(status: "400 Bad Request")
        }
        let observations = Self.parseObservations(body)
        guard !observations.isEmpty else {
            return Self.http(status: "400 Bad Request")
        }
        for observation in observations {
            onObservation?(observation)
        }
        return Self.http(status: "204 No Content")
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if Self.isOversizedHTTPRequestBuffer(nextBuffer) {
                self.sendResponse(Self.http(status: "400 Bad Request"), on: connection)
                return
            }

            if let expectedLength = Self.completeHTTPRequestLength(nextBuffer),
               nextBuffer.count >= expectedLength {
                self.sendResponse(self.handle(nextBuffer), on: connection)
                return
            }

            guard error == nil,
                  !isComplete else {
                self.sendResponse(Self.http(status: "400 Bad Request"), on: connection)
                return
            }

            self.receiveRequest(on: connection, buffer: nextBuffer)
        }
    }

    private func sendResponse(_ response: String, on connection: NWConnection) {
        connection.send(
            content: response.data(using: .utf8),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    static func parseObservation(_ data: Data) -> MeetSpeakerObservation? {
        parseObservations(data).first
    }

    static func parseObservations(_ data: Data, receivedAt: Date = Date()) -> [MeetSpeakerObservation] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let rawObservations = json["observations"] as? [Any] {
            return rawObservations.compactMap { rawObservation in
                guard var observationJSON = rawObservation as? [String: Any] else { return nil }
                if observationJSON["meetingURL"] == nil {
                    observationJSON["meetingURL"] = json["meetingURL"] ?? json["meetingUrl"]
                }
                if observationJSON["source"] == nil {
                    observationJSON["source"] = json["source"]
                }
                return parseObservationObject(observationJSON, receivedAt: receivedAt)
            }
        }
        return parseObservationObject(json, receivedAt: receivedAt).map { [$0] } ?? []
    }

    private static func parseObservationObject(_ json: [String: Any], receivedAt: Date) -> MeetSpeakerObservation? {
        let participants = parseParticipants(json["participants"])
        let speakerName = sanitizedSpeakerName(json["speakerName"] as? String ?? json["speaker"] as? String)
        let activeSpeakers = parseActiveSpeakers(json["activeSpeakers"])
        guard speakerName != nil || !activeSpeakers.isEmpty || !participants.isEmpty else { return nil }
        let source = (json["source"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let meetingURL = (json["meetingURL"] as? String ?? json["meetingUrl"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetSpeakerObservation(
            meetingURL: meetingURL?.isEmpty == true ? nil : meetingURL,
            speakerName: speakerName,
            activeSpeakers: activeSpeakers,
            participants: participants,
            observedAt: parseObservedAt(json, fallback: receivedAt),
            source: source?.isEmpty == false ? source! : "meet-extension"
        )
    }

    private static func parseObservedAt(_ json: [String: Any], fallback: Date) -> Date {
        if let milliseconds = json["observedAtMs"] as? Double {
            return Date(timeIntervalSince1970: milliseconds / 1000.0)
        }
        if let milliseconds = json["observedAtMs"] as? Int {
            return Date(timeIntervalSince1970: Double(milliseconds) / 1000.0)
        }
        if let seconds = json["observedAtSeconds"] as? Double {
            return Date(timeIntervalSince1970: seconds)
        }
        if let isoString = json["observedAt"] as? String,
           let date = ISO8601DateFormatter().date(from: isoString) {
            return date
        }
        return fallback
    }

    private static func parseActiveSpeakers(_ raw: Any?) -> [String] {
        guard let rawSpeakers = raw as? [Any] else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for rawSpeaker in rawSpeakers {
            let rawName: String?
            switch rawSpeaker {
            case let value as String:
                rawName = value
            case let object as [String: Any]:
                rawName = object["name"] as? String
                    ?? object["speakerName"] as? String
                    ?? object["displayName"] as? String
            default:
                rawName = nil
            }
            guard let name = sanitizedSpeakerName(rawName) else { continue }
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard seen.insert(key).inserted else { continue }
            result.append(name)
        }
        return result
    }

    private static func sanitizedSpeakerName(_ value: String?) -> String? {
        guard let name = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              name.count >= 2,
              name.count <= 120,
              !isClockLikeSpeakerName(name) else {
            return nil
        }
        return name
    }

    private static func parseParticipants(_ raw: Any?) -> [MeetingParticipant] {
        guard let rawParticipants = raw as? [Any] else { return [] }
        var seen = Set<String>()
        var result: [MeetingParticipant] = []
        for rawParticipant in rawParticipants {
            let name: String?
            let isSelf: Bool
            switch rawParticipant {
            case let value as String:
                name = value
                isSelf = false
            case let object as [String: Any]:
                name = object["name"] as? String ?? object["displayName"] as? String
                isSelf = object["isSelf"] as? Bool ?? false
            default:
                continue
            }
            guard let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  trimmedName.count >= 2,
                  trimmedName.count <= 120 else { continue }
            let key = trimmedName.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(MeetingParticipant(
                name: trimmedName,
                email: nil,
                isOrganizer: false,
                isSelf: isSelf
            ))
        }
        return result
    }

    private static func isClockLikeSpeakerName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let clock = pieces.first.map(String.init) ?? trimmed
        let suffix = pieces.count == 2 ? String(pieces[1]) : ""
        if !suffix.isEmpty, !["AM", "PM"].contains(suffix.uppercased()) {
            return false
        }
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return false }
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return false }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count else { return false }
        guard (0...23).contains(values[0]), (0...59).contains(values[1]) else { return false }
        return parts.count == 2 || (0...59).contains(values[2])
    }

    private static func bodyData(from data: Data) -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else { return nil }
        return data[range.upperBound...]
    }

    static func completeHTTPRequestLength(_ data: Data) -> Int? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else { return nil }
        let headerLength = range.upperBound
        guard let header = String(data: data[..<range.lowerBound], encoding: .utf8) else {
            return headerLength
        }
        let contentLength = header
            .components(separatedBy: .newlines)
            .compactMap { line -> Int? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.lowercased().hasPrefix("content-length:") else { return nil }
                return Int(trimmed.dropFirst("content-length:".count).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            .first ?? 0
        return headerLength + contentLength
    }

    static func isOversizedHTTPRequestBuffer(_ data: Data) -> Bool {
        if data.count > maxRequestBytes {
            return true
        }
        if let expectedLength = completeHTTPRequestLength(data), expectedLength > maxRequestBytes {
            return true
        }
        return false
    }

    private static func http(status: String) -> String {
        """
        HTTP/1.1 \(status)\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: POST, OPTIONS\r
        Access-Control-Allow-Headers: content-type\r
        Access-Control-Allow-Private-Network: true\r
        Content-Length: 0\r
        Connection: close\r
        \r

        """
    }
}
