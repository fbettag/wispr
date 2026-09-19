//
//  OutputFormat.swift
//  wispr-cli
//
//  Output format options for CLI transcription results.
//

import ArgumentParser

/// Supported output formats for transcription results.
enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    /// Plain text without speaker labels (default).
    case text
    /// Plain text with speaker labels when diarization is enabled.
    case diarized
    /// JSON with segments, timestamps, and speaker information.
    case json
    /// SubRip subtitle format with timestamps.
    case srt

    static var allValueStrings: [String] {
        allCases.map(\.rawValue)
    }
}
