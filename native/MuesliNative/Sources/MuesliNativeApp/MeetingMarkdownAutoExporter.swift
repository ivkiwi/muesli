import Foundation
import MuesliCore
import os

/// Automatically writes a Markdown file for a completed meeting to a
/// user-configured folder. Mirrors the meeting-hook dispatch pattern: all work
/// runs off the main thread so persisting a meeting never blocks the UI.
protocol MeetingMarkdownAutoExporting {
    func exportIfConfigured(meeting: MeetingRecord, config: AppConfig)
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
        let destinationURL = uniqueDestinationURL(in: folderURL, meeting: meeting, content: content)

        do {
            try markdown.write(to: destinationURL, atomically: true, encoding: .utf8)
            writeLog("exported: id=\(meeting.id) path=\(destinationURL.path)")
            return destinationURL
        } catch {
            writeLog("export failed: id=\(meeting.id) path=\(destinationURL.path) error=\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Filename

    /// Returns a non-colliding `.md` URL in the destination folder. The base
    /// name is a date prefix plus the sanitized meeting title; subsequent
    /// collisions get a numeric suffix so previously exported notes are never
    /// overwritten.
    func uniqueDestinationURL(in folder: URL, meeting: MeetingRecord, content: MeetingExportContent) -> URL {
        let baseName = baseFilename(meeting: meeting, content: content)
        let firstCandidate = folder.appendingPathComponent("\(baseName).md")
        if !fileManager.fileExists(atPath: firstCandidate.path) {
            return firstCandidate
        }
        var index = 2
        while true {
            let candidate = folder.appendingPathComponent("\(baseName)-\(index).md")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

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

    private func writeLog(_ message: String) {
        let line = "[\(Self.isoFormatter.string(from: dateProvider()))] \(message)\n"
        Self.logger.log("\(line, privacy: .public)")

        logQueue.sync {
            do {
                try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
                if !fileManager.fileExists(atPath: logURL.path) {
                    fileManager.createFile(atPath: logURL.path, contents: nil)
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
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
