"""Generate golden fixtures for the Swift tests from the Python reference implementation.

Usage (from this folder):  python3 gen_fixtures.py path/to/nmp.onnx
Needs numpy, scipy, onnxruntime and ffmpeg. nmp.onnx is in the basic-pitch repo:
basic_pitch/saved_models/icassp_2022/nmp.onnx
"""
import json, os, subprocess, sys
import numpy as np
import bp_ref
import notation_ref as nr

HERE = os.path.dirname(os.path.abspath(__file__))
ONNX = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "nmp.onnx")
FIX = os.path.join(HERE, "..", "ScoreKitTests", "Fixtures")
TFIX = os.path.join(HERE, "..", "TranscriberTests", "Fixtures")
MEDIA = os.path.join(HERE, "build")
os.makedirs(FIX, exist_ok=True); os.makedirs(TFIX, exist_ok=True); os.makedirs(MEDIA, exist_ok=True)

subprocess.run([sys.executable, os.path.join(HERE, "synth.py"), os.path.join(MEDIA, "ode")], check=True)
audio = np.load(os.path.join(MEDIA, "ode.npy"))
note, onset = bp_ref.run_model(audio, ONNX)
note, onset = note.astype(np.float32), onset.astype(np.float32)

# --- activations
with open(f"{FIX}/ode_activations.bin", "wb") as f:
    f.write(note.astype("<f4").tobytes()); f.write(onset.astype("<f4").tobytes())

decoder_cases = []
for (ot, ft, ms, mel, inf) in [(0.5, 0.3, 127.7, True, True), (0.3, 0.2, 58.0, False, True), (0.6, 0.4, 200.0, True, False)]:
    min_len = int(np.round(ms / 1000 * (bp_ref.SR / bp_ref.FFT_HOP)))
    raw = bp_ref.output_to_notes_polyphonic(note, onset, ot, ft, min_len, infer_onsets=inf, melodia_trick=mel)
    times = bp_ref.model_frames_to_time(note.shape[0])
    decoder_cases.append({
        "onsetThreshold": ot, "frameThreshold": ft, "minNoteLengthMs": ms, "melodiaTrick": mel, "inferOnsets": inf,
        "minNoteLengthFrames": min_len,
        "raw": [{"startFrame": s, "endFrame": e, "pitch": p, "amplitude": a} for s, e, p, a in raw],
        "events": [{"start": float(times[s]), "end": float(times[e]), "pitch": p, "amplitude": a} for s, e, p, a in raw],
    })
json.dump({"frames": int(note.shape[0]), "pitches": 88, "audioLength": int(len(audio)), "cases": decoder_cases},
          open(f"{FIX}/ode_decoder_expected.json", "w"))

# --- windowing
win = []
for L in [1, 1000, 36163, 36164, 43844, 100000, len(audio)]:
    w = bp_ref.windows(np.zeros(L, dtype=np.float32))
    win.append({"length": L, "windows": len(w), "frames": int(L / bp_ref.HOP_SIZE * (bp_ref.ANNOT_N_FRAMES - bp_ref.N_OVERLAP_FRAMES))})
times = bp_ref.model_frames_to_time(400)
json.dump({"cases": win, "frameTimes400": [float(t) for t in times]}, open(f"{FIX}/windowing_expected.json", "w"))

# --- notation
events = [(e["start"], e["end"], e["pitch"], e["amplitude"]) for e in decoder_cases[0]["events"]]
truth = [tuple(x) for x in json.load(open(os.path.join(MEDIA, "ode_truth.json")))]
cases = [
    ("model_44_auto", events, dict(time_sig="4/4")),
    ("model_34_auto", events, dict(time_sig="3/4")),
    ("model_68_auto", events, dict(time_sig="6/8")),
    ("model_44_fixed", events, dict(time_sig="4/4", bpm=96.0, grid="8th", hands="fixed", split_pitch=60, key_fifths=-2, overtones=False)),
    ("truth_44_auto", truth, dict(time_sig="4/4")),
]
out = []
for name, evs, kw in cases:
    sc = nr.build_score(evs, title=f"Test {name}", **kw)
    xml = nr.to_musicxml(sc)
    open(f"{FIX}/{name}.musicxml", "w").write(xml)
    opts = {"timeSignature": kw.get("time_sig", "4/4"), "bpm": kw.get("bpm"), "grid": kw.get("grid", "16th"),
            "hands": kw.get("hands", "auto"), "splitPitch": kw.get("split_pitch", 60), "keyFifths": kw.get("key_fifths"),
            "removeOvertones": kw.get("overtones", True), "title": f"Test {name}"}
    out.append({"name": name, "input": "truth" if evs is truth else "model", "options": opts,
                "bpm": sc["bpm"], "fifths": sc["fifths"], "mode": sc["mode"], "measures": sc["n_measures"],
                "rhPitches": [p for m in sc["staves"][1] for pc in m if pc["kind"] == "note" and not pc["tie_stop"] for p in pc["pitches"]]})
json.dump({"truthEvents": [{"start": s, "end": e, "pitch": p, "amplitude": a} for s, e, p, a in truth],
           "cases": out}, open(f"{FIX}/notation_expected.json", "w"))

# --- Core ML parity fixture: window #3 of the test audio and the ONNX outputs for it
import onnxruntime as ort
sess = ort.InferenceSession(ONNX, providers=["CPUExecutionProvider"])
w = bp_ref.windows(audio)[3].astype(np.float32)
n3, o3 = sess.run(["StatefulPartitionedCall:1", "StatefulPartitionedCall:2"], {"serving_default_input_2:0": w[None, :, None]})
with open(f"{TFIX}/window3_audio.bin", "wb") as f: f.write(w.astype("<f4").tobytes())
with open(f"{TFIX}/window3_onnx.bin", "wb") as f:
    f.write(n3[0].astype("<f4").tobytes()); f.write(o3[0].astype("<f4").tobytes())
subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=0x202830:s=640x360:r=10",
                "-i", os.path.join(MEDIA, "ode.wav"), "-shortest", "-c:v", "libx264", "-preset", "veryfast",
                "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", f"{TFIX}/ode-to-joy-test.mp4"], check=True)
print("ok", [c["name"] for c in out], [len(c["raw"]) for c in decoder_cases])
for c in out: print(c["name"], round(c["bpm"], 2), c["fifths"], c["mode"], c["measures"], c["rhPitches"][:12])
