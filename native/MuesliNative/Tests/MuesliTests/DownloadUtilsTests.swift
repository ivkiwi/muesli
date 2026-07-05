import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("DownloadUtils")
struct DownloadUtilsTests {

    @Test("failed move removes downloaded temp file")
    func failedMoveRemovesDownloadedTempFile() async throws {
        let tempDirectory = makeTemporaryDirectory()
        let tempURL = tempDirectory.appendingPathComponent("download.tmp")
        try Data("payload".utf8).write(to: tempURL)
        let destination = tempDirectory
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("model.bin")

        await #expect(throws: DownloadError.self) {
            try await downloadWithRetry(
                from: requestURL,
                to: destination,
                maxRetries: 1,
                download: { _ in (tempURL, okResponse) }
            )
        }

        #expect(FileManager.default.fileExists(atPath: tempURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test("successful move leaves no temp file")
    func successfulMoveLeavesNoTempFile() async throws {
        let tempDirectory = makeTemporaryDirectory()
        let tempURL = tempDirectory.appendingPathComponent("download.tmp")
        let destination = tempDirectory.appendingPathComponent("model.bin")
        try Data("payload".utf8).write(to: tempURL)

        try await downloadWithRetry(
            from: requestURL,
            to: destination,
            maxRetries: 1,
            download: { _ in (tempURL, okResponse) }
        )

        #expect(FileManager.default.fileExists(atPath: tempURL.path) == false)
        #expect(try Data(contentsOf: destination) == Data("payload".utf8))
    }

    @Test("HTTP error removes downloaded temp file")
    func httpErrorRemovesDownloadedTempFile() async throws {
        let tempDirectory = makeTemporaryDirectory()
        let tempURL = tempDirectory.appendingPathComponent("download.tmp")
        let destination = tempDirectory.appendingPathComponent("model.bin")
        try Data("payload".utf8).write(to: tempURL)

        await #expect(throws: DownloadError.self) {
            try await downloadWithRetry(
                from: requestURL,
                to: destination,
                maxRetries: 1,
                download: { _ in (tempURL, errorResponse) }
            )
        }

        #expect(FileManager.default.fileExists(atPath: tempURL.path) == false)
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
}
