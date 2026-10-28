import Foundation

public enum MusicXMLWriter {
    static let accidentalNames = [-2: "flat-flat", -1: "flat", 0: "natural", 1: "sharp", 2: "double-sharp"]

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Uncompressed MusicXML 4.0 (score-partwise), one piano part on a grand staff. divisions = 4 (16th = 1).
    public static func write(_ sc: Score) -> String {
        var L: [String] = []
        L.append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>")
        L.append("<!DOCTYPE score-partwise PUBLIC \"-//Recordare//DTD MusicXML 4.0 Partwise//EN\" \"http://www.musicxml.org/dtds/partwise.dtd\">")
        L.append("<score-partwise version=\"4.0\">")
        L.append("  <work><work-title>\(escape(sc.title))</work-title></work>")
        L.append("  <identification><encoding><software>PianoScribe</software></encoding></identification>")
        L.append("  <part-list><score-part id=\"P1\"><part-name>Piano</part-name></score-part></part-list>")
        L.append("  <part id=\"P1\">")
        let written = sc.timeSignature.written
        let kalt = Notation.keyAlters(sc.keyFifths)
        for m in 0..<sc.measureCount {
            L.append("    <measure number=\"\(m + 1)\">")
            if m == 0 {
                L.append("      <attributes>")
                L.append("        <divisions>4</divisions>")
                L.append("        <key><fifths>\(sc.keyFifths)</fifths><mode>\(sc.mode)</mode></key>")
                L.append("        <time><beats>\(written.beats)</beats><beat-type>\(written.beatType)</beat-type></time>")
                L.append("        <staves>2</staves>")
                L.append("        <clef number=\"1\"><sign>G</sign><line>2</line></clef>")
                L.append("        <clef number=\"2\"><sign>F</sign><line>4</line></clef>")
                L.append("      </attributes>")
                let bpmDisp = pyRound(sc.tempo)
                let unit = sc.timeSignature.isCompound ? "<beat-unit>quarter</beat-unit><beat-unit-dot/>" : "<beat-unit>quarter</beat-unit>"
                let soundTempo = String(format: "%.2f", sc.quarterTempo)
                L.append("      <direction placement=\"above\"><direction-type><metronome>\(unit)<per-minute>\(bpmDisp)</per-minute></metronome></direction-type><staff>1</staff><sound tempo=\"\(soundTempo)\"/></direction>")
            }
            for st in 1...2 {
                if st == 2 { L.append("      <backup><duration>\(sc.measureLength)</duration></backup>") }
                let voice = st == 1 ? 1 : 5
                var state: [String: Int] = [:]
                for p in sc.staves[st - 1][m] {
                    if p.kind == .rest {
                        if p.isWholeMeasureRest {
                            L.append("      <note><rest measure=\"yes\"/><duration>\(p.units)</duration><voice>\(voice)</voice><staff>\(st)</staff></note>")
                        } else {
                            let (typ, dots) = Notation.typeFor[p.units]!
                            L.append("      <note><rest/><duration>\(p.units)</duration><voice>\(voice)</voice><type>\(typ)</type>\(String(repeating: "<dot/>", count: dots))<staff>\(st)</staff></note>")
                        }
                        continue
                    }
                    let (typ, dots) = Notation.typeFor[p.units]!
                    for (ci, pitch) in p.pitches.enumerated() {
                        let sp = Notation.spell(pitch, fifths: sc.keyFifths)
                        let key = "\(sp.step)\(sp.octave)"
                        let cur = state[key] ?? kalt[sp.step]!
                        var acc = ""
                        if sp.alter != cur {
                            if !p.tieStop { acc = "<accidental>\(accidentalNames[sp.alter]!)</accidental>" }
                            state[key] = sp.alter
                        }
                        var x = "      <note>"
                        if ci > 0 { x += "<chord/>" }
                        x += "<pitch><step>\(sp.step)</step>\(sp.alter != 0 ? "<alter>\(sp.alter)</alter>" : "")<octave>\(sp.octave)</octave></pitch>"
                        x += "<duration>\(p.units)</duration>"
                        if p.tieStop { x += "<tie type=\"stop\"/>" }
                        if p.tieStart { x += "<tie type=\"start\"/>" }
                        x += "<voice>\(voice)</voice><type>\(typ)</type>" + String(repeating: "<dot/>", count: dots)
                        x += acc
                        x += "<staff>\(st)</staff>"
                        if ci == 0 {
                            if let b = p.beam1 { x += "<beam number=\"1\">\(b)</beam>" }
                            if let b = p.beam2 { x += "<beam number=\"2\">\(b)</beam>" }
                        }
                        if p.tieStop || p.tieStart {
                            var t = ""
                            if p.tieStop { t += "<tied type=\"stop\"/>" }
                            if p.tieStart { t += "<tied type=\"start\"/>" }
                            x += "<notations>\(t)</notations>"
                        }
                        x += "</note>"
                        L.append(x)
                    }
                }
            }
            if m == sc.measureCount - 1 {
                L.append("      <barline location=\"right\"><bar-style>light-heavy</bar-style></barline>")
            }
            L.append("    </measure>")
        }
        L.append("  </part>")
        L.append("</score-partwise>")
        return L.joined(separator: "\n") + "\n"
    }
}
