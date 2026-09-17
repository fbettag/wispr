//
//  DurationFormat.swift
//  wispr-cli
//
//  Human-readable duration formatting for terminal output.
//
//  Replaces raw `Duration` interpolation, which produces things like
//  "22.556551125 seconds" — technically correct, unreadable in a terminal.
//

import Foundation

/// Formats an elapsed wall-clock duration for display.
///
/// | Input   | Output    |
/// |---------|-----------|
/// | 0.85 s  | `0.9s`    |
/// | 22.56 s | `22.6s`   |
/// | 262 s   | `4m 22s`  |
/// | 5025 s  | `1:23:45` |
nonisolated func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "—" }

    if seconds < 60 {
        return String(format: "%.1fs", seconds)
    }

    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60

    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return "\(minutes)m \(secs)s"
}

/// Formats a position within a media file as a clock time.
///
/// Uses `mm:ss` below an hour and `h:mm:ss` above, so a position and a total can
/// be shown side by side without the units shifting mid-run.
nonisolated func formatClock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }

    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60

    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%02d:%02d", minutes, secs)
}

extension Duration {
    /// The duration as a floating-point number of seconds.
    ///
    /// `Duration` stores seconds and attoseconds separately; there is no stdlib
    /// conversion to `Double`, so measuring elapsed time needs this.
    nonisolated var seconds: Double {
        let (secs, attos) = components
        return Double(secs) + Double(attos) / 1e18
    }
}
