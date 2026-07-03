# Lane log

## 2026-07-03 - B2 upstream PR #235 auto-record wake timers

- Branch/worktree: `codex/lane-controller` in `/Users/kiwi/Projects/muesli-lane-controller`.
- What changed: adopted PR #235 behavior for per-event auto-record wake timers, 5-minute auto-record catch-up, shared auto-record dedup/start helper, and Teams Safe Links URL extraction.
- Why: auto-record previously depended on launch/event-change checks plus a 60s timer that App Nap can suspend, so later meetings could miss the 90s start window.
- Fork reconciliation: kept fork `startOrigin: .calendarAutoRecord` when moving auto-record start into the shared helper; fork calendar-window code from `0804d794` remained intact.
- Targeted tests: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-controller --filter 'MeetingNotificationController|GoogleCalendarTests'` passed, 43 tests.
- Full suite: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-controller` passed, 1210 tests; no PasteController/StreamingVadController flake rerun needed.
- Hygiene: `git diff --check` passed.
- Note: `CODEX_PLAN.md` was absent in this worktree root; B2 scope was confirmed from user prompt plus read-only sibling plan at `../muesli/CODEX_PLAN.md`.

## 2026-07-03 - C3 cancel starting-now timers from prompt actions

- Branch/worktree: `codex/lane-controller` in `/Users/kiwi/Projects/muesli-lane-controller`.
- What changed: scheduled meeting prompt `Record` and `Join & Record` actions now cancel their pending `Meeting starting now` timer through `cancelMeetingStartingNowTimer(notificationKey:)`, matching existing `Join Only` and dismiss behavior.
- Why: if recording ends before the scheduled event start, or Join & Record fails to reach recording, the old timer could still fire a redundant stale starting-now prompt.
- Targeted tests: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-controller --filter 'MeetingNotificationController|GoogleCalendarTests'` passed, 44 tests.
- Full suite: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-controller` passed, 1211 tests; no PasteController/StreamingVadController flake rerun needed.
- Hygiene: `git diff --check` passed.

## 2026-07-03 - C4 startup temp sweep for app temp dirs

- Branch/worktree: `codex/lane-controller` in `/Users/kiwi/Projects/muesli-lane-controller`.
- What changed: added one `AppTemporaryDirectories` registry/sweeper, wired launch cleanup through it, repointed temp directory producers to shared names, and removed dead `guesli-retranscription` cleanup.
- Why: crash/SIGKILL could leave old app-owned temp files in dictation, meeting mic, import, WAV, retained-recording, and PCM chunk dirs; launch now deletes only entries older than 1h to avoid racing live work.
- Targeted tests: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-controller --filter AppTemporaryDirectories` passed, 2 tests.
- Full suite: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-controller` passed, 1213 tests; no PasteController/StreamingVadController flake rerun needed.
- Hygiene: `git diff --check` passed.

## 2026-07-03 - C5 waveform cache hygiene

- Branch/worktree: `codex/lane-controller` in `/Users/kiwi/Projects/muesli-lane-controller`.
- What changed: clear meeting history now removes the waveform cache directory before deleting saved recordings, startup now sweeps stale `.mwf` cache entries, and cache reads refresh `.mwf` modification time for simple LRU-style age eviction.
- Why: bulk history clear removed recordings but left waveform cache files, and hash keys include file size/mtime so re-encoded recordings strand old `.mwf` files without a source path to inspect.
- Targeted tests: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-controller --filter clearMeetingHistoryRemovesSavedRecordingsAndWaveformCache` passed, 1 test; `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-controller --filter RecordingWaveformCacheFiles` passed, 1 test.
- Full suite: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-controller` passed, 1215 tests; no PasteController/StreamingVadController flake rerun needed.
- Hygiene: `git diff --check` passed.
- Intended commit subject: `Clean up stale waveform cache files`.

## 2026-07-03 - PR #228 selectable dictation text

- Branch/worktree: `codex/lane-controller` in `/Users/kiwi/Projects/muesli-lane-controller`.
- What changed: adopted upstream PR #228 in `DictationRowView`; dictation text is selectable, and row-level tap-to-copy/expand was removed so selection gestures are not intercepted.
- Fork reconciliation: no Guesli-specific rename needed; `SettingsView.swift` and `ConfigStore.swift` untouched.
- Targeted tests: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-controller --list-tests | rg -i "DictationRowView|DictationsView|SearchResultsView|View"` found no row/view UI tests; `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-controller --filter Dictation` passed, 220 tests.
- Full suite: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-controller` passed, 1215 tests; no PasteController/StreamingVadController flake rerun needed.
- Hygiene: `git diff --check` passed.
- Intended commit subject: `Enable dictation text selection`.
# LANE_LOG

## 2026-07-03 - D2 PDF export off main thread

- Status: complete on `codex/lane-summary`.
- AppKit check: Apple thread-safety guidance marks `NSView` descendants as main-thread-only and `NSAttributedString` as generally thread-safe, so the PDF path no longer uses `NSTextView`/`NSPrintOperation`.
- What changed: manual export now presents `NSSavePanel` on main, then builds Markdown, attributed text, pagination, and PDF bytes on a user-initiated background queue. `MeetingMarkdownAutoExporter` reuses the same off-main shared writer instead of wrapping it in `MainActor.run`.
- PDF renderer: replaced synchronous print operation with Core Text pagination into a `CGContext` PDF, preserving the manual attributed-string builder and avoiding `NSAttributedString(html:)`.
- Targeted tests:
  - `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-summary --filter MeetingExporterTests` passed, 24 tests.
  - `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-summary --filter 'MeetingExporterTests|MeetingMarkdownAutoExporterTests'` passed, 36 tests.
- Full suite: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-summary` passed, 1225 tests in 132 suites.
- Flaky note: `PasteController` and `StreamingVadController` passed in the full suite; no quiet rerun needed.

## 2026-07-03 - B4 upstream meeting auto-export

- Status: complete on `codex/lane-summary`.
- Source: `git fetch origin`; inspected Muesli-HQ/muesli PR #263 merge `9a91db7c` and commits `c7ccc280`, `d0a83d63`, `ab9f14a7`, `da605806`, `ae5745b6`.
- Cherry-pick: `git cherry-pick -x c7ccc280` conflicted in `Models.swift` and `SettingsView.swift`; aborted and manually reapplied the merged upstream behavior.
- What changed: added `MeetingMarkdownAutoExporter` to auto-export completed meeting notes as Markdown and optional PDF to a configured folder, reusing existing `MeetingExporter` markdown/PDF rendering.
- Guesli adaptation: exporter defaults to `AppIdentity.supportDirectoryURL`, uses a Guesli bundle-id fallback for unified logging, and Settings copy/path behavior stays fork-local.
- Targeted tests:
  - `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-summary --filter MeetingMarkdownAutoExporterTests` passed, 12 tests.
  - `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-summary --filter 'MeetingHookIntegrationTests|MeetingExporterTests|AppConfig'` passed, 71 tests.
- Full suite: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-summary` passed, 1224 tests in 132 suites.
- Diff check: `git diff --check` passed.
- Flaky note: `PasteController` and `StreamingVadController` passed in the full suite; no quiet rerun needed.

## 2026-07-03 - D1 token-budget meeting summary prompt

- Status: complete on `codex/lane-summary`.
- What changed: `MeetingSummaryClient.summaryUserPrompt` now sends a bounded transcript slice through the shared prompt path used by ChatGPT OAuth, OpenAI, OpenRouter, Ollama, LM Studio, and Custom LLM.
- Budgeting: reused the existing `transcriptChunks` splitter and the transcript-cleanup 24k character budget; long transcripts keep opening and closing sections with an explicit `[Transcript truncated: middle omitted...]` marker.
- Choice: picked middle truncation instead of map-reduce because it is deterministic, adds no extra backend calls, and composes with the existing summary retry wrapper by rebuilding the same bounded prompt on each retry.
- Targeted tests:
  - `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-summary --filter MeetingSummaryClientTests` passed, 41 tests.
- Full suite: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-summary` passed, 1211 tests in 131 suites.
- Flaky note: `PasteController` and `StreamingVadController` passed in the full suite; no quiet rerun needed.

## 2026-07-03 - B5 #236 summary retries

- Status: complete on `codex/lane-summary`.
- Source: `gh pr diff 236 -R Muesli-HQ/muesli`; `CODEX_PLAN.md` was absent in this worktree, so `CODEX_PLAN_LOG.md` plus the lane prompt were used for scope.
- What changed: adopted upstream summary retry handling around `MeetingSummaryClient.summarize`, covering ChatGPT OAuth, OpenAI, OpenRouter, Ollama, LM Studio, and Custom LLM through the shared summary entry point.
- Config/UI: added persisted `meeting_summary_retry_count`, clamped to `0...10`, default `3`, with a Settings stepper.
- Permanent-error behavior: retries skip cancellation, ChatGPT auth errors, permanent URL errors, 4xx backend failures except transient `408`, `409`, `425`, and `429`, and backend failures without status.
- Targeted tests:
  - `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-summary --filter MeetingSummaryClientTests` passed, 40 tests.
  - `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-summary --filter AppConfig` passed, 42 tests.
- Full suite: `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-lane-summary` passed, 1210 tests in 131 suites.
- Diff check: `git diff --check` passed.
- Flaky note: `PasteController` and `StreamingVadController` passed in the full suite; no quiet rerun needed.
