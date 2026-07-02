import Foundation
import MuesliCore
import Darwin
import os

/// Automatically writes a Markdown file for a completed meeting to a
/// user-configured folder. Mirrors the meeting-hook dispatch pattern: all work
/// runs off the main thread so persisting a meeting never blocks the UI.
protocol MeetingMarkdownAutoExporting {
    func exportIfConfigured(meeting: MeetingRecord, config: AppConfig)
    func recordMeetingLookupFailure(meetingID: Int64, error: Error?)
}

final class MeetingMarkdownAutoExporter: MeetingMarkdownAutoExporting {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MarkdownAutoExport")

    private let supportDirectory: URL
    private let fileManager: FileManager
    private let logQueue = DispatchQueue(label: "com.muesli.native.markdown-auto-export-log")
    private let dateProvider: () -> Date

    init(
        supportDirectory: URL = AppIdentity.supportDirectoryURL,
        fileManager: FileManager = .default,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.supportDirectory = supportDirectory
        self.fileManager = fileManager
        self.dateProvider = dateProvider
    }

    var logURL: URL {
        supportDirectory.appendingPathComponent("meeting-markdown-export.log")
    }

    func exportIfConfigured(meeting: MeetingRecord, config: AppConfig) {
        guard config.autoExportMarkdownEnabled else { return }
        Task.detached(priority: .utility) { [self] in
            performExport(meeting: meeting, config: config)
        }
    }

    func recordMeetingLookupFailure(meetingID: Int64, error: Error?) {
        if let error {
            writeLog("export failed: could not load persisted meeting id=\(meetingID) error=\(error.localizedDescription)")
        } else {
            writeLog("export failed: persisted meeting not found id=\(meetingID)")
        }
    }

    /// Builds the Markdown and writes it to disk. Returns the written URL on
    /// success (exposed for testing); logs and returns nil on any failure.
    @discardableResult
    func performExport(meeting: MeetingRecord, config: AppConfig) -> URL? {
        let trimmedFolder = config.autoExportMarkdownFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFolder.isEmpty else {
            writeLog("skipped: auto-export enabled but no destination folder configured")
            return nil
        }
        guard NSString(string: trimmedFolder).isAbsolutePath else {
            writeLog("skipped: destination folder must be an absolute path path=\(trimmedFolder)")
            return nil
        }

        let folderURL = URL(fileURLWithPath: trimmedFolder, isDirectory: true)
        do {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            writeLog("export failed: could not create destination folder path=\(folderURL.path) error=\(error.localizedDescription)")
            return nil
        }

        let content = config.resolvedAutoExportMarkdownContent
        let markdown = MeetingExporter.buildMarkdown(meeting: meeting, content: content)

        do {
            let destinationURL = try writeMarkdown(markdown, in: folderURL, meeting: meeting, content: content)
            writeLog("exported: id=\(meeting.id) path=\(destinationURL.path)")
            return destinationURL
        } catch {
            writeLog("export failed: id=\(meeting.id) error=\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Filename

    private func writeMarkdown(
        _ markdown: String,
        in folder: URL,
        meeting: MeetingRecord,
        content: MeetingExportContent
    ) throws -> URL {
        let baseName = baseFilename(meeting: meeting, content: content)
        let data = Data(markdown.utf8)
        let firstCandidate = folder.appendingPathComponent("\(baseName).md")
        if try write(data, toNewFileAt: firstCandidate) {
            return firstCandidate
        }

        for index in 2...Self.maxCollisionAttempts {
            let candidate = folder.appendingPathComponent("\(baseName)-\(index).md")
            if try write(data, toNewFileAt: candidate) {
                return candidate
            }
        }

        // Degenerate case (folder saturated with the same base name): fall back to
        // a UUID-suffixed name so we never overwrite and never loop unbounded.
        let fallback = folder.appendingPathComponent("\(baseName)-\(UUID().uuidString).md")
        guard try write(data, toNewFileAt: fallback) else {
            throw CocoaError(.fileWriteFileExists)
        }
        return fallback
    }

    /// Atomically reserves a path before writing so concurrent exports cannot
    /// choose the same destination after a preflight existence check.
    private func write(_ data: Data, toNewFileAt url: URL) throws -> Bool {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard descriptor >= 0 else {
            if errno == EEXIST { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            return true
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    private static let maxCollisionAttempts = 1000

    private func baseFilename(meeting: MeetingRecord, content: MeetingExportContent) -> String {
        let filename = MeetingExporter.suggestedFilename(meeting: meeting, content: content, fileExtension: "md")
        let stem = (filename as NSString).deletingPathExtension
        if let datePrefix = Self.datePrefix(from: meeting.startTime) {
            return "\(datePrefix)-\(stem)"
        }
        return stem
    }

    private static func datePrefix(from startTime: String) -> String? {
        guard let date = MeetingBrowserLogic.parseDate(startTime) else { return nil }
        return fileDateFormatter.string(from: date)
    }

    // MARK: - Logging

    /// Blocks until all queued log writes have drained. Intended for tests that
    /// assert on log file contents after a synchronous `performExport` call.
    func waitForPendingLogWrites() {
        logQueue.sync {}
    }

    private func writeLog(_ message: String) {
        let line = "[\(Self.isoFormatter.string(from: dateProvider()))] \(message)\n"
        Self.logger.log("\(line, privacy: .private)")

        logQueue.async { [self] in
            do {
                try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
                if !fileManager.fileExists(atPath: logURL.path) {
                    guard fileManager.createFile(atPath: logURL.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                fputs("[markdown-auto-export] log write failed: \(error)\n", stderr)
            }
        }
    }

    // MARK: - Formatters

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
