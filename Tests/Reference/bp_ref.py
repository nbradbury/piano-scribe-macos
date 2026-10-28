"""Reference Basic Pitch pipeline (numpy), mirrors basic_pitch/inference.py + note_creation.py
without librosa/pretty_midi. Used to produce golden data for the Swift port."""
import numpy as np
import scipy.signal

SR = 22050
FFT_HOP = 256
AUDIO_N_SAMPLES = SR * 2 - FFT_HOP          # 43844
ANNOTATIONS_FPS = SR // FFT_HOP             # 86
ANNOT_N_FRAMES = ANNOTATIONS_FPS * 2        # 172
N_OVERLAP_FRAMES = 30
OVERLAP_LEN = N_OVERLAP_FRAMES * FFT_HOP    # 7680
HOP_SIZE = AUDIO_N_SAMPLES - OVERLAP_LEN    # 36164
MIDI_OFFSET = 21
MAX_FREQ_IDX = 87
MAGIC_ALIGNMENT_OFFSET = 0.0018


def windows(audio):
    padded = np.concatenate([np.zeros(OVERLAP_LEN // 2, dtype=np.float32), audio])
    out = []
    for i in range(0, padded.shape[0], HOP_SIZE):
        w = padded[i:i + AUDIO_N_SAMPLES]
        if len(w) < AUDIO_N_SAMPLES:
            w = np.pad(w, (0, AUDIO_N_SAMPLES - len(w)))
        out.append(w)
    return out


def run_model(audio, onnx_path):
    import onnxruntime as ort
    sess = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
    notes, onsets = [], []
    for w in windows(audio):
        n, o = sess.run(["StatefulPartitionedCall:1", "StatefulPartitionedCall:2"],
                        {"serving_default_input_2:0": w[None, :, None].astype(np.float32)})
        notes.append(n[0]); onsets.append(o[0])
    return unwrap(np.stack(notes), len(audio)), unwrap(np.stack(onsets), len(audio))


def unwrap(output, original_length):
    n_olap = N_OVERLAP_FRAMES // 2
    output = output[:, n_olap:-n_olap, :]
    flat = output.reshape(-1, output.shape[2])
    n_frames_per_window = ANNOT_N_FRAMES - N_OVERLAP_FRAMES
    return flat[: int(original_length / HOP_SIZE * n_frames_per_window), :]


def model_frames_to_time(n_frames):
    idx = np.arange(n_frames)
    original = idx * FFT_HOP / SR
    window_numbers = np.floor(idx / ANNOT_N_FRAMES)
    window_offset = (FFT_HOP / SR) * (ANNOT_N_FRAMES - (AUDIO_N_SAMPLES / FFT_HOP)) + MAGIC_ALIGNMENT_OFFSET
    return original - window_offset * window_numbers


def inferred_onsets(onsets, frames, n_diff=2):
    diffs = []
    for n in range(1, n_diff + 1):
        app = np.concatenate([np.zeros((n, frames.shape[1])), frames])
        diffs.append(app[n:, :] - app[:-n, :])
    fd = np.min(diffs, axis=0)
    fd[fd < 0] = 0
    fd[:n_diff, :] = 0
    m = np.max(fd)
    if m > 0:
        fd = np.max(onsets) * fd / m
    return np.max([onsets, fd], axis=0)


def output_to_notes_polyphonic(frames, onsets, onset_thresh, frame_thresh, min_note_len,
                               infer_onsets=True, melodia_trick=True, energy_tol=11):
    frames = frames.astype(np.float64)
    onsets = onsets.astype(np.float64)
    n_frames = frames.shape[0]
    if infer_onsets:
        onsets = inferred_onsets(onsets, frames)
    peak = np.zeros(onsets.shape)
    peaks = scipy.signal.argrelmax(onsets, axis=0)
    peak[peaks] = onsets[peaks]
    onset_idx = np.where(peak >= onset_thresh)
    t_idx = onset_idx[0][::-1]
    f_idx = onset_idx[1][::-1]
    remaining = frames.copy()
    notes = []
    for s, f in zip(t_idx, f_idx):
        if s >= n_frames - 1:
            continue
        i = s + 1; k = 0
        while i < n_frames - 1 and k < energy_tol:
            k = k + 1 if remaining[i, f] < frame_thresh else 0
            i += 1
        i -= k
        if i - s <= min_note_len:
            continue
        remaining[s:i, f] = 0
        if f < MAX_FREQ_IDX: remaining[s:i, f + 1] = 0
        if f > 0: remaining[s:i, f - 1] = 0
        notes.append((int(s), int(i), int(f + MIDI_OFFSET), float(np.mean(frames[s:i, f]))))
    if melodia_trick:
        while np.max(remaining) > frame_thresh:
            i_mid, f = np.unravel_index(np.argmax(remaining), remaining.shape)
            remaining[i_mid, f] = 0
            i = i_mid + 1; k = 0
            while i < n_frames - 1 and k < energy_tol:
                k = k + 1 if remaining[i, f] < frame_thresh else 0
                remaining[i, f] = 0
                if f < MAX_FREQ_IDX: remaining[i, f + 1] = 0
                if f > 0: remaining[i, f - 1] = 0
                i += 1
            i_end = i - 1 - k
            i = i_mid - 1; k = 0
            while i > 0 and k < energy_tol:
                k = k + 1 if remaining[i, f] < frame_thresh else 0
                remaining[i, f] = 0
                if f < MAX_FREQ_IDX: remaining[i, f + 1] = 0
                if f > 0: remaining[i, f - 1] = 0
                i -= 1
            i_start = i + 1 + k
            if i_end - i_start <= min_note_len:
                continue
            notes.append((int(i_start), int(i_end), int(f + MIDI_OFFSET), float(np.mean(frames[i_start:i_end, f]))))
    return notes


def notes_to_events(frames, onsets, onset_thresh=0.5, frame_thresh=0.3, min_note_ms=127.7):
    min_len = int(np.round(min_note_ms / 1000 * (SR / FFT_HOP)))
    raw = output_to_notes_polyphonic(frames, onsets, onset_thresh, frame_thresh, min_len)
    times = model_frames_to_time(frames.shape[0])
    return [(float(times[s]), float(times[e]), p, a) for s, e, p, a in raw]
