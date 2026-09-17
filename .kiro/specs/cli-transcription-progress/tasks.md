# Tasks: CLI Transcription Progress

Branch: `sebsto/cli-transcription-progress`
Worktree: `/Users/sst/code/swift/mac/wispr-cli-progress`

## 1. WisprCore — reporting plumbing (additive only)

- [x] 1.1 New `Sources/WisprCore/Services/ProgressUpdate.swift`: `ProgressUpdate`
      struct + handler typealiases.
- [x] 1.2 `TranscriptionEngine`: add `transcribe(_:language:onProgress:)`
      requirement + default implementation forwarding to the existing method.
- [x] 1.3 `CompositeTranscriptionEngine`: forward the new overload to the active
      engine.
- [x] 1.4 `WhisperService`: implement the overload using `segmentCallback` for
      position/text and `callback` for liveness; existing 2-arg method becomes a
      forwarder.
- [x] 1.5 `ParakeetService`: implement the overload by draining
      `transcriptionProgressStream` in a child task; cancel on exit.
- [x] 1.6 `AudioFileDecoder.decode`: add defaulted `onProgress` reporting decoded
      sample count, throttled to ~0.25 s of audio.
- [x] 1.7 Verify `swift build` and that no file under `Sources/WisprApp/` was
      modified.

## 2. WisprCLI — reporter and renderer

- [x] 2.1 New `Sources/WisprCLI/DurationFormat.swift`: `formatDuration`,
      `formatClock`, plus `Duration.seconds`.
- [x] 2.2 New `Sources/WisprCLI/ProgressReporter.swift`: phases, actor state,
      `AsyncStream(bufferingNewest: 1)` event intake, 100 ms ticker, render task,
      EMA speed + ETA, monotonic clamping.
- [x] 2.3 Renderer styles: interactive (ANSI single line, `TIOCGWINSZ` width,
      `NO_COLOR`/`TERM=dumb` handling, graceful narrowing), plain lines, silent.
- [x] 2.4 Signal handling: `DispatchSourceSignal` for SIGINT/SIGTERM restoring the
      cursor, then re-raise with default disposition.

## 3. WisprCLI — wiring

- [x] 3.1 Route progress output to the saved fd; TTY detection against it.
- [x] 3.2 Add `--progress <auto|always|never>` (+ `WISPR_PROGRESS`) and `--quiet`;
      resolve the effective style. `--quiet` beats `--progress always`.
- [x] 3.3 Wrap the three phases in `begin`/`endPhase`; pass the reporter's handler
      into `decoder.decode` and `engine.transcribe`.
- [x] 3.4 `finish()` on both exits so the line is erased before transcript or
      error output.
- [x] 3.5 Replace the raw `Duration` / sample-count lines with the formatted ones.

## 4. Verification

- [x] 4.1 Unit tests in `wisprTests` (11 tests, 3 suites) for `ProgressUpdate`,
      the protocol default implementation, and composite forwarding.
- [x] 4.2 `swift build` clean; full suite run and compared against `main`.
- [x] 4.3 Transcript diffed against `main`'s output on a 37 min file — byte
      identical, proving R6.2.
- [x] 4.4 Mode matrix: TTY via pty, `2>file`, `--quiet`, `--progress never`,
      `--verbose`, `WISPR_PROGRESS=always`.
- [x] 4.5 App source confirmed untouched.

## Review

### Deviations from the design

- The handler typealias is `TranscriptionProgressHandler`, not `ProgressHandler`:
  FluidAudio exports its own `ProgressHandler` (for download progress) which
  `ParakeetService` already uses, so the short name shadowed it and broke the
  build. Same reasoning that already applied to `ProgressUpdate` vs WhisperKit's
  `TranscriptionProgress`.
- Bar width is computed from the space actually left after the other fields,
  rather than the design's fixed 62-column reserve. The fixed reserve was too
  small and truncated ETA and speed away at ~89 columns.
- Status lines (`Using model:`) are gated on a separate `logsEnabled` flag rather
  than on the progress style. Gating them on style silently dropped the line in
  non-TTY runs, which would have been a regression against previous behaviour.

### Bugs found and fixed during verification

- Plain-line throttle: the phase-start line set `lastPlainEmit` while the
  fraction was still nil, and the delta rule required a previous non-nil
  fraction, so percentage lines were suppressed until the 5 s timer. A phase
  finishing inside 5 s reported 0% and nothing else. A first-ever fraction now
  counts as a reportable change.
- `Duration` has no `Double` conversion in the stdlib; added `Duration.seconds`.

### Verified

- 37 min file: transcript byte-identical to `main` (40 830 bytes both sides).
- Interactive pty capture: 1 hide-cursor / 1 matching show-cursor, 57 in-place
  redraws, exactly 1 newline in the whole progress region, no truncated frames.
- Whisper's progress path is implemented against WhisperKit's documented
  callbacks but was **not** run end-to-end: only `parakeet-v3` is downloaded on
  this machine. The Parakeet path is exercised for real.
- Pre-existing flake, unrelated to this change: "AudioEngine audio level stream
  terminates on stop" fails under full-suite load on `main` as well, and passes
  in isolation on both branches.
