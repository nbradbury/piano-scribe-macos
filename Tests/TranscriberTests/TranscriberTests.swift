#if canImport(CoreML) && canImport(AVFoundation)
import XCTest
import ScoreKit
import Transcriber

/// macOS-only tests: Core ML model parity with the ONNX reference, and a full MP4 -> score run.
final class TranscriberTests: XCTestCase {
    func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent(name)
    }

    func floats(_ name: String) throws -> [Float] {
        let data = try Data(contentsOf: fixture(name))
        var out = [Float](repeating: 0, count: data.count / 4)
        _ = out.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return out
    }

    func testCoreMLMatchesONNXReference() async throws {
        let model = try await BasicPitchModel.load()
        let audio = try floats("window3_audio.bin")
        let ref = try floats("window3_onnx.bin")
        let n = 172 * 88
        let out = try audio.withUnsafeBufferPointer { try model.predict(window: $0) }
        XCTAssertEqual(out.note.count, n)
        var maxDiff: Float = 0, sumDiff: Float = 0
        for i in 0..<n {
            let d1 = abs(out.note[i] - ref[i]), d2 = abs(out.onset[i] - ref[n + i])
            maxDiff = max(maxDiff, max(d1, d2))
            sumDiff += d1 + d2
        }
        let mean = sumDiff / Float(2 * n)
        print("Core ML vs ONNX: max |diff| = \(maxDiff), mean |diff| = \(mean)")
        XCTAssertLessThan(mean, 0.01)
        XCTAssertLessThan(maxDiff, 0.15)
    }

    func testEndToEndOnTestVideo() async throws {
        let audio = try await AudioDecoder.decode(url: fixture("ode-to-joy-test.mp4"))
        XCTAssertEqual(Double(audio.count) / 22050, 21.8, accuracy: 0.2)
        let model = try await BasicPitchModel.load()
        let act = try model.activations(for: audio)
        let notes = BasicPitch.decode(act)
        XCTAssertGreaterThan(notes.count, 60)
        var opt = NotationOptions()
        opt.title = "Ode to Joy"
        let score = try ScoreBuilder.build(notes: notes, options: opt)
        XCTAssertEqual(score.keyFifths, 1)            // G major
        XCTAssertEqual(score.tempo, 94, accuracy: 3)  // played at ~96 with drift
        let rh = score.staves[0].flatMap { $0 }.filter { $0.kind == .note && !$0.tieStop }.flatMap(\.pitches)
        XCTAssertEqual(Array(rh.prefix(12)), [71, 71, 72, 74, 74, 72, 71, 69, 67, 67, 69, 71])
        let xml = MusicXMLWriter.write(score)
        XCTAssertTrue(xml.contains("<fifths>1</fifths>"))
    }
}
#endif
