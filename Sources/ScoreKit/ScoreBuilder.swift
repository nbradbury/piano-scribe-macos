import Foundation

/// Notes (seconds) -> engraved grand-staff Score.
public enum ScoreBuilder {
    public static func build(notes input: [NoteEvent], options: NotationOptions) throws -> Score {
        let ts = options.timeSignature
        let upb = ts.unitsPerBeat
        let compound = ts.isCompound
        var notes = input.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            if $0.pitch != $1.pitch { return $0.pitch < $1.pitch }
            return $0.amplitude < $1.amplitude
        }
        if options.removeOvertones { notes = Rhythm.removeOvertones(notes) }
        guard !notes.isEmpty else { throw ScoreKitError.noNotes }

        let bpm = options.tempo ?? Rhythm.estimateTempo(notes, compound: compound)
        let beats = Rhythm.trackBeats(notes, bpm: bpm)
        var q = Rhythm.quantize(notes, beats: beats, unitsPerBeat: upb, grid: options.grid.step)

        let c = Rhythm.chooseDownbeat(q, unitsPerBeat: upb, beatsPerMeasure: ts.beatsPerMeasure)
        let measureLength = upb * ts.beatsPerMeasure
        var shift = c * upb
        let minU = q.map(\.start).min()!
        while minU - shift < 0 { shift -= measureLength }
        for i in q.indices { q[i].start -= shift }
        let firstMeasure = floorDiv(q.map(\.start).min()!, measureLength)
        for i in q.indices { q[i].start -= firstMeasure * measureLength }

        let key: (fifths: Int, mode: String)
        if let f = options.keyFifths { key = (f, "major") } else { key = Notation.detectKey(notes) }

        Notation.splitHands(&q, mode: options.hands)
        let end = q.map { $0.start + $0.duration }.max()!
        let measureCount = max(1, (end + measureLength - 1) / measureLength)
        let staves = [1, 2].map { st in
            Notation.buildMeasures(Notation.staffEvents(q, staff: st, gapFill: upb / 2),
                                   measureLength: measureLength, measureCount: measureCount,
                                   unitsPerBeat: upb, compound: compound)
        }
        return Score(title: options.title, keyFifths: key.fifths, mode: key.mode, timeSignature: ts,
                     measureLength: measureLength, tempo: bpm, quarterTempo: compound ? bpm * 1.5 : bpm,
                     measureCount: measureCount, staves: staves, notes: q, beatTimes: beats)
    }
}
