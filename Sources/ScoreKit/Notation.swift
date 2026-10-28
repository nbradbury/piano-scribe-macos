import Foundation

/// Key detection, pitch spelling, hand assignment and measure layout.
public enum Notation {
    static let kkMajor = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let kkMinor = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
    static let majorFifths = [0, -5, 2, -3, 4, -1, 6, 1, -4, 3, -2, 5]

    // MARK: Key

    /// Krumhansl–Kessler key finding. Returns (fifths, "major"|"minor").
    public static func detectKey(_ notes: [NoteEvent]) -> (fifths: Int, mode: String) {
        var hist = [Double](repeating: 0, count: 12)
        for n in notes { hist[floorMod(n.pitch, 12)] += (n.end - n.start) * n.amplitude }
        var sum = 0.0
        for h in hist { sum += h }
        if sum == 0 { return (0, "major") }
        func corr(_ x: [Double], _ y: [Double]) -> Double {
            var sx = 0.0, sy = 0.0
            for v in x { sx += v }
            for v in y { sy += v }
            let mx = sx / 12, my = sy / 12
            var num = 0.0, dx = 0.0, dy = 0.0
            for i in 0..<12 { num += (x[i] - mx) * (y[i] - my) }
            for i in 0..<12 { dx += (x[i] - mx) * (x[i] - mx) }
            for i in 0..<12 { dy += (y[i] - my) * (y[i] - my) }
            let den = (dx * dy).squareRoot()
            return den > 0 ? num / den : 0
        }
        var best = (r: -2.0, tonic: 0, mode: "major")
        for tonic in 0..<12 {
            let rot = (0..<12).map { hist[(tonic + $0) % 12] }
            for (mode, prof) in [("major", kkMajor), ("minor", kkMinor)] {
                let r = corr(rot, prof)
                if r > best.r { best = (r, tonic, mode) }
            }
        }
        let fifths = best.mode == "major" ? majorFifths[best.tonic] : majorFifths[(best.tonic + 3) % 12]
        return (fifths, best.mode)
    }

    public struct Spelling: Hashable {
        public var step: Character
        public var alter: Int
        public var octave: Int
    }

    /// Spell a MIDI pitch with the line-of-fifths position closest to the key.
    public static func spell(_ pitch: Int, fifths: Int) -> Spelling {
        let pc = floorMod(pitch, 12)
        let center = fifths + 2
        let base = (7 * pc) % 12
        var bestPos = 0
        var bestKey: (Int, Int)? = nil
        for k in -2...2 {
            let q = base + 12 * k
            let key = (abs(q - center), fifths >= 0 ? -q : q)
            if bestKey == nil || key < bestKey! {
                bestKey = key
                bestPos = q
            }
        }
        let letters = Array("FCGDAEB")
        let step = letters[floorMod(bestPos + 1, 7)]
        let alter = floorDiv(bestPos + 1, 7)
        let natural = pitch - alter
        let octave = floorDiv(natural, 12) - 1
        return Spelling(step: step, alter: alter, octave: octave)
    }

    static func keyAlters(_ fifths: Int) -> [Character: Int] {
        var alters: [Character: Int] = [:]
        for s in "CDEFGAB" { alters[s] = 0 }
        if fifths > 0 {
            for s in Array("FCGDAEB").prefix(fifths) { alters[s] = 1 }
        } else if fifths < 0 {
            for s in Array("BEADGCF").prefix(-fifths) { alters[s] = -1 }
        }
        return alters
    }

    // MARK: Hands

    public static func splitHands(_ notes: inout [QuantizedNote], mode: HandSplitMode) {
        var groups: [Int: [Int]] = [:]          // start -> indices into notes
        for (i, n) in notes.enumerated() { groups[n.start, default: []].append(i) }
        var rhC = 67.0, lhC = 48.0
        for start in groups.keys.sorted() {
            let g = groups[start]!.sorted { notes[$0].pitch < notes[$1].pitch }
            if case .fixed(let split) = mode {
                for i in g { notes[i].staff = notes[i].pitch >= split ? 1 : 2 }
                continue
            }
            var bestK = 0
            var bestCost = 1e18
            for k in 0...g.count {
                let lh = g[0..<k].map { Double(notes[$0].pitch) }
                let rh = g[k...].map { Double(notes[$0].pitch) }
                var cost = 0.0
                var a = 0.0
                for p in lh { a += abs(p - lhC) }
                var b = 0.0
                for p in rh { b += abs(p - rhC) }
                cost = a + b
                for hand in [lh, rh] where !hand.isEmpty {
                    let span = hand[hand.count - 1] - hand[0]
                    if span > 12 { cost += 10 * (span - 12) }
                    if hand.count > 5 { cost += 20 * Double(hand.count - 5) }
                }
                if cost < bestCost { bestCost = cost; bestK = k }
            }
            let lh = Array(g[0..<bestK]), rh = Array(g[bestK...])
            for i in lh { notes[i].staff = 2 }
            for i in rh { notes[i].staff = 1 }
            if !rh.isEmpty {
                var s = 0.0
                for i in rh { s += Double(notes[i].pitch) }
                rhC = 0.7 * rhC + 0.3 * (s / Double(rh.count))
            } else {
                rhC = 0.9 * rhC + 0.1 * 67
            }
            if !lh.isEmpty {
                var s = 0.0
                for i in lh { s += Double(notes[i].pitch) }
                lhC = 0.7 * lhC + 0.3 * (s / Double(lh.count))
            } else {
                lhC = 0.9 * lhC + 0.1 * 48
            }
            if rhC < lhC + 7 {
                let mid = (rhC + lhC) / 2
                rhC = mid + 3.5
                lhC = mid - 3.5
            }
        }
    }

    // MARK: Measures

    static let repSimple = [16, 12, 8, 6, 4, 3, 2, 1]
    static let repCompound = [12, 9, 6, 4, 3, 2, 1]
    static let typeFor: [Int: (String, Int)] = [1: ("16th", 0), 2: ("eighth", 0), 3: ("eighth", 1), 4: ("quarter", 0),
                                                6: ("quarter", 1), 8: ("half", 0), 9: ("quarter", 2), 12: ("half", 1),
                                                16: ("whole", 0)]

    struct StaffEvent { var start: Int; var duration: Int; var pitches: [Int] }

    static func staffEvents(_ notes: [QuantizedNote], staff: Int, gapFill: Int) -> [StaffEvent] {
        var groups: [Int: [QuantizedNote]] = [:]
        for n in notes where n.staff == staff { groups[n.start, default: []].append(n) }
        let starts = groups.keys.sorted()
        var events: [StaffEvent] = []
        for (i, s) in starts.enumerated() {
            let g = groups[s]!
            var dur = g.map(\.duration).max()!
            if i + 1 < starts.count {
                let nxt = starts[i + 1] - s
                dur = (dur > nxt || nxt - dur <= gapFill) ? nxt : dur
            }
            let pitches = Array(Set(g.map(\.pitch))).sorted()
            events.append(StaffEvent(start: s, duration: dur, pitches: pitches))
        }
        return events
    }

    static func decompose(start s0: Int, length l0: Int, unitsPerBeat upb: Int, compound: Bool) -> [Int] {
        let rep = compound ? repCompound : repSimple
        var out: [Int] = []
        var s = s0, length = l0
        while length > 0 {
            var seg = s % upb != 0 ? min(length, upb - s % upb) : length
            while seg > 0 {
                let v = rep.first { $0 <= seg }!
                out.append(v)
                s += v
                length -= v
                seg -= v
            }
        }
        return out
    }

    static func buildMeasures(_ events: [StaffEvent], measureLength: Int, measureCount: Int,
                              unitsPerBeat upb: Int, compound: Bool) -> [[Piece]] {
        struct Item { var start: Int; var units: Int; var pitches: [Int]; var tieStop: Bool; var tieStart: Bool }
        var items = [[Item]](repeating: [], count: measureCount)
        for ev in events {
            var s = ev.start, d = ev.duration
            var first = true
            while d > 0 {
                let m = s / measureLength
                let within = s - m * measureLength
                let take = min(d, measureLength - within)
                items[m].append(Item(start: within, units: take, pitches: ev.pitches, tieStop: !first, tieStart: d - take > 0))
                first = false
                s += take
                d -= take
            }
        }
        var measures = [[Piece]](repeating: [], count: measureCount)
        for m in 0..<measureCount {
            let its = items[m].sorted { $0.start < $1.start }
            if its.isEmpty {
                measures[m].append(Piece(kind: .rest, start: 0, units: measureLength, isWholeMeasureRest: true,
                                         pitches: [], tieStart: false, tieStop: false))
                continue
            }
            var cur = 0
            for idx in 0...its.count {
                let next: Item? = idx < its.count ? its[idx] : nil
                let nxt = next?.start ?? measureLength
                if nxt > cur {
                    var pos = cur
                    for v in decompose(start: cur, length: nxt - cur, unitsPerBeat: upb, compound: compound) {
                        measures[m].append(Piece(kind: .rest, start: pos, units: v, isWholeMeasureRest: false,
                                                 pitches: [], tieStart: false, tieStop: false))
                        pos += v
                    }
                }
                guard let it = next else { break }
                let parts = decompose(start: it.start, length: it.units, unitsPerBeat: upb, compound: compound)
                var pos = it.start
                for (pi, v) in parts.enumerated() {
                    measures[m].append(Piece(kind: .note, start: pos, units: v, isWholeMeasureRest: false,
                                             pitches: it.pitches,
                                             tieStart: pi == parts.count - 1 ? it.tieStart : true,
                                             tieStop: pi == 0 ? it.tieStop : true))
                    pos += v
                }
                cur = it.start + it.units
            }
        }
        for m in 0..<measureCount { assignBeams(&measures[m], unitsPerBeat: upb) }
        return measures
    }

    static func assignBeams(_ pieces: inout [Piece], unitsPerBeat upb: Int) {
        for i in pieces.indices { pieces[i].beam1 = nil; pieces[i].beam2 = nil }
        var groups: [Int: [Int]] = [:]
        for (idx, p) in pieces.enumerated() where p.kind == .note && p.units <= 3 {
            let beat = p.start / upb
            if (p.start + p.units - 1) / upb == beat { groups[beat, default: []].append(idx) }
        }
        for (_, idxs) in groups {
            var runs: [[Int]] = []
            var cur = [idxs[0]]
            for k in idxs.indices.dropFirst() {
                if idxs[k] == idxs[k - 1] + 1 { cur.append(idxs[k]) } else { runs.append(cur); cur = [idxs[k]] }
            }
            runs.append(cur)
            for run in runs where run.count >= 2 {
                for (j, idx) in run.enumerated() {
                    pieces[idx].beam1 = j == 0 ? "begin" : (j == run.count - 1 ? "end" : "continue")
                }
                var j = 0
                while j < run.count {
                    if pieces[run[j]].units != 1 { j += 1; continue }
                    var k = j
                    while k + 1 < run.count && pieces[run[k + 1]].units == 1 { k += 1 }
                    if k > j {
                        for q in j...k {
                            pieces[run[q]].beam2 = q == j ? "begin" : (q == k ? "end" : "continue")
                        }
                    } else {
                        pieces[run[j]].beam2 = j == 0 ? "forward hook" : "backward hook"
                    }
                    j = k + 1
                }
            }
        }
    }
}
