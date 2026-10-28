import AVFoundation
import Foundation
import ScoreKit

public enum TranscriberError: LocalizedError {
    case noAudioTrack
    case readFailed(String)
    case modelMissing
    case modelOutputMissing(String)

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "This file has no audio track."
        case .readFailed(let why): return "Couldn't read the audio: \(why)"
        case .modelMissing: return "The Basic Pitch model (nmp.mlpackage) is missing from the app bundle."
        case .modelOutputMissing(let name): return "The transcription model didn't return '\(name)'."
        }
    }
}

/// Decodes the first audio track of any AVFoundation-readable file (MP4, MOV, M4A, MP3, WAV, AIFF…)
/// to mono Float32 at Basic Pitch's 22,050 Hz.
public enum AudioDecoder {
    public static func decode(url: URL, sampleRate: Int = BasicPitch.sampleRate) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw TranscriberError.noAudioTrack }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TranscriberError.readFailed("unsupported audio format") }
        reader.add(output)
        guard reader.startReading() else {
            throw TranscriberError.readFailed(reader.error?.localizedDescription ?? "unknown error")
        }

        var samples: [Float] = []
        if let duration = try? await asset.load(.duration), duration.seconds.isFinite {
            samples.reserveCapacity(Int(duration.seconds * Double(sampleRate)) + sampleRate)
        }
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                           destination: raw.baseAddress! + start * MemoryLayout<Float>.size)
            }
            if status != kCMBlockBufferNoErr { throw TranscriberError.readFailed("CoreMedia error \(status)") }
            try Task.checkCancellation()
        }
        if reader.status == .failed {
            throw TranscriberError.readFailed(reader.error?.localizedDescription ?? "unknown error")
        }
        return samples
    }
}
