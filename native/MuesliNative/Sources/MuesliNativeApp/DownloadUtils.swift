import Foundation

enum DownloadError: Error, LocalizedError {
    case httpError(Int, String)
    case retriesExhausted(String, Error)

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let path):
            return "HTTP \(code) downloading \(path)"
        case .retriesExhausted(let path, let underlying):
            return "Failed to download \(path) after retries: \(underlying.localizedDescription)"
        }
    }
}

/// Download a file with HTTP status validation, retry with exponential backoff,
/// and cleanup of partial files on failure.
func downloadWithRetry(
    from url: URL,
    to destination: URL,
    maxRetries: Int = 3,
    session: URLSession = .shared
) async throws {
    try await downloadWithRetry(
        from: url,
        to: destination,
        maxRetries: maxRetries,
        download: { try await session.download(from: $0) }
    )
}

func downloadWithRetry(
    from url: URL,
    to destination: URL,
    maxRetries: Int = 3,
    download: (URL) async throws -> (URL, URLResponse)
) async throws {
    var lastError: Error?
    for attempt in 0..<maxRetries {
        if attempt > 0 {
            let delay = UInt64(pow(2.0, Double(attempt - 1))) * 1_000_000_000
            try? await Task.sleep(nanoseconds: delay)
            fputs("[download] retry \(attempt)/\(maxRetries) for \(url.lastPathComponent)\n", stderr)
        }
        do {
            try Task.checkCancellation()
            let (tempURL, response) = try await download(url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                try? FileManager.default.removeItem(at: tempURL)
                throw DownloadError.httpError(code, url.lastPathComponent)
            }
            try moveDownloadedTemporaryFile(tempURL, to: destination)
            return
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error
        }
    }
    let underlying = lastError ?? NSError(domain: "DownloadError", code: 0, userInfo: [
        NSLocalizedDescriptionKey: "No download attempts were made",
    ])
    throw DownloadError.retriesExhausted(url.lastPathComponent, underlying)
}

func moveDownloadedTemporaryFile(_ tempURL: URL, to destination: URL) throws {
    var movedToDestination = false
    defer {
        if !movedToDestination {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: tempURL, to: destination)
    movedToDestination = true
}
