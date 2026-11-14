"""Audio fingerprints for learning a station's news jingles (research spike, P1 "any news station").

32-bit Haitsma–Kalker style: 8 kHz mono, 64 ms window, 32 ms hop (31.25 frames/s), 33 log bands 300–3000 Hz,
bit = sign of the band-energy difference change over time. Identical audio through two encodes: BER ≈ 0.1–0.2,
unrelated audio: ≈ 0.5.
"""
import os, subprocess, sys
import numpy as np

SR = 8000
WIN, HOP = 512, 256
FPS = SR / HOP  # 31.25
_edges = np.geomspace(300, 3000, 34)
_bins = np.fft.rfftfreq(WIN, 1 / SR)
_band = [np.where((_bins >= _edges[i]) & (_bins < _edges[i + 1]))[0] for i in range(33)]
_win = np.hanning(WIN).astype(np.float32)
_pop8 = np.array([bin(i).count("1") for i in range(256)], dtype=np.uint8)


def decode(path, start=None, dur=None):
    cmd = ["ffmpeg", "-v", "quiet"]
    if start is not None:
        cmd += ["-ss", str(start)]
    cmd += ["-i", path]
    if dur is not None:
        cmd += ["-t", str(dur)]
    cmd += ["-f", "f32le", "-ac", "1", "-ar", str(SR), "pipe:1"]
    return np.frombuffer(subprocess.run(cmd, capture_output=True).stdout, dtype=np.float32)


def energies(pcm):
    n = 1 + max(0, (len(pcm) - WIN) // HOP)
    idx = np.arange(WIN)[None, :] + HOP * np.arange(n)[:, None]
    spec = np.abs(np.fft.rfft(pcm[idx] * _win, axis=1)) ** 2
    e = np.stack([spec[:, b].sum(axis=1) for b in _band], axis=1)
    return e, (pcm[idx] ** 2).mean(axis=1)


def fingerprint(pcm):
    """uint32 per frame (first frame is 0) plus RMS level per frame."""
    e, power = energies(pcm)
    d = e[:, :-1] - e[:, 1:]                     # 32 band differences
    bits = np.zeros_like(d, dtype=bool)
    bits[1:] = (d[1:] - d[:-1]) > 0
    w = (1 << np.arange(32, dtype=np.uint64)).astype(np.uint64)
    fp = (bits.astype(np.uint64) * w).sum(axis=1).astype(np.uint32)
    return fp, np.sqrt(power).astype(np.float32)


def popcount(x):
    """bit counts of a uint32 array"""
    return _pop8[x.view(np.uint8)].reshape(*x.shape, 4).sum(axis=-1)


def file_fp(path, cache_dir):
    """Fingerprint of a whole file, cached as .npz next to the cache dir."""
    os.makedirs(cache_dir, exist_ok=True)
    c = os.path.join(cache_dir, os.path.basename(path) + ".npz")
    if os.path.exists(c) and os.path.getmtime(c) > os.path.getmtime(path):
        z = np.load(c)
        return z["fp"], z["rms"]
    fp, rms = fingerprint(decode(path))
    np.savez(c, fp=fp, rms=rms)
    return fp, rms


if __name__ == "__main__":
    # fingerprint every mp3 of a recording folder (parallel), used before learn.py
    from concurrent.futures import ProcessPoolExecutor
    d = sys.argv[1]
    files = sorted(f for f in os.listdir(d) if f.endswith(".mp3"))
    with ProcessPoolExecutor(8) as ex:
        list(ex.map(file_fp, [os.path.join(d, f) for f in files], [os.path.join(d, "fp")] * len(files)))
    print(f"{len(files)} files fingerprinted")
