# GigaAM Live Overlap Verification Log

Date: 2026-07-03
Branch: `verify/live-gigaam-path`

## Confirmed Working

- Meeting backend selection is separate from dictation backend selection. `MuesliController.startMeetingRecording` resolves `meetingTranscriptionBackend` through `normalizeMeetingTranscriptionSelectionForAvailability()`, passes that `backend` into `MeetingSession`, and `MeetingSession` computes `liveChunkingConfiguration` from that backend.
- GigaAM live chunking config is `minChunkDuration = 3.0`, `maxChunkDuration = 20.0`, `overlapSampleCount = 32_000`, `deduplicatesText = true`. Non-GigaAM keeps `3.0` / `5.0`, `overlapSampleCount = 0`, `deduplicatesText = false`.
- Both live mic and system `PCMChunkRecorder` instances are constructed with `liveChunkingConfiguration.overlapSampleCount`.
- Both live mic and system `StreamingVadController` instances are constructed with `liveChunkingConfiguration.minChunkDuration` and `.maxChunkDuration`, so the `StreamingVadController` convenience default of `5.0` is not used by the live GigaAM meeting path.
- Live overlap text dedup is gated by `MeetingSession.liveChunkingConfiguration(for: backend).deduplicatesText` and keyed by `meetingID|speaker`, so mic (`You`) and system (`Others`) tracks deduplicate separately.
- Final transcript assembly at stop sorts mic and system segments by start time before reconciliation, then applies `TranscriptOverlapMerger.deduplicateSegments` separately to mic and system tracks for GigaAM.
- `PCMChunkRecorder` carries the configured tail into the next WAV. Synthetic 20s / 20s / short trailing rotations proved `tail(file N) == head(file N+1)` for exactly 32,000 samples across multiple rotations. The `freshBytesWritten` guard preserves a short final chunk with fresh samples and drops only carryover-only chunks.

## Fixed

- Live chunk callbacks were completion-order. `MeetingChunkCollector` registered chunks in order, but watcher tasks called `onChunkTranscribed` as soon as each async transcription completed. That could make live captions and live checkpoints interleave when chunk N+1 finished before chunk N. Final stop output was sorted, but live display/checkpoint append was not.
- Fix: `MeetingChunkCollector.retire` now buffers completed chunks by registration sequence and releases only the next contiguous sequence. Empty chunks still advance the sequence, so later non-empty chunks do not stall behind silent chunks. Mic and system collectors remain independent.
- The live checkpoint formatting/dedup logic was extracted into `LiveTranscriptCheckpointAssembler` so tests cover the exact append-path dedup behavior without launching the AppKit controller.

## Broken / Unfixable

- None found.

## Validation

- Passed targeted suite:
  `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-tests --filter 'MeetingLiveOverlapPipelineTests|PCMChunkRecorderTests|StreamingVadControllerTests|QoLTests/gigaAMMeetingChunkingPolicy|QoLTests/collector|TranscriptionRuntimeTests/sharedOverlapMergerUniqueSuffix'`
- Targeted result: 17 Swift Testing tests passed.
- Passed full suite:
  `swift test --package-path native/MuesliNative --scratch-path /private/tmp/muesli-spm-tests`
- Full result: 1261 Swift Testing tests passed.
