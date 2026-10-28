# PianoScribe: project handoff notes

Context for picking this project up in a new conversation or after a break. For setup and usage,
see the [README](../README.md).

## Where things stand (Oct 28, 2026)

- The app **builds and runs in Xcode**. Select the **PianoScribe** scheme. `PianoScribe-Package`
  builds everything but doesn't launch anything.
- The code was written without a Swift compiler, then reviewed for compile errors. It compiled
  on the first try in Xcode.
- **Not yet confirmed on a Mac:**
  - `swift test`, which includes the Core ML vs ONNX parity test and the full test-MP4 pipeline test
  - transcription quality on real (non-synthesized) piano recordings
  - printing / Save as PDF from the app
  - MIDI playback through `AVMIDIPlayer`'s default sound bank
- Repo: https://github.com/nbradbury/piano-scribe-macos. Local checkout:
  `~/GitHub/nbradbury/piano-scribe-macos`.

## Pipeline

```
file ─AudioDecoder─▶ [Float] 22,050 Hz mono
     ─BasicPitchModel (Core ML)─▶ ModelActivations (frames × 88 note + onset)
     ─BasicPitch.decode─▶ [NoteEvent] (seconds, pitch, amplitude)
     ─ScoreBuilder.build─▶ Score (measures × pieces, both staves)
     ─MusicXMLWriter─▶ MusicXML ─score.html + Verovio (WKWebView)─▶ on screen
                                └ MIDIWriter (quantized / as played), print → PDF
```

`AppState` caches the model activations. When a setting changes, it only re-runs the steps after
inference (debounced 250 ms, with a generation counter so stale results are dropped). It only
re-decodes notes when a *decoding* option changes.

## Targets and key files

| Target | Files | Notes |
|---|---|---|
| `ScoreKit` (pure Swift, Linux-OK) | `BasicPitch.swift` | Windowing (43,844-sample windows, 36,164 hop, 30-frame overlap), stitching, `frameTimes` (includes Basic Pitch's per-window alignment fudge), note decoding ported from `note_creation.py` (inferred onsets, melodia trick, with a per-row max cache) |
| | `Rhythm.swift` | Overtone-ghost filter, tempo estimate, beat tracking, quantization, downbeat choice |
| | `Notation.swift` | Key detection, spelling, hand split, measure/tie/beam layout |
| | `ScoreBuilder.swift`, `MusicXMLWriter.swift`, `MIDIWriter.swift` | Top level and output |
| `Transcriber` (macOS) | `AudioDecoder.swift`, `BasicPitchModel.swift` | Model compiled at runtime and cached in `~/Library/Application Support/PianoScribe/nmp-icassp2022-v1.mlmodelc`. Runs `.cpuOnly`, as Basic Pitch's own Core ML path does. I/O names: `input_2` → `Identity_1` (note), `Identity_2` (onset) |
| `PianoScribe` (app) | `AppState`, `ContentView`, `ScoreView` (WKWebView bridge), `Playback`, `Resources/Web/score.html` | JS bridge functions: `renderScore(xml)`, `setZoom(z)`, `preparePrint(bool)`. The page posts `ready` / `rendered` / `error` messages to the `score` handler |

Resource lookup checks the `.app` layout (`Contents/Resources/PianoScribe_*.bundle`) before falling
back to `Bundle.module`, because SwiftPM's generated accessor doesn't look in `Contents/Resources`.

## Notation engine details (the part most likely to need tuning)

- **Tempo:** a grid search over 40–240 BPM in 0.5 steps, then 0.05 refinement. The score is the
  circular resultant of onset times at the beat, ½-beat and ¼-beat periods (⅓ and ⅙ in 6/8),
  averaged over 10 s windows, times a log-normal prior centered at 100 BPM (70 for 6/8). Octave
  errors (½×/2×) are possible; the UI has buttons for them.
- **Beats:** dynamic programming as in Ellis 2007 / librosa (tightness 100) on a 100 Hz onset
  envelope built from note starts weighted by amplitude, then extrapolated to cover all notes.
  This handles gradual drift but not rubato or sudden tempo changes.
- **Quantization:** time → continuous beat position (linear between tracked beats) → 16th grid
  (or 8th). Note ends are biased 0.3 of a grid step earlier, because ends detected from audio run
  long. Same-pitch overlaps are trimmed, and duplicates at the same start are dropped.
- **Downbeat:** picks the beat offset that maximizes amplitude-weighted onsets on candidate
  downbeats, with extra weight for bass notes and long notes. Pickups become rests.
- **Key:** Krumhansl–Kessler profiles on a duration × amplitude pitch-class histogram. Spelling
  picks the line-of-fifths position nearest the key center (so E♯ in F♯ major, C♭ in G♭ major).
- **Hands:** per onset group, the split point that minimizes distance to running left/right-hand
  centers (starting at 48 and 67), with penalties for spans over an octave or more than 5 notes.
  Can also use a fixed split note.
- **Layout:** one voice per staff, with chords. A chord lasts until the next onset in that staff;
  gaps up to half a beat are closed (legato) to avoid fussy rests. Durations are split at barlines
  (tied) and decomposed into notatable values per beat. Beams group 8ths and shorter within a beat,
  with second-level beams and hooks for 16ths. Accidentals are tracked per measure per staff.
- **Overtone filter:** drops a note that starts within 50 ms of a louder note (amplitude
  ratio < 0.8) that sits a harmonic interval below it (12, 19, 24, 28, 31, 34 or 36 semitones).
  This may occasionally remove a real, quieter octave doubling.

## Testing approach

`Tests/Reference/` holds a Python reference implementation (`bp_ref.py`, `notation_ref.py`).
The Swift code is a line-for-line port of it, and the golden fixtures in
`Tests/ScoreKitTests/Fixtures` came from running it on a synthesized *Ode to Joy* (made by
`synth.py`: G major, ~96 BPM with ±3% drift and ±10 ms jitter).

Parity details that matter when editing either side:

- Python `round()` is banker's rounding; Swift uses `pyRound` (`.toNearestOrEven`).
- Integer `//` and `%` floor toward negative infinity; Swift uses `floorDiv` / `floorMod`.
- Squares are written `x * x` in both languages, not `**2`.
- Sorts carry explicit tie-breakers.
- The refinement loop bound in tempo search deliberately moves with the best BPM, as in Python.

To change the algorithm, change both implementations, then run
`python3 Tests/Reference/gen_fixtures.py path/to/nmp.onnx`. That needs numpy, scipy, onnxruntime
and ffmpeg; `nmp.onnx` is in the basic-pitch repo at `basic_pitch/saved_models/icassp_2022/`.

Results on the synthesized test: the right hand is transcribed exactly. The left hand is readable
but has a few false notes from the model (repeated D3s and similar).

## Known limitations

- It's built for solo piano. Full mixes put every instrument onto the piano staves.
- No triplets, no multiple voices per hand, no pedal markings, no tempo changes within a piece.
- Basic Pitch is a general-purpose model, so accuracy on piano is below piano-specific models.
- The key override always writes `mode=major` (the key signature is still correct for the
  relative minor).
- Verovio (6.3.0, LGPL-3.0) is bundled as an unmodified script. Basic Pitch is Apache-2.0
  (see `ThirdParty/`).

## Ideas / next steps

1. Run `swift test` on the Mac and confirm Core ML vs ONNX parity (expected mean |diff| < 0.01).
2. Try real piano recordings and tune the overtone ratio, end bias, gap fill and hand-split
   penalties.
3. A piano-specific model (for example ByteDance's high-resolution piano transcription via
   coremltools) for better accuracy and pedal detection.
4. A second voice in a hand when a long note is held under moving notes; triplet detection;
   a "simplify" mode.
5. Source separation (for example Demucs) before transcription, for non-solo recordings.
6. Editing in the app (click a note to delete or move it), or round-tripping through MuseScore.
