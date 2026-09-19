//
//  SpeakerDiarizationService.swift
//  wispr
//
//  Speaker diarization service using SpeakerKit (Pyannote models).
//  Identifies distinct speakers in audio and assigns them monotonic indices.
//

import Foundation
@preconcurrency import SpeakerKit
import os

/// Actor managing SpeakerKit model lifecycle and speaker diarization.
///
/// Speaker diarization identifies who spoke when in an audio recording,
/// assigning each distinct speaker a monotonic index (0, 1, 2, ...) in
/// the order they first appear.
///
/// Uses Pyannote models via SpeakerKit. Models are downloaded automatically
/// on first use (~50MB) and cached in the Wispr models directory.
public actor SpeakerDiarizationService {
    // MARK: - State

    private var speakerKit: SpeakerKit?
    private var isInitialized = false

    public init() {}

    // MARK: - Initialization

    /// Loads Pyannote models, downloading them if necessary.
    ///
    /// Safe to call multiple times - returns immediately if already initialized.
    /// Models are cached in `ModelPaths.speakerKit`.
    ///
    /// - Throws: Error if model download or loading fails.
    public func initialize() async throws {
        guard !isInitialized else { return }

        Log.speakerDiarization.info("SpeakerDiarizationService — loading Pyannote models")

        let config = PyannoteConfig(
            downloadBase: ModelPaths.speakerKit,
            download: true
        )

        speakerKit = try await SpeakerKit(config)
        isInitialized = true

        Log.speakerDiarization.info("SpeakerDiarizationService — Pyannote models loaded successfully")
    }

    // MARK: - Diarization

    /// Performs speaker diarization on audio samples.
    ///
    /// - Parameter samples: 16kHz mono PCM audio samples.
    /// - Returns: Array of diarized segments with speaker indices and timings.
    /// - Throws: Error if diarization fails or service is not initialized.
    public func diarize(_ samples: [Float]) async throws -> [DiarizedSegment] {
        guard let speakerKit else {
            Log.speakerDiarization.error("SpeakerDiarizationService — not initialized")
            throw WisprError.diarizationNotInitialized
        }

        Log.speakerDiarization.debug("SpeakerDiarizationService — diarizing \(samples.count) samples")

        let result = try await speakerKit.diarize(audioArray: samples)

        Log.speakerDiarization.info("SpeakerDiarizationService — detected \(result.speakerCount) speaker(s), \(result.segments.count) segment(s)")

        // Convert SpeakerKit segments to our DiarizedSegment format
        // SpeakerKit uses speakerId (Int) which we map to monotonic indices
        var speakerIdToIndex: [Int: Int] = [:]
        var nextIndex = 0

        return result.segments.map { segment in
            let speakerId = segment.speaker.speakerId ?? -1

            // Assign monotonic index on first appearance
            if speakerIdToIndex[speakerId] == nil {
                speakerIdToIndex[speakerId] = nextIndex
                nextIndex += 1
            }

            let speakerIndex = speakerIdToIndex[speakerId] ?? 0

            return DiarizedSegment(
                speakerIndex: speakerIndex,
                startTime: TimeInterval(segment.startTime),
                endTime: TimeInterval(segment.endTime)
            )
        }
    }

    /// Merges transcription segments with diarization results.
    ///
    /// Assigns speaker indices to transcription segments based on temporal overlap.
    /// Each transcription segment gets the speaker index of the diarization segment
    /// with the largest overlap.
    ///
    /// - Parameters:
    ///   - transcriptionSegments: Segments from WhisperKit transcription.
    ///   - diarizedSegments: Segments from SpeakerKit diarization.
    /// - Returns: Transcription segments with speaker indices populated.
    public nonisolated func mergeSegments(
        transcriptionSegments: [TranscriptionSegment],
        diarizedSegments: [DiarizedSegment]
    ) -> [TranscriptionSegment] {
        guard !diarizedSegments.isEmpty else {
            return transcriptionSegments
        }

        return transcriptionSegments.map { segment in
            // Find the diarized segment with the largest overlap
            let bestSpeaker = bestSpeakerForSegment(segment, diarizedSegments: diarizedSegments)

            return TranscriptionSegment(
                speakerIndex: bestSpeaker,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text,
                words: segment.words
            )
        }
    }

    /// Finds the speaker index with the largest temporal overlap with a segment.
    private nonisolated func bestSpeakerForSegment(
        _ segment: TranscriptionSegment,
        diarizedSegments: [DiarizedSegment]
    ) -> Int? {
        var speakerOverlap: [Int: TimeInterval] = [:]

        for diarized in diarizedSegments {
            let overlapStart = max(segment.startTime, diarized.startTime)
            let overlapEnd = min(segment.endTime, diarized.endTime)
            let overlap = max(0, overlapEnd - overlapStart)

            if overlap > 0 {
                speakerOverlap[diarized.speakerIndex, default: 0] += overlap
            }
        }

        // Return the speaker with the most overlap
        return speakerOverlap.max(by: { $0.value < $1.value })?.key
    }
}

// MARK: - Supporting Types

/// A diarized speech segment with speaker index and timing.
public nonisolated struct DiarizedSegment: Sendable, Equatable {
    public let speakerIndex: Int
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(speakerIndex: Int, startTime: TimeInterval, endTime: TimeInterval) {
        self.speakerIndex = speakerIndex
        self.startTime = startTime
        self.endTime = endTime
    }
}
