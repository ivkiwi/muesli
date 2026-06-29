import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("MeetingMarkdownAutoExporter")
struct MeetingMarkdownAutoExporterTests {

    @Test("disabled config writes nothing")
    func disabledIsNoOp() async throws {
        let support = makeTemporaryDirectory()
        let destination = makeTemporaryDirectory()
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)
        var config = AppConfig()
        config.autoExportMarkdownEnabled = false
        config.autoExportMarkdownFolderPath = destination.path

        exporter.exportIfConfigured(meeting: makeMeeting(), config: config)

        #expect(FileManager.default.fileExists(atPath: exporter.logURL.path) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test("empty folder path logs skipped and writes nothing")
    func emptyFolderLogsSkipped() throws {
        let support = makeTemporaryDirectory()
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)
        var config = AppConfig()
        config.autoExportMarkdownEnabled = true
        config.autoExportMarkdownFolderPath = "   "

        let result = exporter.performExport(meeting: makeMeeting(), config: config)

        #expect(result == nil)
        let log = try String(contentsOf: exporter.logURL, encoding: .utf8)
        #expect(log.contains("no destination folder configured"))
    }

    @Test("relative folder path is rejected")
    func relativePathRejected() throws {
        let support = makeTemporaryDirectory()
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)
        var config = AppConfig()
        config.autoExportMarkdownEnabled = true
        config.autoExportMarkdownFolderPath = "relative/notes"

        let result = exporter.performExport(meeting: makeMeeting(), config: config)

        #expect(result == nil)
        let log = try String(contentsOf: exporter.logURL, encoding: .utf8)
        #expect(log.contains("must be an absolute path"))
    }

    @Test("writes notes markdown file to destination folder")
    func writesNotesFile() throws {
        let support = makeTemporaryDirectory()
        let destination = makeTemporaryDirectory()
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)
        var config = AppConfig()
        config.autoExportMarkdownEnabled = true
        config.autoExportMarkdownFolderPath = destination.path

        let url = exporter.performExport(meeting: makeMeeting(), config: config)

        let written = try #require(url)
        #expect(written.pathExtension == "md")
        let contents = try String(contentsOf: written, encoding: .utf8)
        #expect(contents.contains("# Weekly Standup"))
        #expect(contents.contains("## Key Points"))
        #expect(contents.contains("Ship export feature"))
    }

    @Test("filename includes date prefix and -notes suffix")
    func filenameHasDatePrefix() throws {
        let support = makeTemporaryDirectory()
        let destination = makeTemporaryDirectory()
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)
        var config = AppConfig()
        config.autoExportMarkdownEnabled = true
        config.autoExportMarkdownFolderPath = destination.path

        let url = try #require(exporter.performExport(meeting: makeMeeting(), config: config))

        #expect(url.lastPathComponent == "2026-04-14-weekly-standup-notes.md")
    }

    @Test("transcript content option exports raw transcript")
    func transcriptContentOption() throws {
        let support = makeTemporaryDirectory()
        let destination = makeTemporaryDirectory()
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)
        var config = AppConfig()
        config.autoExportMarkdownEnabled = true
        config.autoExportMarkdownFolderPath = destination.path
        config.autoExportMarkdownContent = MeetingExportContent.transcript.rawValue

        let url = try #require(exporter.performExport(meeting: makeMeeting(), config: config))

        #expect(url.lastPathComponent.hasSuffix("-transcript.md"))
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("## Raw Transcript"))
        #expect(contents.contains("Hello everyone"))
    }

    @Test("repeated exports do not overwrite, append numeric suffix")
    func collisionAppendsSuffix() throws {
        let support = makeTemporaryDirectory()
        let destination = makeTemporaryDirectory()
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)
        var config = AppConfig()
        config.autoExportMarkdownEnabled = true
        config.autoExportMarkdownFolderPath = destination.path

        let first = try #require(exporter.performExport(meeting: makeMeeting(), config: config))
        let second = try #require(exporter.performExport(meeting: makeMeeting(), config: config))

        #expect(first.lastPathComponent == "2026-04-14-weekly-standup-notes.md")
        #expect(second.lastPathComponent == "2026-04-14-weekly-standup-notes-2.md")
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test("creates destination folder when missing")
    func createsMissingFolder() throws {
        let support = makeTemporaryDirectory()
        let destination = makeTemporaryDirectory().appendingPathComponent("nested/notes", isDirectory: true)
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)
        var config = AppConfig()
        config.autoExportMarkdownEnabled = true
        config.autoExportMarkdownFolderPath = destination.path

        let url = try #require(exporter.performExport(meeting: makeMeeting(), config: config))

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.deletingLastPathComponent().path == destination.standardizedFileURL.path)
    }

    // MARK: - Helpers

    private func makeMeeting(
        title: String = "Weekly Standup",
        startTime: String = "2026-04-14T10:00:00",
        rawTranscript: String = "[00:00:05] You: Hello everyone\n[00:00:10] Speaker 1: Hi there",
        formattedNotes: String = "## Key Points\n\n- Discussed roadmap\n- **Action item:** Ship export feature"
    ) -> MeetingRecord {
        MeetingRecord(
            id: 1,
            title: title,
            startTime: startTime,
            durationSeconds: 1800,
            rawTranscript: rawTranscript,
            formattedNotes: formattedNotes,
            wordCount: 42,
            folderID: nil,
            selectedTemplateName: "Default",
            selectedTemplateKind: .builtin
        )
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("markdown-auto-export-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
