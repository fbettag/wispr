# Implementation Plan: CLI Model Access Errors

## Overview

Restructure error reporting in `Sources/WisprCLI/WisprCLI.swift` so a permission denial on the GUI's
sandbox container is reported as such, with the resolved path and the exact Full Disk Access steps,
instead of being silently converted into "No models downloaded". Then correct the two documentation
files that describe the wrong model path and omit the CLI's permission prerequisite.

Order matters: the error type and the classifier come first because everything else throws through
them. Build after each numbered task — this is a single file and a broken `CLIError` breaks all call
sites at once.

`ModelPaths` is not modified. Its container probe already resolves the correct root without Full Disk
Access.

## Tasks

- [x] 1. Restructure `CLIError`
  - [x] 1.1 Add the `unreadable` case and attach paths to the existing cases
    - Add `case unreadable(what: String, path: String, reason: FailureReason)` to `CLIError`
    - Add the nested `enum FailureReason: Sendable { case permissionDenied; case other(String) }`
    - Change `noModelsDirectory` to `noModelsDirectory(path: String)`
    - Change `noDownloadedModels` to `noDownloadedModels(searched: String)`
    - Keep `FailureReason.other` carrying a pre-rendered `String`, not an `Error`, so the existing
      `Sendable` conformance on `CLIError` holds without an unchecked escape hatch
    - _Requirements: 1.1, 2.1, 2.2, 2.3_

  - [x] 1.2 Write the error descriptions
    - Implement `description` for the new and changed cases using the copy in `design.md`
    - `unreadable` with `.permissionDenied` emits the subject, the path, and the Full Disk Access
      steps including the Terminal.app path, the quit-and-reopen instruction, and the SSH plus
      `tmux kill-server` note
    - `unreadable` with `.other` emits the same subject and path, then the underlying description
    - Plain text only, no markup; multi-line strings print verbatim after `Error: ` because
      ArgumentParser renders `.other` message info without appending a usage block
    - _Requirements: 1.5, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6_

- [x] 2. Add the permission classifier
  - [x] 2.1 Implement `FileAccess.isPermissionDenied(_:)`
    - Match `NSCocoaErrorDomain` / `NSFileReadNoPermissionError`
    - Match `NSPOSIXErrorDomain` with `EPERM` or `EACCES`, at the top level and across
      `NSError.underlyingErrors`
    - _Requirements: 5.1, 5.2_

- [x] 3. Make directory reads strict
  - [x] 3.1 Add the `readDirectory(_:describedAs:)` helper
    - Wrap `FileManager.contentsOfDirectory(atPath:)`, converting any thrown error into
      `CLIError.unreadable`, choosing `.permissionDenied` or `.other` via the classifier
    - _Requirements: 1.1, 1.4, 1.5_

  - [x] 3.2 Rewrite `discoverDownloadedModels()` around a single authoritative read
    - Keep the `fileExists` guard on `ModelPaths.models`, throwing `noModelsDirectory(path:)` — it
      distinguishes "never set up" from "unreadable" and must not be mistaken for a permission check,
      since it succeeds under a TCC denial
    - Read `ModelPaths.models` once via `readDirectory`, and reuse the result for the Parakeet V3
      scan so the directory is no longer read twice
    - Guard `ModelPaths.whisperModels` with `fileExists` before reading it strictly, because its
      absence is legitimate on a Parakeet-only install
    - Remove both `try? fm.contentsOfDirectory` calls
    - Leave the Parakeet EOU `fileExists` check and all model-name extraction unchanged
    - _Requirements: 1.1, 1.2, 1.3, 1.4_

  - [x] 3.3 Pass the searched path into `noDownloadedModels`
    - Update the throw sites in `resolveModel` and `doListModels` to include `ModelPaths.models.path`
    - _Requirements: 2.2_

- [x] 4. Checkpoint - build and verify the happy path is unaffected
  - Build the `wispr-cli` scheme and confirm `--list-models` still lists models correctly on a
    machine that does have Full Disk Access. A false failure here would be worse than the bug being
    fixed, since it would break a working setup.
  - Ask the user if questions arise.

- [x] 5. Escalate permission denials on the preferences read
  - [x] 5.1 Make `guiDefaultsString(forKey:)` throwing
    - Guard on `fileExists` first so an absent plist still means "active model unknown"
    - Replace `try? Data(contentsOf:)` with a `do`/`catch`: on a permission denial throw
      `CLIError.unreadable(what: "Wispr's preferences file", ...)`; on any other read failure return
      `nil`, preserving today's behaviour
    - Keep the `PropertyListSerialization` parse as `try?` — a malformed plist legitimately means
      unknown, not unreadable
    - _Requirements: 4.1, 4.2, 4.3_

  - [x] 5.2 Update both call sites
    - Add `try` in `resolveModel` and `doListModels`
    - _Requirements: 4.1_

- [x] 6. Disclose the resolved root under `--verbose`
  - [x] 6.1 Print `ModelPaths.base` at the top of `run()`
    - Emit to stderr before branching on `listModels`, so it covers both `--list-models` and
      transcription
    - _Requirements: 2.4_

- [x] 7. Fix the documentation
  - [x] 7.1 Correct the model path in `CLAUDE.md`
    - Line 77 claims models are shared at `~/Library/Application Support/wispr/models/`. That is only
      `ModelPaths.base`'s fallback and does not exist on a normal install. Replace it with the
      container path and state that the CLI reads the GUI app's sandbox container.
    - _Requirements: 6.1_

  - [x] 7.2 Add a CLI section to `README.md`
    - Cover invocation, the embedded binary at `Wispr.app/Contents/Resources/bin/WisprCLI`, and the
      Full Disk Access prerequisite with the System Settings steps and the SSH variant
    - Note that Full Disk Access on a terminal applies to every command run in it, not just this tool
    - _Requirements: 6.2_

- [x] 8. Tests
  - [x] 8.1 Unit-test the permission classifier
    - **Property 4: Permission denials are classified**
    - Construct `NSError` values for each recognised shape, including a Cocoa error wrapping a POSIX
      error via `NSUnderlyingErrorKey`, and assert `isPermissionDenied` returns `true`; assert a
      `fileNotFound` error returns `false`
    - **Validates: Requirements 5.1, 5.2**

  - [x] 8.2 Unit-test the strict read against a real denial
    - **Property 1: Read failures never masquerade as an empty directory**
    - **Property 5: Unclassified errors are still surfaced**
    - Create a temporary directory, `chmod 000`, and assert `readDirectory` throws `.unreadable` with
      `.permissionDenied`. Restore the mode in a `defer` so cleanup succeeds, and skip when running
      as root, where the mode is bypassed.
    - **Validates: Requirements 1.1, 1.4, 1.5**

- [x] 9. Final checkpoint - manual verification of the reported bug
  - On a machine whose terminal lacks Full Disk Access, with at least one model downloaded, confirm
    `wispr-cli --list-models` prints the read-failure message with the container path rather than
    "No models downloaded".
  - Grant Full Disk Access, reopen the terminal, and confirm the same command lists the models.
  - Confirm `--verbose` prints the resolved models root.
  - Ensure the build succeeds and any existing tests pass.

## Notes

- Tests were requested during implementation, so task 8 is no longer optional. Implemented in
  `wisprTests/FileAccessTests.swift`: 20 tests in 3 suites, covering classification, strict reads, and
  message content. All passing.
- The classifier, strict read, and guidance text landed in `WisprCore` rather than the CLI, because
  the test target depends on `WisprApp` and `WisprCore` but not on the `WisprCLI` executable target.
  See the placement rationale in `design.md`.
- The reported failure cannot be reproduced in a test process: it needs a TCC denial on another app's
  container, which a test cannot create or revoke. `EACCES` on a mode-`000` directory is the closest
  stand-in, which is why the classifier matches both `EPERM` and `EACCES`.
- Full coverage of `discoverDownloadedModels` would need the models root to be injectable, and
  `ModelPaths.base` is a static computed property with no injection point. Adding one is out of scope.
- Related: GitHub issue [#110](https://github.com/sebsto/wispr/issues/110).
- Deliberately excluded, per the requirements' non-goals: any fallback directory, mirroring models to
  an unprotected location, a degraded mode, changes to `ModelPaths` resolution, and the separate
  question of removing the GUI's App Sandbox.
