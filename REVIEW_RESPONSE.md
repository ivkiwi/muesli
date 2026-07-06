Ready-to-post reply:

Fixed. `migrateLegacyWAVRecordings` now isolates `deleteOrphanedWAVStubs` failures: if the orphan sweep cannot list the recordings directory, it logs that sweep failure, reports `deletedOrphanStubs = 0`, and still returns the migrated count so `startLegacyRecordingMigration` reaches `MuesliNotifications.postDataDidChange()`.

Added regression coverage with an injected `FileManager` whose `contentsOfDirectory` throws for the recordings directory. The test proves a successful WAV-to-M4A migration returns `migrated == 1`, reports `deletedOrphanStubs == 0`, and does not throw.

Validated with `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-prwav --filter MeetingRecordingWriterTests` and `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-prwav`.
