# Requirements: CLI Transcription Progress

## Problem

`wispr-cli` gives no feedback while transcribing. On a 3053 s (50 min) file the
terminal shows this and then goes silent for many minutes:

```
Using model: large-v3
Model loaded in 22.556551125 seconds
Audio duration: 3053.2s
Decoded 48851727 samples.
```

There is no way to tell whether the process is working, stuck, or how long is
left. `--verbose` does not help: the four lines above are all it prints, because
nothing between "decoded" and "done" reports anything.

Three separate causes:

1. Neither `WhisperService` nor `ParakeetService` surfaces the transcription
   progress that WhisperKit and FluidAudio already expose internally.
2. `AudioFileDecoder.decode(fileURL:)` decodes ~195 MB in one blocking pass with
   no progress signal.
3. In non-`--verbose` mode the CLI redirects `STDERR_FILENO` to `/dev/null` for
   the whole run (`WisprCLI.swift:126`), so anything written to stderr during
   transcription is discarded. Any progress output must survive that.

## Scope

CLI only. The GUI app's source and behaviour must not change.

`WisprCore` is shared between the app and the CLI, so the engine-side plumbing
must be **strictly additive**: new types and new overloads with default
implementations, so every existing app and test call site compiles and behaves
exactly as before. No existing signature changes, no behaviour changes on the
existing code paths.

## Requirements

### R1 — Live progress during transcription

1.1 While transcribing, the CLI SHALL emit progress at least once per second.

1.2 Progress SHALL be expressed as a fraction of **audio processed**, derived
from the engine's own position in the audio, not from a wall-clock guess.

1.3 The display SHALL show: phase, percentage, audio position / total duration,
elapsed wall time, estimated time remaining, and realtime factor (speed).

1.4 When the engine reports no new position for a while, the display SHALL still
animate (spinner + elapsed) so the user can distinguish "slow" from "hung".

### R2 — Progress across all long phases

2.1 Model loading (~22 s for `large-v3`) SHALL show an indeterminate progress
indicator with elapsed time.

2.2 Audio decoding SHALL show a determinate percentage, using
`AudioMetadata.estimatedSampleCount` as the denominator.

2.3 Transcription SHALL show a determinate percentage per R1.

2.4 Each completed phase SHALL report its final elapsed time.

### R3 — Both engines

3.1 Whisper models SHALL report progress via WhisperKit's segment-discovery and
token callbacks.

3.2 Parakeet models SHALL report progress via FluidAudio's
`transcriptionProgressStream`.

3.3 If an engine cannot report position, the CLI SHALL fall back to the
indeterminate indicator rather than showing a stalled percentage.

### R4 — Terminal correctness

4.1 All progress output SHALL go to stderr, never stdout. stdout stays a clean
pipe carrying only the transcript.

4.2 Progress SHALL be visible in the default (non-`--verbose`) mode, i.e. it must
be written to the real stderr even while the SDK-log suppression is active.

4.3 When stderr is a TTY, progress SHALL redraw a single line in place.

4.4 When stderr is not a TTY (piped, redirected, CI), the CLI SHALL NOT emit
ANSI escapes or carriage returns. It SHALL emit periodic plain one-line updates
instead, and only when `--verbose` is set.

4.5 The progress line SHALL be erased before the transcript or any error is
written, so output is never interleaved with a half-drawn progress bar.

4.6 The cursor SHALL be restored on normal exit, on error, and on SIGINT/SIGTERM.

4.7 `NO_COLOR` and `TERM=dumb` SHALL disable ANSI styling.

### R5 — User control

5.1 A `--progress <auto|always|never>` option SHALL control the indicator.
Default `auto` = enabled when stderr is a TTY.

5.2 `--quiet` SHALL suppress all stderr output including progress.

5.3 `--verbose` SHALL keep its current per-phase timing lines, in addition to
progress.

### R6 — Cost

6.1 Progress reporting SHALL NOT measurably slow transcription. The per-token
callback path must be allocation-light and must never block the decoder.

6.2 Progress SHALL NOT change transcription output in any way.

### R7 — Readable timings

7.1 Durations SHALL be human-formatted (`22.6s`, `4m 22s`, `1:23:45`), replacing
the current raw `Duration` dump (`22.556551125 seconds`).

7.2 Large sample counts SHALL be reported with the derived duration rather than
a bare integer.
