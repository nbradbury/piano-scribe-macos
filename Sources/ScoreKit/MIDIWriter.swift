import Foundation

/// Minimal Standard MIDI File writer.
public enum MIDIWriter {
    static let ticksPerQuarter = 480

    struct Event { var tick: Int; var order: Int; var bytes: [UInt8] }

    static func vlq(_ value: Int) -> [UInt8] {
        var v = max(0, value)
        var out: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            out.insert(UInt8((v & 0x7F) | 0x80), at: 0)
            v >>= 7
        }
        return out
    }

    static func track(_ events: [Event], name: String?) -> [UInt8] {
        var evs = events
        if let name {
            let text = Array(name.utf8)
            evs.append(Event(tick: 0, order: -2, bytes: [0xFF, 0x03] + vlq(text.count) + text))
        }
        evs.sort { $0.tick != $1.tick ? $0.tick < $1.tick : $0.order < $1.order }
        var body: [UInt8] = []
        var last = 0
        for e in evs {
            body += vlq(e.tick - last) + e.bytes
            last = e.tick
        }
        body += [0x00, 0xFF, 0x2F, 0x00]
        return Array("MTrk".utf8) + be32(body.count) + body
    }

    static func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    static func header(format: Int, tracks: Int) -> [UInt8] {
        Array("MThd".utf8) + be32(6) + be16(format) + be16(tracks) + be16(ticksPerQuarter)
    }

    static func tempoEvent(_ quarterBPM: Double) -> Event {
        let usPerQuarter = Int((60_000_000.0 / max(1, quarterBPM)).rounded())
        return Event(tick: 0, order: -1, bytes: [0xFF, 0x51, 0x03, UInt8((usPerQuarter >> 16) & 0xFF),
                                                 UInt8((usPerQuarter >> 8) & 0xFF), UInt8(usPerQuarter & 0xFF)])
    }

    static func velocity(_ amplitude: Double) -> UInt8 { UInt8(min(127, max(1, Int((amplitude * 127).rounded())))) }

    static func noteEvents(channel: UInt8, pitch: Int, velocity v: UInt8, on: Int, off: Int) -> [Event] {
        let p = UInt8(min(127, max(0, pitch)))
        return [Event(tick: on, order: 1, bytes: [0x90 | channel, p, v]),
                Event(tick: max(on + 1, off), order: 0, bytes: [0x80 | channel, p, 0])]
    }

    /// The notes exactly as detected (real timing), single track.
    public static func performance(_ notes: [NoteEvent], quarterBPM: Double = 120) -> Data {
        let tps = Double(ticksPerQuarter) * quarterBPM / 60.0
        var evs: [Event] = [tempoEvent(quarterBPM), Event(tick: 0, order: -1, bytes: [0xC0, 0x00])]
        // A repeated pitch must release before it sounds again, so trim overlaps per pitch.
        let sorted = notes.sorted { $0.pitch != $1.pitch ? $0.pitch < $1.pitch : $0.start < $1.start }
        for (i, n) in sorted.enumerated() {
            var end = n.end
            if i + 1 < sorted.count, sorted[i + 1].pitch == n.pitch { end = min(end, sorted[i + 1].start) }
            evs += noteEvents(channel: 0, pitch: n.pitch, velocity: velocity(n.amplitude),
                              on: Int((n.start * tps).rounded()), off: Int((end * tps).rounded()))
        }
        return Data(header(format: 0, tracks: 1) + track(evs, name: "Piano"))
    }

    /// The quantized score (what the sheet music says), right and left hand on separate tracks.
    public static func quantized(_ score: Score) -> Data {
        let tpu = ticksPerQuarter / 4   // ticks per sixteenth
        let written = score.timeSignature.written
        let denomPow = written.beatType == 8 ? 3 : 2
        let fifths = Int8(score.keyFifths)
        var conductor: [Event] = [tempoEvent(score.quarterTempo),
                                  Event(tick: 0, order: -1, bytes: [0xFF, 0x58, 0x04, UInt8(written.beats), UInt8(denomPow), 24, 8]),
                                  Event(tick: 0, order: -1, bytes: [0xFF, 0x59, 0x02, UInt8(bitPattern: fifths), score.mode == "minor" ? 1 : 0])]
        conductor.sort { $0.order < $1.order }
        var hands: [[Event]] = [[Event(tick: 0, order: -1, bytes: [0xC0, 0x00])],
                                [Event(tick: 0, order: -1, bytes: [0xC1, 0x00])]]
        for n in score.notes {
            let h = n.staff == 1 ? 0 : 1
            hands[h] += noteEvents(channel: UInt8(h), pitch: n.pitch, velocity: velocity(n.amplitude),
                                   on: n.start * tpu, off: (n.start + n.duration) * tpu)
        }
        return Data(header(format: 1, tracks: 3) + track(conductor, name: score.title)
                    + track(hands[0], name: "Right Hand") + track(hands[1], name: "Left Hand"))
    }
}
