//
//  TranscriptionResult.swift
//  wispr
//
//  Created by Kiro
//

import Foundation

/// Word-level timing information from the transcription engine.
/// Provides precise start/end times for individual words.
public nonisolated struct WordTiming: Sendable, Equatable, Codable {
    public let word: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let probability: Float

    public init(word: String, start: TimeInterval, end: TimeInterval, probability: Float) {
        self.word = word
        self.start = start
        self.end = end
        self.probability = probability
    }
}

/// A single segment of transcribed text with timing and optional speaker information.
/// Segments typically correspond to sentence or phrase boundaries.
public nonisolated struct TranscriptionSegment: Sendable, Equatable, Codable {
    /// Speaker index (0-based) if diarization was performed, nil otherwise.
    /// Speaker 0 = first speaker detected, Speaker 1 = second, etc.
    public let speakerIndex: Int?
    /// Start time of this segment in seconds from the beginning of the audio.
    public let startTime: TimeInterval
    /// End time of this segment in seconds from the beginning of the audio.
    public let endTime: TimeInterval
    /// The transcribed text for this segment.
    public let text: String
    /// Optional word-level timing information.
    public let words: [WordTiming]?

    public init(
        speakerIndex: Int? = nil,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        words: [WordTiming]? = nil
    ) {
        self.speakerIndex = speakerIndex
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.words = words
    }
}

/// Result of a transcription operation
public nonisolated struct TranscriptionResult: Sendable, Equatable {
    public let text: String
    public let segments: [TranscriptionSegment]
    public let detectedLanguage: String?
    public let duration: TimeInterval
    /// True when the transcription engine detected end-of-utterance.
    /// Used by StateManager to auto-stop recording in hands-free mode.
    public let isEndOfUtterance: Bool

    public init(
        text: String,
        segments: [TranscriptionSegment] = [],
        detectedLanguage: String? = nil,
        duration: TimeInterval,
        isEndOfUtterance: Bool = false
    ) {
        self.text = text
        self.segments = segments
        self.detectedLanguage = detectedLanguage
        self.duration = duration
        self.isEndOfUtterance = isEndOfUtterance
    }
}
