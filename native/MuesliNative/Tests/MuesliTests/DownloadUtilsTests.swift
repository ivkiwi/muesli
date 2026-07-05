import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("DownloadUtils")
struct DownloadUtilsTests {

    @Test("failed move removes downloaded temp file")
    func failedMoveRemovesDownloadedTempFile() async throws {
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let destination = tempDirectory
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("model.bin")

        await #expect(throws: DownloadError.self) {
            try await downloadWithRetry(
                from: requestURL,
                to: destination,
                maxRetries: 1,
                download: downloadPayload(in: tempDirectory, response: okResponse)
            )
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test("successful move leaves no temp file")
    func successfulMoveLeavesNoTempFile() async throws {
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let destination = tempDirectory.appendingPathComponent("model.bin")

        try await downloadWithRetry(
            from: requestURL,
            to: destination,
            maxRetries: 1,
            download: downloadPayload(in: tempDirectory, response: okResponse)
        )

        #expect(try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path) == ["model.bin"])
        #expect(try Data(contentsOf: destination) == Data("payload".utf8))
    }

    @Test("HTTP error removes downloaded temp file")
    func httpErrorRemovesDownloadedTempFile() async throws {
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let destination = tempDirectory.appendingPathComponent("model.bin")

        await #expect(throws: DownloadError.self) {
            try await downloadWithRetry(
                from: requestURL,
                to: destination,
                maxRetries: 1,
                download: downloadPayload(in: tempDirectory, response: errorResponse)
            )
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    private var requestURL: URL {
        URL(string: "https://example.com/model.bin")!
    }

    private var okResponse: HTTPURLResponse {
        HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    private var errorResponse: HTTPURLResponse {
        HTTPURLResponse(url: requestURL, statusCode: 500, httpVersion: nil, headerFields: nil)!
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-utils-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func downloadPayload(
        in directory: URL,
        response: HTTPURLResponse
    ) -> (URL) async throws -> (URL, URLResponse) {
        { _ in
            let tempURL = directory.appendingPathComponent("download-\(UUID().uuidString).tmp")
            try Data("payload".utf8).write(to: tempURL)
            return (tempURL, response)
        }
    }
}
