import Foundation

/// Overtone cleanup, tempo estimation, beat tracking and quantization.
/// Line-for-line port of notation_ref.py (see Tests/Reference).
public enum Rhythm {
    static let envRate = 100.0
    static let endBias = 0.3
    static let harmonicIntervals: Set<Int> = [12, 19, 24, 28, 31, 34, 36]

    // MARK: Cleanup

    /// Drop notes that look like overtones of a louder note starting at (almost) the same time.
    public static func removeOvertones(_ notes: [NoteEvent], ratio: Double = 0.8, window: Double = 0.05) -> [NoteEvent] {
        // `notes` must be sorted by start; neighbours are found with a sliding window.
        var keep: [NoteEvent] = []
        keep.reserveCapacity(notes.count)
        var lo = 0
        for (i, n) in notes.enumerated() {
            while lo < notes.count && notes[lo].start < n.start - window - 1e-9 { lo += 1 }
            var ghost = false
            var j = lo
            while j < notes.count && notes[j].start <= n.start + window + 1e-9 {
                let m = notes[j]
                if j != i && abs(n.start - m.start) <= window && harmonicIntervals.contains(n.pitch - m.pitch)
                    && n.amplitude < ratio * m.amplitude {
                    ghost = true
                    break
                }
                j += 1
            }
            if !ghost { keep.append(n) }
        }
        return keep
    }

    // MARK: Tempo

    struct Cluster { var time: Double; var weight: Double }

    static func onsetClusters(_ notes: [NoteEvent]) -> [Cluster] {
        let starts = notes.map { ($0.start, $0.amplitude) }.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var out: [Cluster] = []
        for (t, a) in starts {
            if let last = out.last, t - last.time < 0.035 {
                out[out.count - 1].weight += a
            } else {
                out.append(Cluster(time: t, weight: a))
            }
        }
        return out
    }

    static func resultant(_ clusters: ArraySlice<Cluster>, period: Double) -> Double {
        var c = 0.0, s = 0.0, tw = 0.0
        for cl in clusters {
            let ang = 2 * Double.pi * cl.time / period
            c += cl.weight * cos(ang)
            s += cl.weight * sin(ang)
        }
        for cl in clusters { tw += cl.weight }
        return tw > 0 ? hypot(c, s) / tw : 0
    }

    static func tempoScore(_ clusters: [Cluster], bpm: Double, compound: Bool) -> Double {
        let period = 60.0 / bpm
        let subs: [Double] = compound ? [1, 3, 6] : [1, 2, 4]
        let levelWeights = [0.45, 0.35, 0.20]
        guard let first = clusters.first, let last = clusters.last else { return 0 }
        let tEnd = last.time
        let win = 10.0, hop = 5.0
        var total = 0.0, totalW = 0.0
        var start = first.time
        while true {
            // clusters are sorted: select [start, start + win)
            let lo = clusters.firstIndex { $0.time >= start } ?? clusters.count
            var hi = lo
            while hi < clusters.count && clusters[hi].time < start + win { hi += 1 }
            if hi - lo >= 3 {
                let sel = clusters[lo..<hi]
                var sc = 0.0
                for (lw, sub) in zip(levelWeights, subs) {
                    sc += lw * resultant(sel, period: period / sub)
                }
                var w = 0.0
                for c in sel { w += c.weight }
                total += sc * w
                totalW += w
            }
            if start + win >= tEnd { break }
            start += hop
        }
        if totalW == 0 { return 0 }
        let center = compound ? 70.0 : 100.0
        let x = log2(bpm / center) / 0.55
        let prior = exp(-0.5 * (x * x))
        return total / totalW * prior
    }

    /// Estimate the tracked-beat tempo (quarter note, or dotted quarter for compound meters).
    public static func estimateTempo(_ notes: [NoteEvent], compound: Bool) -> Double {
        let clusters = onsetClusters(notes)
        var bestBPM = 100.0, best = -1.0
        var bpm = 40.0
        while bpm <= 240.0 {
            let s = tempoScore(clusters, bpm: bpm, compound: compound)
            if s > best { best = s; bestBPM = bpm }
            bpm += 0.5
        }
        bpm = bestBPM - 0.5
        while bpm <= bestBPM + 0.5 {   // (bound moves with bestBPM, as in the reference)
            let s = tempoScore(clusters, bpm: bpm, compound: compound)
            if s > best { best = s; bestBPM = bpm }
            bpm += 0.05
        }
        return bestBPM
    }

    // MARK: Beat tracking (dynamic programming, after Ellis 2007 / librosa)

    static func onsetEnvelope(_ notes: [NoteEvent]) -> [Double] {
        let end = notes.map(\.start).max() ?? 0
        let n = Int((end * envRate).rounded(.up)) + 8
        var env = [Double](repeating: 0, count: n)
        for note in notes {
            let i = pyRound(note.start * envRate)
            if i >= 0 && i < n { env[i] += note.amplitude }
        }
        let kernel = (-6...6).map { d -> Double in let x = Double(d) / 2.0; return exp(-0.5 * (x * x)) }
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var acc = 0.0
            for (j, kv) in kernel.enumerated() {
                let idx = i + j - 6
                if idx >= 0 && idx < n { acc += env[idx] * kv }
            }
            out[i] = acc
        }
        return out
    }

    public static func trackBeats(_ notes: [NoteEvent], bpm: Double, tightness: Double = 100) -> [Double] {
        let env = onsetEnvelope(notes)
        let n = env.count
        let period = 60.0 / bpm * envRate
        let half = pyRound(period)
        let win = (-half...half).map { d -> Double in let x = Double(d) * 32.0 / period; return exp(-0.5 * (x * x)) }
        var local = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var acc = 0.0
            for (j, wv) in win.enumerated() {
                let idx = i + j - half
                if idx >= 0 && idx < n { acc += env[idx] * wv }
            }
            local[i] = acc
        }
        var cum = [Double](repeating: 0, count: n)
        var back = [Int](repeating: -1, count: n)
        let loOff = pyRound(period / 2)
        let hiOff = pyRound(2 * period)
        for i in 0..<n {
            var best = -1e30
            var arg = -1
            let jStart = max(0, i - hiOff)
            let jEnd = i - loOff
            if jEnd >= jStart {
                for j in jStart...jEnd {
                    let l = log(Double(i - j) / period)
                    let v = cum[j] - tightness * (l * l)
                    if v > best { best = v; arg = j }
                }
            }
            if arg >= 0 && best > 0 {
                cum[i] = local[i] + best
                back[i] = arg
            } else {
                cum[i] = local[i]
                back[i] = -1
            }
        }
        var maxima: [Int] = []
        if n >= 3 {
            for i in 1..<(n - 1) where cum[i] >= cum[i - 1] && cum[i] > cum[i + 1] { maxima.append(i) }
        }
        if maxima.isEmpty { maxima = [n - 1] }
        let sortedVals = maxima.map { cum[$0] }.sorted()
        let med = sortedVals[maxima.count / 2]
        let last = maxima.filter { cum[$0] >= 0.5 * med }.max() ?? (n - 1)
        var beats: [Int] = []
        var i = last
        while i >= 0 {
            beats.append(i)
            i = back[i]
        }
        beats.reverse()
        var times = beats.map { Double($0) / envRate }
        let firstOnset = notes.map(\.start).min() ?? 0
        while times.count > 2 && times[1] <= firstOnset - 0.5 * 60.0 / bpm {
            times.removeFirst()
        }
        return extendBeats(times, notes: notes, bpm: bpm)
    }

    static func extendBeats(_ input: [Double], notes: [NoteEvent], bpm: Double) -> [Double] {
        let p = 60.0 / bpm
        var times = input
        let firstOnset = notes.map(\.start).min() ?? 0
        let lastEnd = notes.map(\.end).max() ?? 0
        if times.count < 2 {
            times = [firstOnset, firstOnset + p]
        }
        while times[0] > firstOnset - 0.05 {
            let step = times.count > 1 ? times[1] - times[0] : p
            times.insert(times[0] - step, at: 0)
        }
        while times[times.count - 1] < lastEnd + p {
            let step = times[times.count - 1] - times[times.count - 2]
            times.append(times[times.count - 1] + step)
        }
        return times
    }

    /// Continuous beat index for time `t` (linear between tracked beats).
    public static func beatPosition(_ t: Double, beats: [Double]) -> Double {
        let last = beats.count - 1
        if t <= beats[0] { return (t - beats[0]) / (beats[1] - beats[0]) }
        if t >= beats[last] { return Double(last) + (t - beats[last]) / (beats[last] - beats[last - 1]) }
        var lo = 0, hi = beats.count - 2
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if beats[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        return Double(lo) + (t - beats[lo]) / (beats[lo + 1] - beats[lo])
    }

    // MARK: Quantization

    public static func quantize(_ notes: [NoteEvent], beats: [Double], unitsPerBeat: Int, grid: Int) -> [QuantizedNote] {
        let upb = Double(unitsPerBeat), g = Double(grid)
        var q: [(note: QuantizedNote, order: Int)] = notes.enumerated().map { idx, n in
            let us = pyRound(beatPosition(n.start, beats: beats) * upb / g) * grid
            let ue = pyRound(beatPosition(n.end, beats: beats) * upb / g - endBias) * grid
            return (QuantizedNote(start: us, duration: max(grid, ue - us), pitch: n.pitch, amplitude: n.amplitude, staff: 1), idx)
        }
        q.sort { a, b in
            if a.note.pitch != b.note.pitch { return a.note.pitch < b.note.pitch }
            if a.note.start != b.note.start { return a.note.start < b.note.start }
            if a.note.duration != b.note.duration { return a.note.duration > b.note.duration }
            return a.order < b.order
        }
        var out: [QuantizedNote] = []
        for item in q {
            let n = item.note
            if var prev = out.last, prev.pitch == n.pitch {
                if prev.start == n.start { continue }
                if prev.start + prev.duration > n.start {
                    prev.duration = n.start - prev.start
                    out[out.count - 1] = prev
                }
            }
            out.append(n)
        }
        out.sort { $0.start != $1.start ? $0.start < $1.start : $0.pitch < $1.pitch }
        return out
    }

    static func chooseDownbeat(_ notes: [QuantizedNote], unitsPerBeat upb: Int, beatsPerMeasure: Int) -> Int {
        var bestC = 0
        var best = -1.0
        for c in 0..<beatsPerMeasure {
            var score = 0.0
            for n in notes {
                if floorMod(n.start, upb) != 0 { continue }
                let beat = floorDiv(n.start, upb)
                if floorMod(beat - c, beatsPerMeasure) == 0 {
                    score += n.amplitude * (n.pitch < 55 ? 1.5 : 1.0) + 0.3 * Double(n.duration) / Double(upb)
                }
            }
            if score > best { best = score; bestC = c }
        }
        return bestC
    }
}
