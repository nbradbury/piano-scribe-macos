import Foundation

/// A detected note, in seconds. `amplitude` is 0...1 (mean model activation).
public struct NoteEvent: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var pitch: Int
    public var amplitude: Double

    public init(start: Double, end: Double, pitch: Int, amplitude: Double) {
        self.start = start
        self.end = end
        self.pitch = pitch
        self.amplitude = amplitude
    }
}

/// Unwrapped Basic Pitch activations for a whole recording.
/// Both matrices are row-major `[frame * 88 + pitchIndex]`.
public struct ModelActivations: Sendable {
    public var frameCount: Int
    public var note: [Float]
    public var onset: [Float]

    public init(frameCount: Int, note: [Float], onset: [Float]) {
        precondition(note.count == frameCount * BasicPitch.pitchCount && onset.count == note.count)
        self.frameCount = frameCount
        self.note = note
        self.onset = onset
    }

    public var duration: Double { Double(frameCount) * Double(BasicPitch.fftHop) / Double(BasicPitch.sampleRate) }
}

/// Options for turning model activations into notes (same meaning and defaults as Basic Pitch).
public struct DecodingOptions: Hashable, Sendable {
    public var onsetThreshold: Double = 0.5
    public var frameThreshold: Double = 0.3
    public var minNoteLengthMs: Double = 127.7
    public var melodiaTrick: Bool = true
    public var inferOnsets: Bool = true
    /// Optional MIDI pitch limits (inclusive). nil = full piano range.
    public var lowestPitch: Int? = nil
    public var highestPitch: Int? = nil

    public init() {}

    public var minNoteLengthFrames: Int {
        Int((minNoteLengthMs / 1000.0 * (Double(BasicPitch.sampleRate) / Double(BasicPitch.fftHop))).rounded(.toNearestOrEven))
    }
}

public enum TimeSignature: String, CaseIterable, Identifiable, Hashable, Sendable {
    case fourFour = "4/4"
    case threeFour = "3/4"
    case twoFour = "2/4"
    case sixEight = "6/8"

    public var id: String { rawValue }

    /// Beats per measure as felt by the beat tracker (6/8 = 2 dotted-quarter beats).
    public var beatsPerMeasure: Int {
        switch self {
        case .fourFour: return 4
        case .threeFour: return 3
        case .twoFour, .sixEight: return 2
        }
    }
    /// Numbers written in the time signature.
    public var written: (beats: Int, beatType: Int) {
        switch self {
        case .fourFour: return (4, 4)
        case .threeFour: return (3, 4)
        case .twoFour: return (2, 4)
        case .sixEight: return (6, 8)
        }
    }
    /// Sixteenth notes per tracked beat.
    public var unitsPerBeat: Int { self == .sixEight ? 6 : 4 }
    public var isCompound: Bool { self == .sixEight }
}

public enum GridResolution: String, CaseIterable, Identifiable, Hashable, Sendable {
    case sixteenth = "16th"
    case eighth = "8th"
    public var id: String { rawValue }
    var step: Int { self == .sixteenth ? 1 : 2 }
}

public enum HandSplitMode: Hashable, Sendable {
    case automatic
    case fixed(splitPitch: Int)   // pitches >= splitPitch go to the treble staff
}

public struct NotationOptions: Hashable, Sendable {
    public var title: String = "Transcription"
    public var timeSignature: TimeSignature = .fourFour
    /// Beats per minute of the tracked beat (quarter note, or dotted quarter in 6/8). nil = detect.
    public var tempo: Double? = nil
    public var grid: GridResolution = .sixteenth
    public var hands: HandSplitMode = .automatic
    /// Key signature in fifths (-7...7). nil = detect.
    public var keyFifths: Int? = nil
    public var removeOvertones: Bool = true

    public init() {}
}

/// A note after quantization. Positions/durations are in sixteenth-note units from the start of measure 1.
public struct QuantizedNote: Hashable, Sendable {
    public var start: Int
    public var duration: Int
    public var pitch: Int
    public var amplitude: Double
    /// 1 = treble (right hand), 2 = bass (left hand)
    public var staff: Int
}

/// One printable symbol (note/chord or rest) inside a measure of one staff.
public struct Piece: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case note, rest }
    public var kind: Kind
    public var start: Int          // units from the start of the measure
    public var units: Int          // sixteenth units
    public var isWholeMeasureRest: Bool
    public var pitches: [Int]      // ascending, empty for rests
    public var tieStart: Bool
    public var tieStop: Bool
    public var beam1: String? = nil
    public var beam2: String? = nil
}

public struct Score: Sendable {
    public var title: String
    public var keyFifths: Int
    public var mode: String               // "major" / "minor"
    public var timeSignature: TimeSignature
    public var measureLength: Int         // units
    public var tempo: Double              // tracked-beat BPM
    public var quarterTempo: Double       // quarter-note BPM (for MIDI)
    public var measureCount: Int
    /// staves[0] = treble, staves[1] = bass; each is [measure][piece]
    public var staves: [[[Piece]]]
    public var notes: [QuantizedNote]
    public var beatTimes: [Double]
}

public enum ScoreKitError: Error, LocalizedError {
    case noNotes
    public var errorDescription: String? {
        switch self {
        case .noNotes: return "No notes were detected in this recording."
        }
    }
}

// MARK: - Python-compatible integer helpers

@inline(__always) func floorDiv(_ a: Int, _ b: Int) -> Int {
    let q = a / b
    return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q
}

@inline(__always) func floorMod(_ a: Int, _ b: Int) -> Int {
    let r = a % b
    return (r != 0 && ((r < 0) != (b < 0))) ? r + b : r
}

/// Python's round() (banker's rounding) to Int.
@inline(__always) func pyRound(_ x: Double) -> Int {
    Int(x.rounded(.toNearestOrEven))
}
