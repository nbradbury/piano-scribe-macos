import Foundation

/// Constants and pre/post-processing for Spotify's Basic Pitch model (ICASSP 2022, Apache-2.0).
/// Ported from basic_pitch/inference.py and basic_pitch/note_creation.py.
public enum BasicPitch {
    public static let sampleRate = 22050
    public static let fftHop = 256
    public static let windowSamples = sampleRate * 2 - fftHop          // 43844
    public static let framesPerWindow = (sampleRate / fftHop) * 2      // 172
    public static let overlapFrames = 30
    public static let overlapSamples = overlapFrames * fftHop          // 7680
    public static let hopSamples = windowSamples - overlapSamples      // 36164
    public static let pitchCount = 88
    public static let midiOffset = 21
    static let maxFreqIndex = 87
    static let magicAlignmentOffset = 0.0018

    // MARK: Windowing

    /// Number of model windows needed for a recording of `sampleCount` samples.
    public static func windowCount(sampleCount: Int) -> Int {
        let padded = sampleCount + overlapSamples / 2
        return max(1, (padded + hopSamples - 1) / hopSamples)
    }

    /// Fill `buffer` (length `windowSamples`) with window `index` of the padded signal.
    public static func fillWindow(_ index: Int, from audio: [Float], into buffer: UnsafeMutableBufferPointer<Float>) {
        precondition(buffer.count == windowSamples)
        let pad = overlapSamples / 2
        let start = index * hopSamples - pad   // position in the original audio
        for i in 0..<windowSamples {
            let j = start + i
            buffer[i] = (j >= 0 && j < audio.count) ? audio[j] : 0
        }
    }

    public static func window(_ index: Int, from audio: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: windowSamples)
        out.withUnsafeMutableBufferPointer { fillWindow(index, from: audio, into: $0) }
        return out
    }

    /// Number of frames kept after unwrapping.
    public static func unwrappedFrameCount(sampleCount: Int) -> Int {
        Int(Double(sampleCount) / Double(hopSamples) * Double(framesPerWindow - overlapFrames))
    }

    /// Collects per-window outputs and stitches them (drops 15 overlap frames on each side).
    public struct Unwrapper {
        public let sampleCount: Int
        public private(set) var note: [Float] = []
        public private(set) var onset: [Float] = []

        public init(sampleCount: Int) {
            self.sampleCount = sampleCount
            let windows = BasicPitch.windowCount(sampleCount: sampleCount)
            note.reserveCapacity(windows * 142 * pitchCount)
            onset.reserveCapacity(windows * 142 * pitchCount)
        }

        /// `windowNote` / `windowOnset`: row-major [172 * 88].
        public mutating func append(windowNote: [Float], windowOnset: [Float]) {
            let half = overlapFrames / 2
            let lo = half * pitchCount
            let hi = (framesPerWindow - half) * pitchCount
            note.append(contentsOf: windowNote[lo..<hi])
            onset.append(contentsOf: windowOnset[lo..<hi])
        }

        public func finish() -> ModelActivations {
            let frames = min(BasicPitch.unwrappedFrameCount(sampleCount: sampleCount), note.count / pitchCount)
            return ModelActivations(frameCount: frames,
                                    note: Array(note[0..<(frames * pitchCount)]),
                                    onset: Array(onset[0..<(frames * pitchCount)]))
        }
    }

    /// Frame index -> seconds (includes Basic Pitch's per-window alignment correction).
    public static func frameTimes(_ count: Int) -> [Double] {
        let windowOffset = (Double(fftHop) / Double(sampleRate))
            * (Double(framesPerWindow) - Double(windowSamples) / Double(fftHop)) + magicAlignmentOffset
        return (0..<count).map { i in
            let original = Double(i) * Double(fftHop) / Double(sampleRate)
            let windowNumber = (Double(i) / Double(framesPerWindow)).rounded(.down)
            return original - windowOffset * windowNumber
        }
    }

    // MARK: Note decoding

    public struct RawNote: Hashable {
        public var startFrame: Int
        public var endFrame: Int
        public var pitch: Int
        public var amplitude: Double
    }

    public static func decode(_ act: ModelActivations, options: DecodingOptions = DecodingOptions()) -> [NoteEvent] {
        let raw = decodeFrames(act, options: options)
        let times = frameTimes(act.frameCount)
        return raw.map { NoteEvent(start: times[$0.startFrame], end: times[$0.endFrame], pitch: $0.pitch, amplitude: $0.amplitude) }
    }

    /// Port of `output_to_notes_polyphonic`.
    public static func decodeFrames(_ act: ModelActivations, options: DecodingOptions = DecodingOptions()) -> [RawNote] {
        let n = act.frameCount
        let P = pitchCount
        guard n > 2 else { return [] }
        var frames = act.note.map { Double($0) }
        var onsets = act.onset.map { Double($0) }

        // constrain_frequency
        let minIdx = options.lowestPitch.map { max(0, $0 - midiOffset) } ?? 0
        let maxIdx = options.highestPitch.map { min(P, $0 - midiOffset + 1) } ?? P
        if minIdx > 0 || maxIdx < P {
            for t in 0..<n {
                for f in 0..<P where f < minIdx || f >= maxIdx {
                    frames[t * P + f] = 0
                    onsets[t * P + f] = 0
                }
            }
        }

        if options.inferOnsets {
            onsets = inferredOnsets(onsets: onsets, frames: frames, frameCount: n)
        }

        // peaks along time (scipy.signal.argrelmax, axis 0, strict), iterate backwards in time
        var onsetList: [(Int, Int)] = []
        for t in 1..<(n - 1) {
            for f in 0..<P {
                let v = onsets[t * P + f]
                if v > onsets[(t - 1) * P + f] && v > onsets[(t + 1) * P + f] && v >= options.onsetThreshold {
                    onsetList.append((t, f))
                }
            }
        }
        onsetList.reverse()

        let energyTol = 11
        let thresh = options.frameThreshold
        let minLen = options.minNoteLengthFrames
        var remaining = frames
        var notes: [RawNote] = []

        func meanFrames(_ s: Int, _ e: Int, _ f: Int) -> Double {
            var acc = 0.0
            for t in s..<e { acc += frames[t * P + f] }
            return acc / Double(e - s)
        }

        for (s, f) in onsetList {
            if s >= n - 1 { continue }
            var i = s + 1
            var k = 0
            while i < n - 1 && k < energyTol {
                k = remaining[i * P + f] < thresh ? k + 1 : 0
                i += 1
            }
            i -= k
            if i - s <= minLen { continue }
            for t in s..<i {
                remaining[t * P + f] = 0
                if f < maxFreqIndex { remaining[t * P + f + 1] = 0 }
                if f > 0 { remaining[t * P + f - 1] = 0 }
            }
            notes.append(RawNote(startFrame: s, endFrame: i, pitch: f + midiOffset, amplitude: meanFrames(s, i, f)))
        }

        if options.melodiaTrick {
            // Equivalent to repeated np.argmax(remaining) (first index of the maximum), but with a
            // per-frame max cache: values only ever get zeroed, so only touched rows need rescanning.
            var rowMax = [Double](repeating: -Double.infinity, count: n)
            var rowArg = [Int](repeating: 0, count: n)
            var dirty = [Bool](repeating: true, count: n)
            func refresh(_ t: Int) {
                var b = -Double.infinity
                var a = 0
                for f in 0..<P where remaining[t * P + f] > b {
                    b = remaining[t * P + f]
                    a = f
                }
                rowMax[t] = b
                rowArg[t] = a
                dirty[t] = false
            }
            while true {
                var best = -Double.infinity
                var bestRow = 0
                for t in 0..<n {
                    if dirty[t] { refresh(t) }
                    if rowMax[t] > best {
                        best = rowMax[t]
                        bestRow = t
                    }
                }
                if !(best > thresh) { break }
                let iMid = bestRow
                let f = rowArg[bestRow]
                remaining[iMid * P + f] = 0
                dirty[iMid] = true

                var i = iMid + 1
                var k = 0
                while i < n - 1 && k < energyTol {
                    k = remaining[i * P + f] < thresh ? k + 1 : 0
                    remaining[i * P + f] = 0
                    if f < maxFreqIndex { remaining[i * P + f + 1] = 0 }
                    if f > 0 { remaining[i * P + f - 1] = 0 }
                    dirty[i] = true
                    i += 1
                }
                let iEnd = i - 1 - k

                i = iMid - 1
                k = 0
                while i > 0 && k < energyTol {
                    k = remaining[i * P + f] < thresh ? k + 1 : 0
                    remaining[i * P + f] = 0
                    if f < maxFreqIndex { remaining[i * P + f + 1] = 0 }
                    if f > 0 { remaining[i * P + f - 1] = 0 }
                    dirty[i] = true
                    i -= 1
                }
                let iStart = i + 1 + k

                if iEnd - iStart <= minLen { continue }
                notes.append(RawNote(startFrame: iStart, endFrame: iEnd, pitch: f + midiOffset,
                                     amplitude: meanFrames(iStart, iEnd, f)))
            }
        }
        return notes
    }

    /// Port of `get_infered_onsets` (n_diff = 2).
    static func inferredOnsets(onsets: [Double], frames: [Double], frameCount n: Int) -> [Double] {
        let P = pitchCount
        let nDiff = 2
        var diff = [Double](repeating: 0, count: n * P)
        var maxDiff = 0.0
        for t in 0..<n {
            for f in 0..<P {
                var m = Double.infinity
                for d in 1...nDiff {
                    let prev = t - d >= 0 ? frames[(t - d) * P + f] : 0
                    m = min(m, frames[t * P + f] - prev)
                }
                if m < 0 || t < nDiff { m = 0 }
                diff[t * P + f] = m
                maxDiff = max(maxDiff, m)
            }
        }
        let maxOnset = onsets.max() ?? 0
        var out = onsets
        for i in 0..<out.count {
            let scaled = maxDiff > 0 ? maxOnset * diff[i] / maxDiff : diff[i]
            out[i] = max(onsets[i], scaled)
        }
        return out
    }
}
