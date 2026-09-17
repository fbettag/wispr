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

## Review round 2 — reviewer feedback

13 threads. Implemented 9, dismissed 3 as factually incorrect, 1 partially.

### Implemented

- **Xcode registration (blocking).** `WisprCore`/`WisprCLI` list sources
  explicitly in `project.pbxproj`; only the test targets are synchronized
  groups. The three new files were invisible to `xcodebuild`. Added the four
  entries per file. `build-xcode` green.
- **Stale-event race.** Event intake is asynchronous, so the decoder's final
  report — a position equal to the whole audio length — could be applied *after*
  `begin(.transcribing)` reset the state, pinning the bar at 100% and making the
  monotonic clamp reject every real engine update for the rest of the run.
  Events now carry the generation of the phase that produced them and stale ones
  are dropped. Regression test:
  `staleEventFromPreviousPhaseIsDropped`.
- **No per-token cost when progress is off.** The handler factories return nil
  when the style is `.silent`, so the engines build nil backend callbacks and
  WhisperKit does no per-token work at all. A no-op closure would still have
  cost a call per token.
- **`--quiet` now beats `--verbose`.** Gated the `Models root:` line, and — found
  while testing that fix — `--verbose` also disabled the SDK-log suppression, so
  `--quiet --verbose` emitted 20 lines of FluidAudio logging. `--quiet` is now
  authoritative for stderr. Verified byte-empty.
- **Removed the `nonisolated(unsafe)`** on the signal sources in favour of a
  `Mutex`, per the reviewer's suggestion. Write-once discipline made the
  unchecked version sound, but this costs nothing.
- **Tests for the CLI layer** (the largest gap): 33 new tests covering duration
  and clock formatting boundaries, style resolution from the flags, preference
  parsing, SDK-log suppression precedence, the reporter state machine
  (monotonic clamping, clamping to total, phase reset, generation tagging), and
  bar geometry. Required adding `WisprCLI` to the SPM test target's
  dependencies; the Xcode scheme's Build action contains only `WisprApp`, so
  `build-xcode` is unaffected.
- **Renamed `ProgressReporter` → `TerminalProgressReporter`.** Foundation ships
  its own `ProgressReporter` in the macOS 26 SDK; unambiguous inside the module
  but ambiguous from the test target. Same collision-avoidance already applied
  to `ProgressUpdate` and `TranscriptionProgressHandler`.
- **Corrected a wrong doc value.** `formatDuration(0.85)` yields `0.8s`, not
  `0.9s`: 0.85's nearest Double is below 0.85. The design table and my own test
  both claimed otherwise — the test caught it.

### Dismissed as factually incorrect

- **"`NO_COLOR=` (empty) leaves colour enabled."** It does not.
  `ProcessInfo.environment` returns `""` for a set-but-empty variable, so
  `== nil` is false and colour is disabled. Verified by direct experiment. The
  suggested replacement line was byte-identical to the existing one.
- **"`public` member on an internal type is rejected by Swift."** It is legal;
  effective access is capped at internal. Both `swift build` and `xcodebuild`
  compile it, and a standalone repro compiles.
- **"`ProgressStyle` lacks `Equatable`, so the CLI won't compile."** Enums
  without associated values are implicitly `Equatable`. Both CI build jobs were
  already green on that exact code.

### Partially implemented

- **"The 5 s non-TTY throttle violates the once-per-second requirement."** The
  inconsistency was real, but the fix was in the spec, not the code: the
  once-per-second guarantee belongs to the interactive display, where a 100 ms
  ticker drives it. The non-TTY channel is a log stream; one line per second
  would be thousands of lines for a long file. R1.1 now scopes the guarantee to
  the TTY and R1.1a states the log cadence.

### Determinism re-verified

One run during this round differed from `main` by a single word while the
737-test suite was executing concurrently. It did not reproduce: 13 subsequent
controlled runs — idle, 4-way concurrent, during the full test suite, and with
progress fully enabled (`--verbose --progress always`, pump task active) — are
all byte-identical to `main` (md5 `5fb684d7…`, 40 830 bytes), on both branches.
Not attributable to this change, and not reproducible.
