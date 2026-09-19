//
//  OutputFormatters.swift
//  wispr-cli
//
//  Formatters for transcription output in various formats.
//

import Foundation
import WisprCore

/// Formats transcription results for output.
nonisolated enum OutputFormatter {
    /// Formats transcription result as plain text.
    /// When diarization is enabled, prefixes each segment with speaker label.
    static func formatText(_ result: TranscriptionResult, diarized: Bool) -> String {
        guard diarized, !result.segments.isEmpty else {
            return result.text
        }

        return result.segments
            .map { segment in
                let speakerLabel = segment.speakerIndex.map { "Speaker \($0 + 1)" } ?? "Unknown"
                return "[\(speakerLabel)] \(segment.text.trimmingCharacters(in: .whitespaces))"
            }
            .joined(separator: "\n\n")
    }

    /// Formats transcription result as JSON.
    static func formatJSON(_ result: TranscriptionResult) -> String {
        let segmentsJSON: [[String: Any]] = result.segments.map { segment in
            var dict: [String: Any] = [
                "startTime": String(format: "%.3f", segment.startTime),
                "endTime": String(format: "%.3f", segment.endTime),
                "text": segment.text.trimmingCharacters(in: .whitespaces)
            ]
            if let speakerIndex = segment.speakerIndex {
                dict["speaker"] = speakerIndex + 1
            }
            return dict
        }

        let output: [String: Any] = [
            "text": result.text,
            "segments": segmentsJSON,
            "duration": String(format: "%.3f", result.duration),
            "language": result.detectedLanguage ?? "unknown"
        ]

        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: output,
            options: [.prettyPrinted, .sortedKeys]
        ),
        let jsonString = String(data: jsonData, encoding: .utf8) else {
            return result.text
        }

        return jsonString
    }

    /// Formats transcription result as SubRip (SRT) subtitles.
    static func formatSRT(_ result: TranscriptionResult) -> String {
        guard !result.segments.isEmpty else {
            // Fallback: single subtitle for entire duration
            return """
            1
            00:00:00,000 --> \(formatSRTTime(result.duration))
            \(result.text)


            """
        }

        return result.segments
            .enumerated()
            .map { index, segment in
                let subtitleIndex = index + 1
                let startTime = formatSRTTime(segment.startTime)
                let endTime = formatSRTTime(segment.endTime)
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)

                // Add speaker label if available
                let speakerLabel = segment.speakerIndex.map { "[Speaker \($0 + 1)] " } ?? ""

                return """
                \(subtitleIndex)
                \(startTime) --> \(endTime)
                \(speakerLabel)\(text)


                """
            }
            .joined()
    }

    /// Formats seconds as SRT timestamp (HH:MM:SS,mmm).
    private static func formatSRTTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        let millis = Int((seconds - Double(Int(seconds))) * 1000)

        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }
}
