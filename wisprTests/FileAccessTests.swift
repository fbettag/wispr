//  FileAccessTests.swift
//  wisprTests
//
//  Covers the distinction between "this directory is empty" and "this directory
//  is protected". Conflating the two is what made a Full Disk Access denial on
//  the GUI's sandbox container surface as "No models downloaded", telling users
//  to re-download models they already had.
//
//  The real fault needs a TCC denial on another app's container, which a test
//  process cannot create or revoke. A directory with mode 000 yields EACCES
//  instead of the EPERM that TCC produces, which is precisely why the classifier
//  matches both codes — these tests pin that down.
//

import Foundation
import Testing
import WisprCore

@Suite("FileAccess permission classification")
struct FileAccessClassificationTests {

    // MARK: - Helpers

    private func cocoaError(_ code: Int, underlying: NSError? = nil) -> NSError {
        var info: [String: Any] = [:]
        if let underlying {
            info[NSUnderlyingErrorKey] = underlying
        }
        return NSError(domain: NSCocoaErrorDomain, code: code, userInfo: info)
    }

    private func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [:])
    }

    // MARK: - Recognised denials

    @Test("A Cocoa read-no-permission error is a denial")
    func testCocoaNoPermission() {
        #expect(FileAccess.isPermissionDenied(cocoaError(NSFileReadNoPermissionError)))
    }

    @Test("A top-level EPERM is a denial")
    func testTopLevelEPERM() {
        // This is the shape a TCC denial takes.
        #expect(FileAccess.isPermissionDenied(posixError(EPERM)))
    }

    @Test("A top-level EACCES is a denial")
    func testTopLevelEACCES() {
        // This is the shape an ordinary filesystem permission failure takes.
        #expect(FileAccess.isPermissionDenied(posixError(EACCES)))
    }

    @Test("A POSIX denial wrapped in a Cocoa error is still a denial")
    func testWrappedDenial() {
        // Foundation routinely wraps the POSIX errno inside a Cocoa error, so
        // inspecting only the top level would miss the real cause.
        let wrapped = cocoaError(NSFileReadUnknownError, underlying: posixError(EPERM))
        #expect(FileAccess.isPermissionDenied(wrapped))
    }

    @Test("A wrapped EACCES is a denial too")
    func testWrappedEACCES() {
        let wrapped = cocoaError(NSFileReadUnknownError, underlying: posixError(EACCES))
        #expect(FileAccess.isPermissionDenied(wrapped))
    }

    @Test("A denial nested two wrappers deep is still found")
    func testDoublyWrappedDenial() {
        // `underlyingErrors` only reports one level, so a wrapper whose own
        // underlying error is another wrapper needs the chain to be walked.
        let inner = cocoaError(NSFileReadUnknownError, underlying: posixError(EPERM))
        let outer = cocoaError(NSFileReadUnknownError, underlying: inner)
        #expect(FileAccess.isPermissionDenied(outer))
    }

    @Test("A Cocoa no-permission error nested inside a wrapper is found")
    func testNestedCocoaNoPermission() {
        let inner = cocoaError(NSFileReadNoPermissionError)
        let outer = cocoaError(NSFileReadUnknownError, underlying: inner)
        #expect(FileAccess.isPermissionDenied(outer))
    }

    @Test("A deeply nested non-denial terminates instead of recursing forever")
    func testDeepChainTerminates() {
        // A chain this deep does not occur in practice; the point is that
        // traversal ends rather than spinning.
        var error = cocoaError(NSFileNoSuchFileError)
        for _ in 0..<50 {
            error = cocoaError(NSFileReadUnknownError, underlying: error)
        }
        #expect(!FileAccess.isPermissionDenied(error))
    }

    @Test("A denial is found however deeply it is nested")
    func testDeeplyNestedDenialIsFound() {
        // Termination is by visited-set, not a depth limit, so nesting depth
        // must not decide whether the guidance is shown. Requirement 5.2 says
        // "anywhere in its chain"; a truncating traversal would fail here.
        var error = posixError(EPERM)
        for _ in 0..<50 {
            error = cocoaError(NSFileReadUnknownError, underlying: error)
        }
        #expect(FileAccess.isPermissionDenied(error))
    }

    @Test("A denial reachable through a branch of a multi-error chain is found")
    func testDenialInMultipleUnderlyingErrors() {
        // NSMultipleUnderlyingErrorsKey yields several siblings; the denial may
        // be in any of them, so every branch has to be walked.
        let benign = cocoaError(NSFileNoSuchFileError)
        let denial = cocoaError(NSFileReadUnknownError, underlying: posixError(EACCES))
        let multi = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadUnknownError,
            userInfo: [NSMultipleUnderlyingErrorsKey: [benign, denial]]
        )
        #expect(FileAccess.isPermissionDenied(multi))
    }

    // MARK: - Non-denials

    @Test("A missing-file error is not a denial")
    func testMissingFileIsNotDenial() {
        #expect(!FileAccess.isPermissionDenied(cocoaError(NSFileNoSuchFileError)))
    }

    @Test("ENOENT is not a denial")
    func testENOENTIsNotDenial() {
        #expect(!FileAccess.isPermissionDenied(posixError(ENOENT)))
    }

    @Test("An unrelated error domain is not a denial")
    func testUnrelatedDomain() {
        let error = NSError(domain: "com.example.whatever", code: Int(EPERM), userInfo: [:])
        #expect(!FileAccess.isPermissionDenied(error))
    }

    // MARK: - classify

    @Test("A denial classifies as permissionDenied")
    func testClassifyDenial() {
        #expect(FileAccess.classify(posixError(EPERM)) == .permissionDenied)
    }

    @Test("An unrecognised failure classifies as other, carrying a description")
    func testClassifyOther() {
        // A classification miss must degrade to a verbose but truthful message,
        // never to a wrong one, so `.other` has to retain the reason.
        guard case .other(let reason) = FileAccess.classify(posixError(ENOENT)) else {
            Issue.record("ENOENT should classify as .other, not .permissionDenied")
            return
        }
        #expect(!reason.isEmpty)
    }
}

@Suite("FileAccess.readDirectory")
struct FileAccessReadDirectoryTests {

    /// Creates a directory in a unique temporary location.
    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FileAccessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A readable directory lists its contents")
    func testReadableDirectory() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data().write(to: dir.appendingPathComponent("alpha"))
        try Data().write(to: dir.appendingPathComponent("beta"))

        let entries = try FileAccess.readDirectory(at: dir)
        #expect(Set(entries) == Set(["alpha", "beta"]))
    }

    @Test("An empty directory reads successfully rather than throwing")
    func testEmptyDirectory() throws {
        // The whole point of the change: empty is a success, not a failure.
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(try FileAccess.readDirectory(at: dir).isEmpty)
    }

    @Test("A missing directory throws with the path and a non-permission reason")
    func testMissingDirectory() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FileAccessTests-absent-\(UUID().uuidString)")

        do {
            _ = try FileAccess.readDirectory(at: missing)
            Issue.record("Reading a missing directory should throw")
        } catch let error as FileReadError {
            #expect(error.path == missing.path)
            #expect(error.failure != .permissionDenied)
        }
    }

    @Test(
        "An unreadable directory throws permissionDenied, never an empty list",
        .disabled(if: getuid() == 0, "root bypasses directory permissions")
    )
    func testUnreadableDirectory() throws {
        let dir = try makeTempDirectory()
        // Restore permissions before cleanup, or removeItem cannot descend.
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }

        try Data().write(to: dir.appendingPathComponent("hidden-by-permissions"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: dir.path)

        do {
            let entries = try FileAccess.readDirectory(at: dir)
            Issue.record("Expected a denial, got \(entries.count) entries")
        } catch let error as FileReadError {
            #expect(error.failure == .permissionDenied)
            #expect(error.path == dir.path)
        }
    }
}

@Suite("FileAccess.explain")
struct FileAccessExplainTests {

    private let path = "/Users/example/Library/Containers/com.stormacq.mac.wispr"
        + "/Data/Library/Application Support/wispr/models"

    private func denial() -> FileReadError {
        FileReadError(path: path, failure: .permissionDenied)
    }

    @Test("A denial names the subject and the path it tried to read")
    func testDenialNamesSubjectAndPath() {
        let message = FileAccess.explain(denial(), what: "Wispr's model directory")
        #expect(message.contains("Wispr's model directory"))
        #expect(message.contains(path))
    }

    @Test("A denial spells out the Full Disk Access remedy")
    func testDenialIncludesRemedy() {
        let message = FileAccess.explain(denial(), what: "Wispr's model directory")
        #expect(message.contains("Full Disk Access"))
        #expect(message.contains("System Settings"))
        #expect(message.contains("/System/Applications/Utilities/Terminal.app"))
        // The grant only applies to newly launched processes, so the message is
        // incomplete without this.
        #expect(message.contains("quit and reopen"))
    }

    @Test("A denial covers the SSH and tmux cases")
    func testDenialCoversRemoteSessions() {
        let message = FileAccess.explain(denial(), what: "Wispr's model directory")
        #expect(message.contains("/usr/libexec/sshd-keygen-wrapper"))
        #expect(message.contains("tmux kill-server"))
    }

    @Test("A denial never suggests downloading models")
    func testDenialDoesNotSuggestDownloading() {
        // The original bug: a permission problem was reported as a missing
        // download. This is the regression guard for that.
        let message = FileAccess.explain(denial(), what: "Wispr's model directory")
        #expect(!message.lowercased().contains("download"))
    }

    @Test("A non-permission failure reports the underlying reason")
    func testOtherFailureReportsReason() {
        let error = FileReadError(path: path, failure: .other("disk I/O error"))
        let message = FileAccess.explain(error, what: "Wispr's model directory")
        #expect(message.contains("disk I/O error"))
        #expect(message.contains(path))
    }

    @Test("A non-permission failure omits the Full Disk Access advice")
    func testOtherFailureOmitsRemedy() {
        // Sending someone to Privacy & Security for a disk error would waste
        // their time exactly the way the original message did.
        let error = FileReadError(path: path, failure: .other("disk I/O error"))
        let message = FileAccess.explain(error, what: "Wispr's model directory")
        #expect(!message.contains("Full Disk Access"))
    }
}
