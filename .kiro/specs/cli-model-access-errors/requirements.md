# Requirements Document

## Introduction

`wispr-cli` reads its models from the GUI app's App Sandbox container. macOS protects that
container's `Data` directory as app-private data, so any process other than Wispr.app itself
needs Full Disk Access to read it. When that permission is missing, the CLI currently reports
`No models downloaded. Please open Wispr.app and download at least one model` — advice that is
both wrong and unactionable, because the models are present and the real problem is a missing
permission grant.

This change makes the CLI report permission failures accurately and tell the user exactly which
setting to change. It does not add a fallback, a workaround, or a degraded mode: when the model
directory cannot be read, the CLI fails and explains how to fix the configuration.

### Field report that motivated this

A user with two downloaded models (Parakeet V3 and Whisper Large v3, both visible and working in
the GUI) saw `No models downloaded` from the CLI. Diagnosis took six rounds of back-and-forth
because every filesystem error was silently discarded and no error message named the path being
read. `ls` on the container returned `Operation not permitted`; granting Full Disk Access to the
terminal resolved it immediately.

## Glossary

- **wispr-cli / WisprCLI**: The command-line transcription tool, target `WisprCLI`, shipped inside
  `Wispr.app/Contents/Resources/bin/WisprCLI`. Not sandboxed.
- **Wispr.app**: The sandboxed GUI app (`com.stormacq.mac.wispr`, `ENABLE_APP_SANDBOX = YES`).
- **Container**: The GUI app's App Sandbox container,
  `~/Library/Containers/com.stormacq.mac.wispr/Data`.
- **Models root**: `ModelPaths.base` — for both targets this resolves to
  `<container>/Library/Application Support/wispr`.
- **Models directory**: `ModelPaths.models`, i.e. `<models root>/models`.
- **TCC**: macOS Transparency, Consent and Control — the subsystem that gates access to protected
  locations, including another app's container data.
- **FDA**: Full Disk Access, the TCC permission that allows a process to read protected locations.
- **Responsible process**: The process TCC attributes a permission grant to. For a terminal
  command this is the terminal application; for an SSH session it is `sshd`.

## Background: the exact failure mechanism

`ModelPaths.base` resolves correctly even without FDA, because it probes with
`FileManager.fileExists(atPath:)`, which uses `stat()` and is permitted. Directory enumeration is
not permitted, and `FileManager.contentsOfDirectory(atPath:)` returns `EPERM`. Both enumeration
calls in `discoverDownloadedModels()` are wrapped in `try?`, which converts that error into `nil`:

```swift
if let variants = try? fm.contentsOfDirectory(atPath: whisperDir.path) { ... }
if let entries  = try? fm.contentsOfDirectory(atPath: modelsDir.path)  { ... }
```

The scan therefore finds nothing, `results` is empty, and the caller throws
`CLIError.noDownloadedModels`. The user is told to download models they already have.

The same denial applies to `ModelPaths.guiDefaultsPlist`, read with
`try? Data(contentsOf:)`, so a user who fixed only the directory read would next hit
`CLIError.noActiveModel` — a second misleading message for the same root cause.

## Requirements

### Requirement 1: Distinguish an unreadable directory from an empty one

**User Story:** As a CLI user, I want to be told when Wispr's model directory cannot be read, so
that I do not waste time re-downloading models that are already installed.

#### Acceptance Criteria

1. WHEN the models directory exists but cannot be enumerated, THE CLI SHALL report a read failure
   and SHALL NOT report that no models are downloaded.
2. WHEN the models directory exists and can be enumerated but contains no recognized model layout,
   THE CLI SHALL report that no models are downloaded.
3. WHEN the models directory does not exist, THE CLI SHALL report that Wispr.app has not been set
   up yet.
4. THE CLI SHALL NOT discard any error returned by a filesystem enumeration or read while
   discovering models.
5. WHEN a filesystem error is not recognizable as a permission denial, THE CLI SHALL report the
   underlying error rather than substituting a generic message.

### Requirement 2: Name the path in every model-discovery error

**User Story:** As a user or maintainer diagnosing a report, I want to know which directory the CLI
actually looked at, so that I can tell a permission problem from a wrong path without reading the
source.

#### Acceptance Criteria

1. THE CLI SHALL include the resolved absolute path in the "not set up" error.
2. THE CLI SHALL include the resolved absolute path in the "no models downloaded" error.
3. THE CLI SHALL include the resolved absolute path in the read-failure error.
4. WHEN `--verbose` is passed, THE CLI SHALL print the resolved `ModelPaths.base` to stderr before
   attempting model discovery.

### Requirement 3: Guide the user to the correct permission setting

**User Story:** As a CLI user hitting a permission denial, I want the error to tell me precisely
which setting to change, so that I can fix it without searching for documentation.

#### Acceptance Criteria

1. WHEN a permission denial is detected, THE CLI SHALL state that macOS protects one app's data
   directory from other processes.
2. WHEN a permission denial is detected, THE CLI SHALL instruct the user to grant Full Disk Access
   via System Settings → Privacy & Security → Full Disk Access.
3. WHEN a permission denial is detected, THE CLI SHALL name the terminal application as the item to
   add, including the absolute path of the default macOS Terminal as an example.
4. WHEN a permission denial is detected, THE CLI SHALL state that the terminal must be quit and
   reopened for the grant to take effect.
5. WHEN a permission denial is detected, THE CLI SHALL describe the SSH case, naming
   `/usr/libexec/sshd-keygen-wrapper` as the item to add, and SHALL mention that a pre-existing
   `tmux` server must be restarted with `tmux kill-server`.
6. THE guidance SHALL be plain text suitable for a terminal, with no markup.

### Requirement 4: Apply the same treatment to the preferences read

**User Story:** As a CLI user, I want a single clear error for a single root cause, rather than
hitting a second unrelated-looking message after fixing the first.

#### Acceptance Criteria

1. WHEN the GUI preferences plist cannot be read because of a permission denial, THE CLI SHALL
   report the same permission error and guidance as for the models directory.
2. WHEN the GUI preferences plist is absent or malformed, THE CLI SHALL continue to treat the active
   model as unknown, preserving today's behaviour.
3. THE CLI SHALL distinguish "plist unreadable due to permissions" from "plist absent".

### Requirement 5: Detect both permission error representations

**User Story:** As a maintainer, I want permission detection to be robust across the error shapes
Foundation produces, so that the good message is not skipped because of an error-code mismatch.

#### Acceptance Criteria

1. THE CLI SHALL treat `NSCocoaErrorDomain` / `NSFileReadNoPermissionError` as a permission denial.
2. THE CLI SHALL treat `NSPOSIXErrorDomain` with code `EPERM` or `EACCES` as a permission denial,
   whether it appears as the top-level error or anywhere in its chain of underlying errors.
3. THE CLI SHALL terminate its traversal of an underlying-error chain regardless of the chain's
   depth or the presence of a cycle.
4. WHEN detection does not match, THE CLI SHALL still surface the error per Requirement 1.5, so a
   detection miss degrades to a verbose but correct message rather than a wrong one.

### Requirement 6: Documentation matches reality

**User Story:** As a user or contributor, I want the documented model path and CLI prerequisites to
be correct, so that I do not investigate the wrong directory.

#### Acceptance Criteria

1. THE repository documentation SHALL state the container path as the shared model location, not
   `~/Library/Application Support/wispr/models/`.
2. THE README SHALL document the CLI, including the Full Disk Access prerequisite.

## Non-Goals

These are explicitly out of scope. The CLI must fail loudly rather than work around the permission.

- No fallback to an alternative models directory when the container is unreadable.
- No copying, symlinking, or mirroring of models to an unprotected location.
- No degraded or partial-results mode.
- No change to how `ModelPaths.base` resolves the models root; it already resolves correctly
  without FDA.
- No change to the GUI's sandbox status. Removing the App Sandbox would eliminate this failure mode
  entirely and is worth considering, but it is a distribution and migration decision that belongs in
  its own spec.
- No change to the GUI app. This spec covers the CLI and documentation only.
