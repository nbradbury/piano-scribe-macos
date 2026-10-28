"""Reference notation engine (Python). The Swift ScoreKit is a line-for-line port of this file.

notes -> tempo -> beat tracking -> quantization -> downbeat -> key -> hand split -> measures -> MusicXML
"""
import math
import numpy as np

KK_MAJOR = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
KK_MINOR = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
MAJOR_FIFTHS = [0, -5, 2, -3, 4, -1, 6, 1, -4, 3, -2, 5]   # tonic pitch class -> fifths

TIME_SIGS = {  # name: (beats per measure, beat type, units per beat (16ths), compound)
    "4/4": (4, 4, 4, False), "3/4": (3, 4, 4, False), "2/4": (2, 4, 4, False), "6/8": (2, 8, 6, True),
}

ENV_RATE = 100.0
END_BIAS = 0.3   # grid steps; note ends from audio run long because of decay


# ---------------------------------------------------------------- cleanup

HARMONIC_INTERVALS = (12, 19, 24, 28, 31, 34, 36)


def remove_overtones(notes, ratio=0.8, window=0.05):
    """Drop notes that look like overtones of a louder note starting at the same time."""
    keep = []
    for i, (s, e, p, a) in enumerate(notes):
        ghost = False
        for j, (s2, e2, p2, a2) in enumerate(notes):
            if i != j and abs(s - s2) <= window and (p - p2) in HARMONIC_INTERVALS and a < ratio * a2:
                ghost = True
                break
        if not ghost:
            keep.append((s, e, p, a))
    return keep


# ---------------------------------------------------------------- tempo

def onset_clusters(notes):
    """Merge note starts closer than 35 ms; weight = summed amplitude."""
    starts = sorted((n[0], n[3]) for n in notes)
    out = []
    for t, a in starts:
        if out and t - out[-1][0] < 0.035:
            out[-1][1] += a
        else:
            out.append([t, a])
    return out


def resultant(times, weights, period):
    c = s = 0.0
    for t, w in zip(times, weights):
        ang = 2 * math.pi * t / period
        c += w * math.cos(ang); s += w * math.sin(ang)
    tw = sum(weights)
    return math.hypot(c, s) / tw if tw > 0 else 0.0


def tempo_score(clusters, bpm, compound):
    period = 60.0 / bpm
    subs = (1, 3, 6) if compound else (1, 2, 4)
    weights_lv = (0.45, 0.35, 0.20)
    if not clusters:
        return 0.0
    t_end = clusters[-1][0]
    win, hop = 10.0, 5.0
    total = 0.0; total_w = 0.0
    start = clusters[0][0]
    while True:
        sel = [c for c in clusters if start <= c[0] < start + win]
        if len(sel) >= 3:
            ts = [c[0] for c in sel]; ws = [c[1] for c in sel]
            sc = sum(lw * resultant(ts, ws, period / sub) for lw, sub in zip(weights_lv, subs))
            w = sum(ws)
            total += sc * w; total_w += w
        if start + win >= t_end:
            break
        start += hop
    if total_w == 0:
        return 0.0
    center = 70.0 if compound else 100.0
    _x = math.log2(bpm / center) / 0.55
    prior = math.exp(-0.5 * (_x * _x))
    return total / total_w * prior


def estimate_tempo(notes, compound):
    clusters = onset_clusters(notes)
    best_bpm, best = 100.0, -1.0
    bpm = 40.0
    while bpm <= 240.0:
        s = tempo_score(clusters, bpm, compound)
        if s > best:
            best, best_bpm = s, bpm
        bpm += 0.5
    lo = best_bpm - 0.5
    bpm = lo
    while bpm <= best_bpm + 0.5:
        s = tempo_score(clusters, bpm, compound)
        if s > best:
            best, best_bpm = s, bpm
        bpm += 0.05
    return best_bpm


# ---------------------------------------------------------------- beat tracking

def onset_envelope(notes):
    end = max(n[0] for n in notes)
    n = int(math.ceil(end * ENV_RATE)) + 8
    env = [0.0] * n
    for s, e, p, a in notes:
        i = int(round(s * ENV_RATE))
        if 0 <= i < n:
            env[i] += a
    # gaussian smoothing sigma = 2 frames
    k = [math.exp(-0.5 * ((d / 2.0) * (d / 2.0))) for d in range(-6, 7)]
    out = [0.0] * n
    for i in range(n):
        acc = 0.0
        for j, kv in enumerate(k):
            idx = i + j - 6
            if 0 <= idx < n:
                acc += env[idx] * kv
        out[i] = acc
    return out


def track_beats(notes, bpm, tightness=100.0):
    env = onset_envelope(notes)
    n = len(env)
    period = 60.0 / bpm * ENV_RATE
    # local score: smooth with gaussian window as wide as one period (librosa style)
    half = int(round(period))
    win = [math.exp(-0.5 * ((d * 32.0 / period) * (d * 32.0 / period))) for d in range(-half, half + 1)]
    local = [0.0] * n
    for i in range(n):
        acc = 0.0
        for j, wv in enumerate(win):
            idx = i + j - half
            if 0 <= idx < n:
                acc += env[idx] * wv
        local[i] = acc
    cum = [0.0] * n
    back = [-1] * n
    lo_off = int(round(period / 2)); hi_off = int(round(2 * period))
    for i in range(n):
        best = -1e30; arg = -1
        for j in range(max(0, i - hi_off), i - lo_off + 1):
            if j < 0:
                continue
            _l = math.log((i - j) / period)
            v = cum[j] - tightness * (_l * _l)
            if v > best:
                best, arg = v, j
        if arg >= 0 and best > 0:
            cum[i] = local[i] + best; back[i] = arg
        else:
            cum[i] = local[i]; back[i] = -1
    # last beat: last local max of cum above half the median of local maxima
    maxima = [i for i in range(1, n - 1) if cum[i] >= cum[i - 1] and cum[i] > cum[i + 1]]
    if not maxima:
        maxima = [n - 1]
    med = sorted(cum[i] for i in maxima)[len(maxima) // 2]
    last = max(i for i in maxima if cum[i] >= 0.5 * med)
    beats = []
    i = last
    while i >= 0:
        beats.append(i)
        i = back[i]
    beats.reverse()
    times = [b / ENV_RATE for b in beats]
    # drop leading beats before any onset energy
    first_onset = min(nn[0] for nn in notes)
    while len(times) > 2 and times[1] <= first_onset - 0.5 * 60.0 / bpm:
        times.pop(0)
    return extend_beats(times, notes, bpm)


def extend_beats(times, notes, bpm):
    p = 60.0 / bpm
    if len(times) < 2:
        t0 = min(nn[0] for nn in notes)
        times = [t0, t0 + p]
    first_onset = min(nn[0] for nn in notes)
    last_end = max(nn[1] for nn in notes)
    while times[0] > first_onset - 0.05:
        step = times[1] - times[0] if len(times) > 1 else p
        times.insert(0, times[0] - step)
    while times[-1] < last_end + p:
        step = times[-1] - times[-2]
        times.append(times[-1] + step)
    return times


def beat_position(t, beats):
    # binary search
    lo, hi = 0, len(beats) - 2
    if t <= beats[0]:
        return (t - beats[0]) / (beats[1] - beats[0])
    if t >= beats[-1]:
        return len(beats) - 1 + (t - beats[-1]) / (beats[-1] - beats[-2])
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if beats[mid] <= t:
            lo = mid
        else:
            hi = mid - 1
    return lo + (t - beats[lo]) / (beats[lo + 1] - beats[lo])


# ---------------------------------------------------------------- quantize

def quantize(notes, beats, units_per_beat, grid):
    q = []
    for s, e, p, a in notes:
        us = int(round(beat_position(s, beats) * units_per_beat / grid)) * grid
        ue = int(round(beat_position(e, beats) * units_per_beat / grid - END_BIAS)) * grid
        q.append({"start": us, "dur": max(grid, ue - us), "pitch": p, "amp": a})
    # dedupe same pitch at same start (keep longest), trim same-pitch overlaps
    q.sort(key=lambda n: (n["pitch"], n["start"], -n["dur"]))
    out = []
    for n in q:
        if out and out[-1]["pitch"] == n["pitch"]:
            prev = out[-1]
            if prev["start"] == n["start"]:
                continue
            if prev["start"] + prev["dur"] > n["start"]:
                prev["dur"] = n["start"] - prev["start"]
        out.append(n)
    out.sort(key=lambda n: (n["start"], n["pitch"]))
    return out


def choose_downbeat(qnotes, units_per_beat, beats_per_measure):
    best_c, best = 0, -1.0
    for c in range(beats_per_measure):
        score = 0.0
        for n in qnotes:
            if n["start"] % units_per_beat != 0:
                continue
            beat = n["start"] // units_per_beat
            if (beat - c) % beats_per_measure == 0:
                score += n["amp"] * (1.5 if n["pitch"] < 55 else 1.0) + 0.3 * n["dur"] / units_per_beat
        if score > best:
            best, best_c = score, c
    return best_c


# ---------------------------------------------------------------- key / spelling

def detect_key(notes):
    hist = [0.0] * 12
    for s, e, p, a in notes:
        hist[p % 12] += (e - s) * a
    if sum(hist) == 0:
        return 0, "major"
    def corr(x, y):
        mx = sum(x) / 12; my = sum(y) / 12
        num = sum((a - mx) * (b - my) for a, b in zip(x, y))
        den = math.sqrt(sum((a - mx) * (a - mx) for a in x) * sum((b - my) * (b - my) for b in y))
        return num / den if den > 0 else 0
    best = (-2, 0, "major")
    for tonic in range(12):
        rot = [hist[(tonic + i) % 12] for i in range(12)]
        for mode, prof in (("major", KK_MAJOR), ("minor", KK_MINOR)):
            r = corr(rot, prof)
            if r > best[0]:
                best = (r, tonic, mode)
    _, tonic, mode = best
    fifths = MAJOR_FIFTHS[tonic] if mode == "major" else MAJOR_FIFTHS[(tonic + 3) % 12]
    return fifths, mode


def spell(pitch, fifths):
    """Return (step, alter, octave) choosing the line-of-fifths spelling closest to the key."""
    pc = pitch % 12
    center = fifths + 2
    # line-of-fifths position p satisfies 7p = pc (mod 12)  ->  p = 7*pc mod 12 (7 is its own inverse mod 12)
    base = (7 * pc) % 12
    cands = [base + 12 * k for k in range(-2, 3)]
    pos = min(cands, key=lambda q: (abs(q - center), -q if fifths >= 0 else q))
    step = "FCGDAEB"[(pos + 1) % 7]
    alter = (pos + 1) // 7
    natural = pitch - alter
    octave = natural // 12 - 1
    return step, alter, octave


def key_alters(fifths):
    alters = {s: 0 for s in "CDEFGAB"}
    if fifths > 0:
        for s in "FCGDAEB"[:fifths]:
            alters[s] = 1
    elif fifths < 0:
        for s in "BEADGCF"[:-fifths]:
            alters[s] = -1
    return alters


# ---------------------------------------------------------------- hands

def split_hands(qnotes, mode="auto", split_pitch=60):
    groups = {}
    for n in qnotes:
        groups.setdefault(n["start"], []).append(n)
    rh_c, lh_c = 67.0, 48.0
    for start in sorted(groups):
        g = sorted(groups[start], key=lambda n: n["pitch"])
        if mode == "fixed":
            for n in g:
                n["staff"] = 1 if n["pitch"] >= split_pitch else 2
            continue
        best_k, best_cost = 0, 1e18
        for k in range(len(g) + 1):         # g[:k] -> LH, g[k:] -> RH
            lh = [n["pitch"] for n in g[:k]]; rh = [n["pitch"] for n in g[k:]]
            cost = sum(abs(p - lh_c) for p in lh) + sum(abs(p - rh_c) for p in rh)
            for hand in (lh, rh):
                if hand:
                    span = hand[-1] - hand[0]
                    if span > 12:
                        cost += 10 * (span - 12)
                    if len(hand) > 5:
                        cost += 20 * (len(hand) - 5)
            if cost < best_cost:
                best_cost, best_k = cost, k
        lh = g[:best_k]; rh = g[best_k:]
        for n in lh: n["staff"] = 2
        for n in rh: n["staff"] = 1
        if rh:
            rh_c = 0.7 * rh_c + 0.3 * (sum(n["pitch"] for n in rh) / len(rh))
        else:
            rh_c = 0.9 * rh_c + 0.1 * 67
        if lh:
            lh_c = 0.7 * lh_c + 0.3 * (sum(n["pitch"] for n in lh) / len(lh))
        else:
            lh_c = 0.9 * lh_c + 0.1 * 48
        if rh_c < lh_c + 7:
            mid = (rh_c + lh_c) / 2
            rh_c, lh_c = mid + 3.5, mid - 3.5


# ---------------------------------------------------------------- measures

REP_SIMPLE = [16, 12, 8, 6, 4, 3, 2, 1]
REP_COMPOUND = [12, 9, 6, 4, 3, 2, 1]
TYPE_FOR = {1: ("16th", 0), 2: ("eighth", 0), 3: ("eighth", 1), 4: ("quarter", 0), 6: ("quarter", 1),
            8: ("half", 0), 9: ("quarter", 2), 12: ("half", 1), 16: ("whole", 0)}


def staff_events(qnotes, staff, gap_fill):
    groups = {}
    for n in qnotes:
        if n["staff"] == staff:
            groups.setdefault(n["start"], []).append(n)
    starts = sorted(groups)
    events = []
    for i, s in enumerate(starts):
        g = groups[s]
        dur = max(n["dur"] for n in g)
        if i + 1 < len(starts):
            nxt = starts[i + 1] - s
            # cap at the next onset; close small gaps (legato) so we don't print fussy rests
            dur = nxt if dur > nxt or nxt - dur <= gap_fill else dur
        pitches = sorted(set(n["pitch"] for n in g))
        events.append({"start": s, "dur": dur, "pitches": pitches})
    return events


def decompose(s, length, upb, compound):
    rep = REP_COMPOUND if compound else REP_SIMPLE
    out = []
    while length > 0:
        seg = min(length, upb - s % upb) if s % upb else length
        while seg > 0:
            v = next(r for r in rep if r <= seg)
            out.append(v); s += v; length -= v; seg -= v
    return out


def build_measures(events, measure_len, n_measures, upb, compound):
    """Returns list (per measure) of pieces: dict(kind, start, units, pitches, tie_start, tie_stop)."""
    measures = [[] for _ in range(n_measures)]
    # split events at barlines
    items = [[] for _ in range(n_measures)]
    for ev in events:
        s, d = ev["start"], ev["dur"]
        first = True
        while d > 0:
            m = s // measure_len
            within = s - m * measure_len
            take = min(d, measure_len - within)
            items[m].append({"start": within, "units": take, "pitches": ev["pitches"],
                             "tie_stop": not first, "tie_start": d - take > 0})
            first = False
            s += take; d -= take
    for m in range(n_measures):
        cur = 0
        its = sorted(items[m], key=lambda x: x["start"])
        if not its:
            measures[m].append({"kind": "rest", "start": 0, "units": measure_len, "whole": True,
                                "pitches": [], "tie_start": False, "tie_stop": False})
            continue
        for it in its + [None]:
            nxt = it["start"] if it else measure_len
            if nxt > cur:
                pos = cur
                for v in decompose(cur, nxt - cur, upb, compound):
                    measures[m].append({"kind": "rest", "start": pos, "units": v, "whole": False,
                                        "pitches": [], "tie_start": False, "tie_stop": False})
                    pos += v
            if it is None:
                break
            parts = decompose(it["start"], it["units"], upb, compound)
            pos = it["start"]
            for idx, v in enumerate(parts):
                measures[m].append({"kind": "note", "start": pos, "units": v, "whole": False,
                                    "pitches": it["pitches"],
                                    "tie_stop": it["tie_stop"] if idx == 0 else True,
                                    "tie_start": it["tie_start"] if idx == len(parts) - 1 else True})
                pos += v
            cur = it["start"] + it["units"]
    for m in range(n_measures):
        assign_beams(measures[m], upb)
    return measures


def assign_beams(pieces, upb):
    for p in pieces:
        p["beam1"] = None; p["beam2"] = None
    groups = {}
    for idx, p in enumerate(pieces):
        if p["kind"] == "note" and p["units"] <= 3:
            beat = p["start"] // upb
            if (p["start"] + p["units"] - 1) // upb == beat:
                groups.setdefault(beat, []).append(idx)
    for beat, idxs in groups.items():
        # split into runs of consecutive pieces (no rest in between)
        runs, cur = [], [idxs[0]]
        for a, b in zip(idxs, idxs[1:]):
            if b == a + 1:
                cur.append(b)
            else:
                runs.append(cur); cur = [b]
        runs.append(cur)
        for run in runs:
            if len(run) < 2:
                continue
            for j, idx in enumerate(run):
                pieces[idx]["beam1"] = "begin" if j == 0 else ("end" if j == len(run) - 1 else "continue")
            # level 2: 16ths
            j = 0
            while j < len(run):
                if pieces[run[j]]["units"] != 1:
                    j += 1; continue
                k = j
                while k + 1 < len(run) and pieces[run[k + 1]]["units"] == 1:
                    k += 1
                if k > j:
                    for q in range(j, k + 1):
                        pieces[run[q]]["beam2"] = "begin" if q == j else ("end" if q == k else "continue")
                else:
                    pieces[run[j]]["beam2"] = "forward hook" if j == 0 else "backward hook"
                j = k + 1


# ---------------------------------------------------------------- top level

def build_score(notes, time_sig="4/4", bpm=None, grid="16th", hands="auto", split_pitch=60,
                key_fifths=None, title="Transcription", overtones=True):
    beats_per_measure, beat_type, upb, compound = TIME_SIGS[time_sig]
    notes = sorted(notes)
    if overtones:
        notes = remove_overtones(notes)
    if not notes:
        raise ValueError("no notes")
    if bpm is None:
        bpm = estimate_tempo(notes, compound)
    beats = track_beats(notes, bpm)
    gstep = 1 if grid == "16th" else (2 if not compound else 2)
    q = quantize(notes, beats, upb, gstep)
    c = choose_downbeat(q, upb, beats_per_measure)
    measure_len = upb * beats_per_measure
    shift = c * upb
    min_u = min(n["start"] for n in q)
    while min_u - shift < 0:
        shift -= measure_len
    for n in q:
        n["start"] -= shift
    first_m = min(n["start"] for n in q) // measure_len
    for n in q:
        n["start"] -= first_m * measure_len
    if key_fifths is None:
        fifths, mode = detect_key(notes)
    else:
        fifths, mode = key_fifths, "major"
    split_hands(q, hands, split_pitch)
    end = max(n["start"] + n["dur"] for n in q)
    n_measures = max(1, -(-end // measure_len))
    staves = {st: build_measures(staff_events(q, st, upb // 2), measure_len, n_measures, upb, compound) for st in (1, 2)}
    # beat-level bpm -> quarter bpm for MIDI/metronome
    quarter_bpm = bpm * 1.5 if compound else bpm
    return {"title": title, "fifths": fifths, "mode": mode, "time": (beats_per_measure, beat_type),
            "upb": upb, "compound": compound, "measure_len": measure_len, "bpm": bpm, "quarter_bpm": quarter_bpm,
            "n_measures": n_measures, "staves": staves, "notes": q}


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


ACC = {-2: "flat-flat", -1: "flat", 0: "natural", 1: "sharp", 2: "double-sharp"}


def to_musicxml(sc):
    L = []
    a = L.append
    a('<?xml version="1.0" encoding="UTF-8" standalone="no"?>')
    a('<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">')
    a('<score-partwise version="4.0">')
    a(f'  <work><work-title>{esc(sc["title"])}</work-title></work>')
    a('  <identification><encoding><software>PianoScribe</software></encoding></identification>')
    a('  <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>')
    a('  <part id="P1">')
    beats, beat_type = sc["time"]
    kalt = key_alters(sc["fifths"])
    for m in range(sc["n_measures"]):
        a(f'    <measure number="{m + 1}">')
        if m == 0:
            a('      <attributes>')
            a('        <divisions>4</divisions>')
            a(f'        <key><fifths>{sc["fifths"]}</fifths><mode>{sc["mode"]}</mode></key>')
            a(f'        <time><beats>{beats}</beats><beat-type>{beat_type}</beat-type></time>')
            a('        <staves>2</staves>')
            a('        <clef number="1"><sign>G</sign><line>2</line></clef>')
            a('        <clef number="2"><sign>F</sign><line>4</line></clef>')
            a('      </attributes>')
            bpm_disp = int(round(sc["bpm"]))
            unit = '<beat-unit>quarter</beat-unit><beat-unit-dot/>' if sc["compound"] else '<beat-unit>quarter</beat-unit>'
            a(f'      <direction placement="above"><direction-type><metronome>{unit}<per-minute>{bpm_disp}</per-minute></metronome></direction-type><staff>1</staff><sound tempo="{sc["quarter_bpm"]:.2f}"/></direction>')
        for st in (1, 2):
            if st == 2:
                a(f'      <backup><duration>{sc["measure_len"]}</duration></backup>')
            voice = 1 if st == 1 else 5
            state = {}
            for p in sc["staves"][st][m]:
                if p["kind"] == "rest":
                    if p["whole"]:
                        a(f'      <note><rest measure="yes"/><duration>{p["units"]}</duration><voice>{voice}</voice><staff>{st}</staff></note>')
                    else:
                        typ, dots = TYPE_FOR[p["units"]]
                        a(f'      <note><rest/><duration>{p["units"]}</duration><voice>{voice}</voice><type>{typ}</type>{"<dot/>" * dots}<staff>{st}</staff></note>')
                    continue
                typ, dots = TYPE_FOR[p["units"]]
                for ci, pitch in enumerate(p["pitches"]):
                    step, alter, octave = spell(pitch, sc["fifths"])
                    key = (step, octave)
                    cur = state.get(key, kalt[step])
                    acc = ""
                    if alter != cur:
                        if not p["tie_stop"]:
                            acc = f'<accidental>{ACC[alter]}</accidental>'
                        state[key] = alter
                    x = ['      <note>']
                    if ci > 0:
                        x.append('<chord/>')
                    x.append(f'<pitch><step>{step}</step>{f"<alter>{alter}</alter>" if alter else ""}<octave>{octave}</octave></pitch>')
                    x.append(f'<duration>{p["units"]}</duration>')
                    if p["tie_stop"]: x.append('<tie type="stop"/>')
                    if p["tie_start"]: x.append('<tie type="start"/>')
                    x.append(f'<voice>{voice}</voice><type>{typ}</type>' + '<dot/>' * dots)
                    x.append(acc)
                    x.append(f'<staff>{st}</staff>')
                    if ci == 0:
                        if p.get("beam1"): x.append(f'<beam number="1">{p["beam1"]}</beam>')
                        if p.get("beam2"): x.append(f'<beam number="2">{p["beam2"]}</beam>')
                    if p["tie_stop"] or p["tie_start"]:
                        t = ''
                        if p["tie_stop"]: t += '<tied type="stop"/>'
                        if p["tie_start"]: t += '<tied type="start"/>'
                        x.append(f'<notations>{t}</notations>')
                    x.append('</note>')
                    a(''.join(x))
        if m == sc["n_measures"] - 1:
            a('      <barline location="right"><bar-style>light-heavy</bar-style></barline>')
        a('    </measure>')
    a('  </part>')
    a('</score-partwise>')
    return "\n".join(L) + "\n"
