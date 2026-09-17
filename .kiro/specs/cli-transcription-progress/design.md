# Design: CLI Transcription Progress

## Overview

Three layers, cleanly separated:

```
┌─ WisprCore (additive) ────────────────────────────────────────────┐
│  ProgressUpdate value type + optional handler on the engine APIs  │
│  WhisperService  → WhisperKit segmentCallback + token callback    │
│  ParakeetService → FluidAudio transcriptionProgressStream         │
│  AudioFileDecoder → defaulted onProgress closure                  │
└───────────────────────────────────────────────────────────────────┘
                              │  ProgressUpdate events (irregular)
                              ▼
┌─ WisprCLI ────────────────────────────────────────────────────────┐
│  ProgressReporter (actor)                                         │
│    ├── AsyncStream<Event>, .bufferingNewest(1)   ← engine events  │
│    ├── 100 ms ticker                             ← liveness       │
│    ├── state: phase, position, total, phase start, run start      │
│    └── TerminalRenderer (TTY single-line │ plain lines │ silent)  │
└───────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    real stderr fd (captured
                    before /dev/null suppression)
```

The engine only *reports*. The CLI owns all policy: throttling, formatting, ETA,
TTY detection. That keeps WisprCore free of presentation concerns and means the
app links exactly the same code it does today.

## Why the plumbing has to touch WisprCore

The progress signal exists but is unreachable from the CLI:

- `WhisperKit.progress` and the `callback` / `segmentCallback` parameters sit
  behind `WhisperService`'s private `whisperKit` field.
- `AsrManager.transcriptionProgressStream` sits behind `ParakeetService`'s
  private `asrManager` field.

Three options were considered:

| Option | Verdict |
|---|---|
| CLI calls WhisperKit/FluidAudio directly, bypassing WisprCore | Rejected. Duplicates model-path resolution, hallucination filtering, EOU handling, error mapping. Two code paths that drift. |
| Expose `whisperKit` / `asrManager` publicly and poll from the CLI | Rejected. Leaks the backend through the abstraction the protocol exists to hide, and needs a poll loop. |
| **Additive progress handler on the existing APIs** | **Selected.** One new parameter, default `nil`, real implementations in both services. |

Additive means: new overloads carrying `onProgress`, with the existing
signatures kept as thin forwarders passing `nil`. No app source changes, no test
changes, no behaviour change on the existing paths.

## WisprCore changes

### New file: `Sources/WisprCore/Services/ProgressUpdate.swift`

```swift
/// A report of how far through the audio an engine has got.
public struct ProgressUpdate: Sendable {
    /// Seconds of audio processed so far.
    public let processedSeconds: Double
    /// Total seconds of audio, when the engine knows it.
    public let totalSeconds: Double?
    /// Most recently decoded text, when the engine exposes it. Display only.
    public let textTail: String?

    public var fraction: Double? {
        guard let totalSeconds, totalSeconds > 0 else { return nil }
        return min(max(processedSeconds / totalSeconds, 0), 1)
    }
}

public typealias ProgressHandler = @Sendable (ProgressUpdate) -> Void
```

Named `ProgressUpdate`, not `TranscriptionProgress`: `WhisperService.swift`
imports WhisperKit, which already exports a `TranscriptionProgress` struct.
Avoiding the collision keeps both usable without qualification.

### `TranscriptionEngine` protocol

Add one requirement plus a default implementation, so existing conformers
(including `MockTranscriptionEngine` in the tests) keep compiling untouched:

```swift
public protocol TranscriptionEngine: Actor {
    ...
    func transcribe(
        _ audioSamples: [Float],
        language: TranscriptionLanguage,
        onProgress: ProgressHandler?
    ) async throws -> TranscriptionResult
}

extension TranscriptionEngine {
    /// Engines that don't report progress fall back to the plain call.
    public func transcribe(
        _ audioSamples: [Float],
        language: TranscriptionLanguage,
        onProgress: ProgressHandler?
    ) async throws -> TranscriptionResult {
        try await transcribe(audioSamples, language: language)
    }
}
```

`CompositeTranscriptionEngine` forwards to the active engine, mirroring its
existing `transcribe`.

### `WhisperService`

Real implementation. The existing 2-arg `transcribe` becomes a forwarder
(`onProgress: nil`), so the app path is byte-for-byte the same work it does now.

Wispr passes no `chunkingStrategy`, so WhisperKit takes the sequential
`runTranscribeTask` branch and walks 30 s windows in order. Two hooks:

- **`segmentCallback`** — fires once per completed window with
  `[TranscriptionSegment]`. `segment.end` is an absolute timestamp in seconds, so
  `processedSeconds = segments.map(\.end).max()`. This is the authoritative
  position: ~102 ticks for a 50 min file. Also supplies `textTail`.
- **`callback`** — fires per decoded token. Used only as a liveness signal
  (`windowId` → a lower bound of `Double(windowId) * 30`), and returns `nil` so
  decoding is never interrupted. Per R6.1 the closure does one comparison and one
  non-blocking `yield`; no allocation, no `await`, no `Task`.

`totalSeconds` comes from `Double(audioSamples.count) / 16000.0`, which the
method already computes for logging.

### `ParakeetService`

FluidAudio hands us a fraction directly. Before calling `asrManager.transcribe`,
grab `transcriptionProgressStream` and drain it in a child task:

```swift
let totalSeconds = Double(audioSamples.count) / 16000.0
let stream = await asrManager.transcriptionProgressStream
let pump = Task {
    for try await fraction in stream {
        onProgress(ProgressUpdate(
            processedSeconds: fraction * totalSeconds,
            totalSeconds: totalSeconds,
            textTail: nil
        ))
    }
}
defer { pump.cancel() }
```

FluidAudio only opens a session when `samples > ~15 s`, and yields `0.0` at start
and `1.0` at finish. Short clips simply produce no intermediate events, which R3.3
covers via the indeterminate fallback. `transcribeWithEou` is left alone — EOU is
a realtime path the CLI never uses.

### `AudioFileDecoder`

A defaulted parameter, which is source-compatible for the app's call sites:

```swift
public func decode(
    fileURL: URL,
    onProgress: (@Sendable (Int) -> Void)? = nil   // samples decoded so far
) async throws -> [Float]
```

Reported from the `copyNextSampleBuffer()` loop, throttled to every ~0.25 s of
appended samples so the closure isn't hit thousands of times. The CLI already has
`metadata.estimatedSampleCount` for the denominator.

## WisprCLI changes

### Fixing the stderr trap

`WisprCLI.swift:126` dups `/dev/null` over `STDERR_FILENO` for the entire run
whenever `--verbose` is absent, to silence FluidAudio's INFO logging. A spinner
written to `FileHandle.standardError` in that mode goes nowhere.

Fix: capture the real descriptor **before** suppression and hand it to the
renderer. `suppressStderr()` already returns exactly that saved fd:

```swift
let savedFd = suppressStderr()           // always suppress-and-save
let out = ProgressOutput(fd: savedFd)    // renderer writes here
```

TTY detection (`isatty`) must also happen against the saved fd, not
`STDERR_FILENO`, which by then points at `/dev/null`. In `--verbose` mode nothing
is suppressed and the renderer writes to `STDERR_FILENO` directly.

### New file: `Sources/WisprCLI/ProgressReporter.swift`

An actor. Two inputs, one output.

```swift
enum ProgressPhase { case loadingModel, decoding, transcribing }

actor ProgressReporter {
    enum Style { case interactive, plainLines, silent }

    func begin(_ phase: ProgressPhase, total: Double?)
    func update(position: Double, textTail: String? = nil)
    func endPhase()            // prints "✓ <phase> in 22.6s" when verbose
    func finish()              // erase line, restore cursor
}
```

Engine callbacks are synchronous and `@Sendable`, so they cannot `await` into the
actor. Rather than spawn a `Task` per token, the reporter exposes a
`ProgressHandler` backed by an `AsyncStream` continuation created with
`.bufferingNewest(1)`:

- `yield` is non-blocking and cheap — satisfies R6.1.
- `bufferingNewest(1)` means a burst of token events collapses to the latest one;
  no unbounded queue, no backpressure on the decoder.

A single render task consumes that stream merged with a 100 ms `ContinuousClock`
ticker, and redraws at most 10 Hz. That is what makes the display animate even
when the engine is silent for 30 s of audio (R1.4).

### Rendering

**Interactive (TTY).** One line, redrawn with `\r` + `ESC[K`. Cursor hidden with
`ESC[?25l` on start, shown again in `finish()` and from the signal handler.

```
⠋ Transcribing  ▕██████████░░░░░░░░░░░░░░▏  38%   19:23 / 50:53   elapsed 2:41   eta 4:22   11.8×
```

Indeterminate phases drop the bar and the percentage:

```
⠹ Loading model large-v3   22.4s
```

Bar width adapts to `ioctl(TIOCGWINSZ)`, clamped to 10–40 cells, and the whole
line degrades to the plain form below 60 columns. `NO_COLOR` / `TERM=dumb`
disables the ANSI styling but keeps the redraw.

**Plain lines (non-TTY, `--verbose`).** No `\r`, no escapes. Emitted on a 5 s
interval or a 5 % delta, whichever comes first:

```
[progress] transcribing 38% 19:23/50:53 elapsed 2:41 eta 4:22 11.8x
```

**Silent.** `--quiet`, `--progress never`, or non-TTY without `--verbose`.

### ETA and speed

Computed over the current phase only, from the audio position:

```
speed   = processedSeconds / phaseElapsed          // realtime factor
eta     = (totalSeconds - processedSeconds) / speed
```

Displayed speed is smoothed with an exponential moving average (α = 0.3) so a
slow window doesn't make the ETA jump. ETA is withheld until the first real
position report — no fabricated numbers.

### CLI surface

```
--progress <auto|always|never>   Progress indicator (default: auto)
--quiet, -q                      Suppress all stderr output
--verbose                        Per-phase timings (unchanged) + progress
```

`--quiet` wins over `--progress always`. `--progress` is also honoured via the
`WISPR_PROGRESS` environment variable for scripted use.

### Timing format (R7)

A small `formatDuration` helper replaces the raw `Duration` interpolation:

| Input | Output |
|---|---|
| 0.85 s | `0.9s` |
| 22.56 s | `22.6s` |
| 262 s | `4m 22s` |
| 5025 s | `1:23:45` |

Audio positions use `mm:ss` / `h:mm:ss`. `Decoded 48851727 samples` becomes
`Decoded 50:53 of audio in 12.4s`.

## Resulting output

Default mode, TTY:

```
Using model: large-v3
⠹ Loading model            22.4s
⠋ Decoding audio    ▕███████████████████░░░░░▏  76%   12.1s
⠴ Transcribing      ▕██████████░░░░░░░░░░░░░░▏  38%   19:23 / 50:53   elapsed 2:41   eta 4:22   11.8×
```

then the progress line is erased and the transcript goes to stdout.

`--verbose`, TTY — progress line plus the retained phase lines scrolling above it:

```
Using model: large-v3
✓ Model loaded in 22.6s
✓ Audio duration 50:53 (16 kHz mono)
✓ Decoded 50:53 of audio in 12.4s
⠴ Transcribing      ▕██████████░░░░░░░░░░░░░░▏  38%   19:23 / 50:53   elapsed 2:41   eta 4:22   11.8×
```

`wispr-cli long.m4a > out.txt` (stdout redirected, stderr still a TTY): progress
still renders, transcript still lands in the file.

`wispr-cli long.m4a 2>log --verbose`: plain `[progress]` lines in `log`.

## Failure and cancellation

- Any thrown error: `finish()` runs from a `defer`, erasing the line and
  restoring the cursor before the error is printed.
- SIGINT/SIGTERM: a `DispatchSourceSignal` writes `ESC[?25h\n` to the saved fd and
  re-raises with the default disposition, so `^C` never leaves a hidden cursor.
- Engine progress that runs backwards or exceeds the total is clamped monotonic,
  so the bar can't jump backwards on window overlap.

## Verification

Automated (`WisprTests`, pure logic, no models needed):

- `formatDuration` boundaries.
- `ProgressReporter` state machine: monotonic clamping, ETA withheld before the
  first report, phase transitions, `bufferingNewest` collapse.
- Bar rendering at 10 / 40 cells and below the 60-column cutoff.
- `MockTranscriptionEngine` still conforms without implementing the new
  requirement — proves the default implementation carries existing conformers.

Manual:

- `swift build --product WisprCLI` then run against the 50 min file: bar advances,
  ETA converges, transcript identical to `main`'s output (R6.2 — diff the two).
- `2>/dev/null`, `2>file`, `| cat`, `--quiet`, `--progress never`, `^C` mid-run.
- `make test` and `make run` to confirm the app is unaffected.
