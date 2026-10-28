import CoreML
import Foundation
import ScoreKit

/// Runs Spotify's Basic Pitch Core ML model over a whole recording.
public final class BasicPitchModel: @unchecked Sendable {
    private let model: MLModel
    private let inputName: String
    // Output names in the published nmp.mlpackage (see basic_pitch/inference.py).
    static let noteOutput = "Identity_1"
    static let onsetOutput = "Identity_2"
    static let cacheVersion = "icassp2022-v1"

    init(model: MLModel) {
        self.model = model
        self.inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "input_2"
    }

    /// Locates the bundled .mlpackage, compiles it once and caches the compiled model in Application Support.
    public static func load(computeUnits: MLComputeUnits = .cpuOnly) async throws -> BasicPitchModel {
        guard let packageURL = TranscriberResources.modelPackageURL else { throw TranscriberError.modelMissing }
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits   // Basic Pitch's own reference runs Core ML on CPU only

        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("PianoScribe", isDirectory: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let cached = support.appendingPathComponent("nmp-\(cacheVersion).mlmodelc", isDirectory: true)

        if fm.fileExists(atPath: cached.path), let m = try? MLModel(contentsOf: cached, configuration: config) {
            return BasicPitchModel(model: m)
        }
        let compiled = try await MLModel.compileModel(at: packageURL)
        try? fm.removeItem(at: cached)
        do {
            try fm.moveItem(at: compiled, to: cached)
            return BasicPitchModel(model: try MLModel(contentsOf: cached, configuration: config))
        } catch {
            return BasicPitchModel(model: try MLModel(contentsOf: compiled, configuration: config))
        }
    }

    /// Model output for one 43,844-sample window: row-major [172 * 88] note and onset activations.
    public func predict(window: UnsafeBufferPointer<Float>) throws -> (note: [Float], onset: [Float]) {
        let n = BasicPitch.windowSamples
        precondition(window.count == n)
        let input = try MLMultiArray(shape: [1, NSNumber(value: n), 1], dataType: .float32)
        let dst = input.dataPointer.bindMemory(to: Float.self, capacity: n)
        let stride = input.strides[1].intValue
        for i in 0..<n { dst[i * stride] = window[i] }
        let features = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: input)])
        let out = try model.prediction(from: features)
        guard let note = out.featureValue(for: Self.noteOutput)?.multiArrayValue else {
            throw TranscriberError.modelOutputMissing(Self.noteOutput)
        }
        guard let onset = out.featureValue(for: Self.onsetOutput)?.multiArrayValue else {
            throw TranscriberError.modelOutputMissing(Self.onsetOutput)
        }
        return (Self.flatten(note), Self.flatten(onset))
    }

    /// Runs every window of `audio` (22,050 Hz mono) and stitches the result.
    public func activations(for audio: [Float], progress: ((Double) -> Void)? = nil) throws -> ModelActivations {
        var unwrapper = BasicPitch.Unwrapper(sampleCount: audio.count)
        let windows = BasicPitch.windowCount(sampleCount: audio.count)
        var buffer = [Float](repeating: 0, count: BasicPitch.windowSamples)
        for w in 0..<windows {
            try Task.checkCancellation()
            buffer.withUnsafeMutableBufferPointer { BasicPitch.fillWindow(w, from: audio, into: $0) }
            let result = try buffer.withUnsafeBufferPointer { try predict(window: $0) }
            unwrapper.append(windowNote: result.note, windowOnset: result.onset)
            progress?(Double(w + 1) / Double(windows))
        }
        return unwrapper.finish()
    }

    /// Copies a [1, 172, 88] (or [172, 88]) MLMultiArray of any float type into a row-major [Float].
    static func flatten(_ a: MLMultiArray) -> [Float] {
        let shape = a.shape.map(\.intValue)
        let strides = a.strides.map(\.intValue)
        let rank = shape.count
        let rows = shape[rank - 2], cols = shape[rank - 1]
        let rs = strides[rank - 2], cs = strides[rank - 1]
        var out = [Float](repeating: 0, count: rows * cols)
        switch a.dataType {
        case .float32:
            let p = a.dataPointer.bindMemory(to: Float.self, capacity: (rows - 1) * rs + (cols - 1) * cs + 1)
            for r in 0..<rows { for c in 0..<cols { out[r * cols + c] = p[r * rs + c * cs] } }
        case .double:
            let p = a.dataPointer.bindMemory(to: Double.self, capacity: (rows - 1) * rs + (cols - 1) * cs + 1)
            for r in 0..<rows { for c in 0..<cols { out[r * cols + c] = Float(p[r * rs + c * cs]) } }
        default:
            // Float16 and anything else: go through NSNumber (slower, but always correct).
            let lead = [NSNumber](repeating: 0, count: rank - 2)
            for r in 0..<rows {
                for c in 0..<cols {
                    out[r * cols + c] = a[lead + [NSNumber(value: r), NSNumber(value: c)]].floatValue
                }
            }
        }
        return out
    }
}

enum TranscriberResources {
    /// Finds nmp.mlpackage both in a packaged .app (Contents/Resources/<bundle>) and in SwiftPM/Xcode builds.
    static var modelPackageURL: URL? {
        let bundleName = "PianoScribe_Transcriber.bundle"
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()]
        for root in roots.compactMap({ $0 }) {
            if let b = Bundle(url: root.appendingPathComponent(bundleName)),
               let url = b.url(forResource: "nmp", withExtension: "mlpackage") {
                return url
            }
        }
        return Bundle.module.url(forResource: "nmp", withExtension: "mlpackage")
    }
}
