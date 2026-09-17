//
//  ProgressUpdate.swift
//  wispr
//
//  Engine-agnostic progress reporting for long-running transcription.
//
//  Engines report a position in the audio; they never decide how that gets
//  displayed. All presentation policy (throttling, formatting, ETA, TTY
//  handling) lives in the consumer — currently only wispr-cli.
//

import Foundation

/// A report of how far through the audio a transcription engine has progressed.
///
/// Deliberately named `ProgressUpdate` rather than `TranscriptionProgress`:
/// `WhisperService` imports WhisperKit, which already exports a type by the
/// latter name. Keeping the names distinct means neither needs qualifying.
nonisolated public struct ProgressUpdate: Sendable {

    /// Seconds of audio processed so far.
    public let processedSeconds: Double

    /// Total seconds of audio, when the engine knows it up front.
    public let totalSeconds: Double?

    /// Most recently decoded text, when the engine exposes it.
    /// For display only — never assembled into the final transcript.
    public let textTail: String?

    public init(
        processedSeconds: Double,
        totalSeconds: Double? = nil,
        textTail: String? = nil
    ) {
        self.processedSeconds = processedSeconds
        self.totalSeconds = totalSeconds
        self.textTail = textTail
    }

    /// Completed fraction in 0...1, or nil when the total is unknown.
    public var fraction: Double? {
        guard let totalSeconds, totalSeconds > 0 else { return nil }
        return min(max(processedSeconds / totalSeconds, 0), 1)
    }
}

/// Receives `ProgressUpdate` values from a transcription engine.
///
/// Called from whatever context the underlying engine decodes on, potentially at
/// token rate (thousands of times per minute). Implementations must be
/// non-blocking and allocation-light: enqueue and return, never `await`, never
/// render inline.
///
/// Named with the `Transcription` prefix because FluidAudio exports a
/// `ProgressHandler` of its own for model downloads, which `ParakeetService`
/// uses; an unqualified `ProgressHandler` here would shadow it.
public typealias TranscriptionProgressHandler = @Sendable (ProgressUpdate) -> Void

/// Receives decoded-sample counts while an audio file is being read.
///
/// Same contract as `TranscriptionProgressHandler`: cheap and non-blocking.
public typealias DecodeProgressHandler = @Sendable (Int) -> Void
