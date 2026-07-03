## 2026-07-03 15:33 +03 - C1 imported audio transcript cleanup

- Status: complete.
- Change: imported audio now runs `MeetingTranscriptCleanupPipeline.cleanIfNeeded` after diarization and before title/summary/persist. Cleaned transcript feeds title generation, summary generation, stored `raw_transcript`, and import result.
- Preservation: successful cleanup stores the pre-cleanup transcript in `raw_original_transcript`; cleanup failures keep raw transcript and store no original, matching live meeting fallback semantics.
- Tests:
  - `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-settings --filter AudioFileImportControllerTests` - passed, 16 tests.
  - `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-settings` - passed, 1208 tests / 131 suites.
  - `git diff --check` - passed.
- Deviations: `CODEX_PLAN.md` was not present in this worktree root; read-only C1 plan source came from sibling `../muesli/CODEX_PLAN.md`. No files outside this worktree were changed.
