import Foundation
import Network

struct MeetSpeakerObservation: Equatable, Sendable {
    let meetingURL: String?
    let speakerName: String?
    let participants: [MeetingParticipant]
    let observedAt: Date
    let source: String
}

final class MeetSpeakerBridgeServer {
    static let port: NWEndpoint.Port = 1477
    static let path = "/v1/meet-speaker"

    private var listener: NWListener?
    var onObservation: ((MeetSpeakerObservation) -> Void)?

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: Self.port)
        guard let listener = try? NWListener(using: params) else {
            fputs("[meet-speaker] failed to start bridge on 127.0.0.1:\(Self.port)\n", stderr)
            return
        }

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                guard let self else {
                    connection.cancel()
                    return
                }
                let response = self.handle(data)
                connection.send(
                    content: response.data(using: .utf8),
                    completion: .contentProcessed { _ in connection.cancel() }
                )
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                fputs("[meet-speaker] bridge failed: \(error)\n", stderr)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
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
        guard let body = Self.bodyData(from: data),
              let observation = Self.parseObservation(body) else {
            return Self.http(status: "400 Bad Request")
        }
        onObservation?(observation)
        return Self.http(status: "204 No Content")
    }

    static func parseObservation(_ data: Data) -> MeetSpeakerObservation? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let rawName = json["speakerName"] as? String ?? json["speaker"] as? String
        let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let speakerName = (name?.count ?? 0) >= 2 && (name?.count ?? 0) <= 120 ? name : nil
        let participants = parseParticipants(json["participants"])
        guard speakerName != nil || !participants.isEmpty else { return nil }
        let source = (json["source"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let meetingURL = (json["meetingURL"] as? String ?? json["meetingUrl"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetSpeakerObservation(
            meetingURL: meetingURL?.isEmpty == true ? nil : meetingURL,
            speakerName: speakerName,
            participants: participants,
            observedAt: Date(),
            source: source?.isEmpty == false ? source! : "meet-extension"
        )
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

    private static func bodyData(from data: Data) -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else { return nil }
        return data[range.upperBound...]
    }

    private static func http(status: String) -> String {
        """
        HTTP/1.1 \(status)\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: POST, OPTIONS\r
        Access-Control-Allow-Headers: content-type\r
        Content-Length: 0\r
        Connection: close\r
        \r

        """
    }
}
