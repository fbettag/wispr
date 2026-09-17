//
//  FileAccess.swift
//  wispr
//
//  Filesystem reads that distinguish a permission denial from an absent or
//  empty directory, plus the guidance needed to resolve the denial.
//
//  The GUI app is sandboxed, so models live in its container. macOS protects
//  that container as app-private data: a process which is not the owning app
//  needs Full Disk Access to enumerate it. The failure is asymmetric —
//  `stat()` is permitted, so `FileManager.fileExists(atPath:)` returns `true`,
//  while `opendir`/`readdir` is refused. Code that swallows the enumeration
//  error therefore cannot tell "protected" from "empty", which is exactly the
//  confusion this type exists to prevent.
//

import Foundation

/// Why a filesystem read failed.
public nonisolated enum FileReadFailure: Sendable, Equatable {
    /// The operating system refused access.
    case permissionDenied

    /// Any other failure. Carries a pre-rendered description rather than the
    /// original error so the value stays `Sendable` — `any Error` is not.
    case other(String)
}

/// A read that failed on a path which was expected to be readable.
public nonisolated struct FileReadError: Error, Sendable, Equatable {
    public let path: String
    public let failure: FileReadFailure

    public init(path: String, failure: FileReadFailure) {
        self.path = path
        self.failure = failure
    }
}

public nonisolated enum FileAccess {

    // MARK: - Classification

    /// Whether `error` represents the operating system refusing access.
    ///
    /// Matches both `EPERM` and `EACCES`: TCC denials surface as `EPERM`,
    /// ordinary POSIX permission failures as `EACCES`. Foundation frequently
    /// wraps the POSIX error inside a Cocoa error, so underlying errors are
    /// inspected as well as the top level.
    ///
    /// A miss here is not fatal. `classify(_:)` falls back to `.other`, which
    /// still surfaces the underlying description, so an unrecognised error
    /// produces a verbose but truthful message rather than a wrong one.
    public static func isPermissionDenied(_ error: Error) -> Bool {
        isPermissionDenied(error as NSError, depth: 0)
    }

    /// Walks a wrapped error chain looking for a denial at any level.
    ///
    /// `NSError.underlyingErrors` already reports both the singular
    /// `NSUnderlyingErrorKey` and the plural `NSMultipleUnderlyingErrorsKey`,
    /// so neither form needs handling of its own. What does need handling is a
    /// wrapper whose underlying error is itself a wrapper: inspecting only one
    /// level would miss a denial nested below it.
    private static func isPermissionDenied(_ error: NSError, depth: Int) -> Bool {
        if error.domain == NSCocoaErrorDomain,
            error.code == NSFileReadNoPermissionError {
            return true
        }
        if isPOSIXDenial(error) { return true }

        guard depth < maxUnderlyingErrorDepth else { return false }
        return error.underlyingErrors.contains {
            isPermissionDenied($0 as NSError, depth: depth + 1)
        }
    }

    /// Depth cap for `underlyingErrors` traversal. Real chains from Foundation
    /// are one level deep; the cap exists only so a pathological or
    /// self-referential chain cannot recurse without bound.
    private static let maxUnderlyingErrorDepth = 5

    private static func isPOSIXDenial(_ error: NSError) -> Bool {
        guard error.domain == NSPOSIXErrorDomain else { return false }
        return error.code == Int(EPERM) || error.code == Int(EACCES)
    }

    /// Maps an arbitrary error onto a `FileReadFailure`.
    public static func classify(_ error: Error) -> FileReadFailure {
        isPermissionDenied(error)
            ? .permissionDenied
            : .other(error.localizedDescription)
    }

    // MARK: - Strict Reads

    /// Lists the contents of `url`, throwing `FileReadError` on any failure.
    ///
    /// Unlike `try? FileManager.contentsOfDirectory(atPath:)`, this never
    /// reports an unreadable directory as an empty one.
    public static func readDirectory(at url: URL) throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: url.path)
        } catch {
            throw FileReadError(path: url.path, failure: classify(error))
        }
    }

    // MARK: - Guidance

    /// Plain-text explanation of a failed read, including how to fix a
    /// permission denial. Suitable for writing straight to a terminal.
    ///
    /// - Parameters:
    ///   - error: The failure to explain.
    ///   - what: Subject of the read, e.g. `"Wispr's model directory"`.
    public static func explain(_ error: FileReadError, what: String) -> String {
        let header = """
            Cannot read \(what).

              \(error.path)
            """

        switch error.failure {
        case .permissionDenied:
            return header + "\n\n" + fullDiskAccessGuidance
        case .other(let reason):
            return header + "\n\nThe read failed: \(reason)"
        }
    }

    /// Steps to grant Full Disk Access, for both local terminals and SSH.
    ///
    /// The grant applies to the *responsible process*: for a local command
    /// that is the terminal application, for a remote one it is `sshd`. A
    /// pre-existing `tmux` server keeps the permissions it was started with,
    /// so it has to be restarted too.
    public static let fullDiskAccessGuidance = """
        macOS protects one app's data directory from other processes. Grant Full \
        Disk Access to your terminal, then quit and reopen it:

          System Settings › Privacy & Security › Full Disk Access › +
          Add your terminal app, for example:
            /System/Applications/Utilities/Terminal.app

        Over SSH, add /usr/libexec/sshd-keygen-wrapper instead. If you use tmux, \
        run "tmux kill-server" and reconnect after granting access, because an \
        existing tmux server keeps its old permissions.
        """
}
