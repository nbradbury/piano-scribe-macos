import XCTest
@testable import ScoreKit

/// Golden tests: fixtures were produced by the Python reference implementation in Tests/Reference
/// (a numpy port of Spotify's basic-pitch post-processing plus PianoScribe's notation engine),
/// run on a synthesized piano recording of "Ode to Joy".
final class ScoreKitTests: XCTestCase {

    // MARK: helpers

    func fixtureURL(_ name: String) throws -> URL {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return dir.appendingPathComponent(name)
    }

    func json(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureURL(name))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func loadActivations() throws -> ModelActivations {
        let meta = try json("ode_decoder_expected.json")
        let frames = meta["frames"] as! Int
        let data = try Data(contentsOf: fixtureURL("ode_activations.bin"))
        var floats = [Float](repeating: 0, count: data.count / 4)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        let n = frames * 88
        return ModelActivations(frameCount: frames, note: Array(floats[0..<n]), onset: Array(floats[n..<(2 * n)]))
    }

    func events(_ list: [[String: Any]]) -> [NoteEvent] {
        list.map { NoteEvent(start: $0["start"] as! Double, end: $0["end"] as! Double,
                             pitch: $0["pitch"] as! Int, amplitude: $0["amplitude"] as! Double) }
    }

    // MARK: Basic Pitch pre/post-processing

    func testWindowingMatchesReference() throws {
        let ref = try json("windowing_expected.json")
        for c in ref["cases"] as! [[String: Any]] {
            let length = c["length"] as! Int
            XCTAssertEqual(BasicPitch.windowCount(sampleCount: length), c["windows"] as! Int, "windows for \(length)")
            XCTAssertEqual(BasicPitch.unwrappedFrameCount(sampleCount: length), c["frames"] as! Int, "frames for \(length)")
        }
        let times = BasicPitch.frameTimes(400)
        let expected = ref["frameTimes400"] as! [Double]
        for (a, b) in zip(times, expected) { XCTAssertEqual(a, b, accuracy: 1e-9) }
    }

    func testWindowContents() {
        let audio = (0..<100_000).map { Float($0) }
        let w0 = BasicPitch.window(0, from: audio)
        XCTAssertEqual(w0[3839], 0)
        XCTAssertEqual(w0[3840], 0)      // audio[0]
        XCTAssertEqual(w0[3841], 1)
        let w1 = BasicPitch.window(1, from: audio)
        XCTAssertEqual(w1[0], Float(36164 - 3840))
        let w2 = BasicPitch.window(2, from: audio)
        XCTAssertEqual(w2[BasicPitch.windowSamples - 1], 0) // zero padded past the end
    }

    func testUnwrapper() {
        var u = BasicPitch.Unwrapper(sampleCount: 80_000)
        for w in 0..<BasicPitch.windowCount(sampleCount: 80_000) {
            let frame = (0..<(172 * 88)).map { Float(w * 1000 + $0 / 88) }
            u.append(windowNote: frame, windowOnset: frame)
        }
        let a = u.finish()
        XCTAssertEqual(a.frameCount, BasicPitch.unwrappedFrameCount(sampleCount: 80_000))
        XCTAssertEqual(a.note[0], 15)             // first kept frame of window 0
        XCTAssertEqual(a.note[142 * 88], 1015)    // first kept frame of window 1
    }

    func testNoteDecodingMatchesReference() throws {
        let act = try loadActivations()
        let ref = try json("ode_decoder_expected.json")
        for c in ref["cases"] as! [[String: Any]] {
            var opt = DecodingOptions()
            opt.onsetThreshold = c["onsetThreshold"] as! Double
            opt.frameThreshold = c["frameThreshold"] as! Double
            opt.minNoteLengthMs = c["minNoteLengthMs"] as! Double
            opt.melodiaTrick = c["melodiaTrick"] as! Bool
            opt.inferOnsets = c["inferOnsets"] as! Bool
            XCTAssertEqual(opt.minNoteLengthFrames, c["minNoteLengthFrames"] as! Int)

            let raw = BasicPitch.decodeFrames(act, options: opt)
            let expected = c["raw"] as! [[String: Any]]
            XCTAssertEqual(raw.count, expected.count, "note count (onset \(opt.onsetThreshold))")
            for (r, e) in zip(raw, expected) {
                XCTAssertEqual(r.startFrame, e["startFrame"] as! Int)
                XCTAssertEqual(r.endFrame, e["endFrame"] as! Int)
                XCTAssertEqual(r.pitch, e["pitch"] as! Int)
                XCTAssertEqual(r.amplitude, e["amplitude"] as! Double, accuracy: 1e-6)
            }
            let ev = BasicPitch.decode(act, options: opt)
            for (a, b) in zip(ev, events(c["events"] as! [[String: Any]])) {
                XCTAssertEqual(a.start, b.start, accuracy: 1e-9)
                XCTAssertEqual(a.end, b.end, accuracy: 1e-9)
            }
        }
    }

    // MARK: Notation

    func options(_ o: [String: Any]) -> NotationOptions {
        var opt = NotationOptions()
        opt.title = o["title"] as! String
        opt.timeSignature = TimeSignature(rawValue: o["timeSignature"] as! String)!
        opt.tempo = o["bpm"] as? Double
        opt.grid = GridResolution(rawValue: o["grid"] as! String)!
        opt.hands = (o["hands"] as! String) == "fixed" ? .fixed(splitPitch: o["splitPitch"] as! Int) : .automatic
        opt.keyFifths = o["keyFifths"] as? Int
        opt.removeOvertones = o["removeOvertones"] as! Bool
        return opt
    }

    func testScoresMatchReference() throws {
        let ref = try json("notation_expected.json")
        let ode = try json("ode_decoder_expected.json")
        let modelEvents = events((ode["cases"] as! [[String: Any]])[0]["events"] as! [[String: Any]])
        let truthEvents = events(ref["truthEvents"] as! [[String: Any]])
        for c in ref["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let input = (c["input"] as! String) == "truth" ? truthEvents : modelEvents
            let score = try ScoreBuilder.build(notes: input, options: options(c["options"] as! [String: Any]))

            // Robust checks first (these should hold even if floating point differs in the last ulp).
            XCTAssertEqual(score.tempo, c["bpm"] as! Double, accuracy: 0.051, name)
            XCTAssertEqual(score.keyFifths, c["fifths"] as! Int, name)
            XCTAssertEqual(score.mode, c["mode"] as! String, name)
            XCTAssertEqual(score.measureCount, c["measures"] as! Int, name)
            let rh = score.staves[0].flatMap { $0 }.filter { $0.kind == .note && !$0.tieStop }.flatMap(\.pitches)
            XCTAssertEqual(rh, c["rhPitches"] as! [Int], name)

            // Exact MusicXML match with the reference implementation.
            let xml = MusicXMLWriter.write(score)
            let expected = try String(contentsOf: fixtureURL("\(name).musicxml"), encoding: .utf8)
            if xml != expected {
                let a = xml.split(separator: "\n"), b = expected.split(separator: "\n")
                let firstDiff = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }
                XCTFail("\(name): MusicXML differs at line \(firstDiff.map { $0.offset + 1 } ?? min(a.count, b.count))\n got: \(firstDiff?.element.0 ?? "")\nwant: \(firstDiff?.element.1 ?? "")")
            }
        }
    }

    func testSpelling() {
        func s(_ p: Int, _ f: Int) -> String {
            let x = Notation.spell(p, fifths: f)
            return "\(x.step)\(x.alter == 1 ? "#" : x.alter == -1 ? "b" : x.alter == 2 ? "##" : x.alter == -2 ? "bb" : "")\(x.octave)"
        }
        XCTAssertEqual(s(60, 0), "C4")
        XCTAssertEqual(s(61, 0), "C#4")
        XCTAssertEqual(s(61, -3), "Db4")
        XCTAssertEqual(s(66, 1), "F#4")
        XCTAssertEqual(s(70, -1), "Bb4")
        XCTAssertEqual(s(65, 6), "E#4")   // F#-major leading tone
        XCTAssertEqual(s(59, -6), "Cb4")  // Gb-major subdominant
        XCTAssertEqual(s(21, 0), "A0")
    }

    func testKeyDetectionOnScale() {
        // D major scale, long tonic
        let pitches = [62, 64, 66, 67, 69, 71, 73, 74, 62, 66, 69]
        let notes = pitches.enumerated().map { NoteEvent(start: Double($0.offset), end: Double($0.offset) + 0.9, pitch: $0.element, amplitude: 0.8) }
        let k = Notation.detectKey(notes)
        XCTAssertEqual(k.fifths, 2)
        XCTAssertEqual(k.mode, "major")
    }

    func testDecompose() {
        XCTAssertEqual(Notation.decompose(start: 0, length: 5, unitsPerBeat: 4, compound: false), [4, 1])
        XCTAssertEqual(Notation.decompose(start: 2, length: 4, unitsPerBeat: 4, compound: false), [2, 2])
        XCTAssertEqual(Notation.decompose(start: 0, length: 16, unitsPerBeat: 4, compound: false), [16])
        XCTAssertEqual(Notation.decompose(start: 0, length: 6, unitsPerBeat: 6, compound: true), [6])
    }

    func testPythonIntegerSemantics() {
        XCTAssertEqual(floorDiv(-1, 7), -1)
        XCTAssertEqual(floorMod(-1, 7), 6)
        XCTAssertEqual(floorDiv(7, 7), 1)
        XCTAssertEqual(pyRound(2.5), 2)
        XCTAssertEqual(pyRound(3.5), 4)
        XCTAssertEqual(pyRound(-0.5), 0)
    }

    // MARK: MIDI

    func testMIDIFiles() throws {
        let ref = try json("notation_expected.json")
        let truth = events(ref["truthEvents"] as! [[String: Any]])
        var opt = NotationOptions()
        opt.title = "MIDI"
        let score = try ScoreBuilder.build(notes: truth, options: opt)

        let q = [UInt8](MIDIWriter.quantized(score))
        XCTAssertEqual(Array(q[0..<4]), Array("MThd".utf8))
        XCTAssertEqual(q[9], 1)   // format 1
        XCTAssertEqual(q[11], 3)  // 3 tracks
        XCTAssertEqual(countNoteOns(q), score.notes.count)

        let p = [UInt8](MIDIWriter.performance(truth, quarterBPM: 96))
        XCTAssertEqual(p[9], 0)
        XCTAssertEqual(countNoteOns(p), truth.count)
        XCTAssertEqual(MIDIWriter.vlq(0x80), [0x81, 0x00])
        XCTAssertEqual(MIDIWriter.vlq(0x0FFFFFFF), [0xFF, 0xFF, 0xFF, 0x7F])
    }

    /// Tiny SMF parser: counts note-on events with velocity > 0.
    func countNoteOns(_ b: [UInt8]) -> Int {
        var i = 14, count = 0
        while i + 8 <= b.count {
            XCTAssertEqual(Array(b[i..<(i + 4)]), Array("MTrk".utf8))
            let len = Int(b[i + 4]) << 24 | Int(b[i + 5]) << 16 | Int(b[i + 6]) << 8 | Int(b[i + 7])
            var j = i + 8
            let end = j + len
            while j < end {
                while b[j] & 0x80 != 0 { j += 1 }   // delta time
                j += 1
                let status = b[j]
                if status == 0xFF {
                    j += 2
                    var l = 0
                    while b[j] & 0x80 != 0 { l = (l << 7) | Int(b[j] & 0x7F); j += 1 }
                    l = (l << 7) | Int(b[j]); j += 1
                    j += l
                } else if status & 0xF0 == 0x90 {
                    if b[j + 2] > 0 { count += 1 }
                    j += 3
                } else if status & 0xF0 == 0x80 {
                    j += 3
                } else if status & 0xF0 == 0xC0 {
                    j += 2
                } else {
                    XCTFail("unexpected status \(status)"); return count
                }
            }
            i = end
        }
        return count
    }
}
