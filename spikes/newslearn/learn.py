"""Learns a station's news markers from a few recorded full hours, without per-station hand work.

Idea: whatever sounds the same around :00 in most hours (opener, jingle, time signal) marks the start of the news;
whatever repeats a few minutes later in most hours (outro, weather/traffic jingle, programme ident) marks the end.
"""
import os, sys, re, json
import numpy as np
import fp as F

FPS = F.FPS


def load(d):
    """All hourly fingerprints of a recording folder joined into one timeline.
    Returns fp, rms, {hour 'YYYYMMDD-HH': start frame}."""
    files = sorted(f for f in os.listdir(d) if re.fullmatch(r"\d{8}-\d{2}\.mp3", f))
    fps, rmss, starts, pos = [], [], {}, 0
    for f in files:
        a, r = F.file_fp(os.path.join(d, f), os.path.join(d, "fp"))
        starts[f[:-4]] = pos
        fps.append(a); rmss.append(r); pos += len(a)
    return np.concatenate(fps), np.concatenate(rmss), starts


def ber_track(a, b):
    """per-frame bit error rate of two equally long fingerprint runs"""
    return F.popcount(a ^ b) / 32.0


def smooth(x, n):
    k = np.ones(n)
    return np.convolve(x, k, mode="same") / np.convolve(np.ones_like(x), k, mode="same")  # no zero padding at the edges


def coverage(windows, max_lag_s, thr=0.30, smooth_s=1.0):
    """For each window: per frame, the fraction of the other windows that contain the same sound
    (at any lag up to max_lag_s). Windows are equally long fingerprint arrays."""
    L = len(windows[0]); ml = int(max_lag_s * FPS); sm = int(smooth_s * FPS)
    hits = np.zeros((len(windows), L))
    for i, a in enumerate(windows):
        for j, b in enumerate(windows):
            if i == j:
                continue
            best = np.zeros(L, dtype=bool)
            for lag in range(-ml, ml + 1):
                lo, hi = max(0, -lag), min(L, L - lag)
                e = smooth(ber_track(a[lo:hi], b[lo + lag:hi + lag]), sm)
                best[lo:hi] |= e < thr
            hits[i] += best
    return hits / (len(windows) - 1)


def regions(mask, min_len):
    out, start = [], None
    for i, m in enumerate(np.append(mask, False)):
        if m and start is None:
            start = i
        elif not m and start is not None:
            if i - start >= min_len:
                out.append((start, i))
            start = None
    return out


MODE = os.environ.get("NL_MODE", "hits")
FRAME_OK = 0.35


def scan(stream, template):
    """sliding score of the template over the whole stream, 0 = perfect, ~0.5/1 = unrelated.
    mean: mean bit error rate; hits: share of frames that do NOT match (robust to speech or music over part of it)."""
    T = len(template); N = len(stream) - T + 1
    acc = np.zeros(N, dtype=np.float32)
    lim = int(FRAME_OK * 32)
    for k in range(T):
        e = F.popcount(stream[k:k + N] ^ template[k])
        acc += (e > lim) if MODE == "hits" else e
    return acc / (T if MODE == "hits" else 32.0 * T)


def peaks(score, thr, gap_s=30):
    """local minima below thr, at least gap_s apart"""
    idx = np.where(score < thr)[0]
    out = []
    for i in idx:
        if out and i - out[-1] < gap_s * FPS:
            if score[i] < score[out[-1]]:
                out[-1] = i
        else:
            out.append(i)
    return out


def marks_in(n0, n1, starts_sorted, half):
    """frame positions of :00 (and :30) marks between n0 and n1"""
    out = []
    for s in starts_sorted:
        for m in ([0, 1800] if half else [0]):
            p = s + int(m * FPS)
            if n0 <= p < n1:
                out.append(p)
    return np.array(out)


def learn_start(fp, starts, train, pre=60, post=90, window_s=90):
    """Picks the stretch of sound around :00 that repeats in most training hours and occurs nowhere else.
    Returns dict(template, offset_s (template start relative to :00), threshold, margin)."""
    W = [fp[starts[h] - int(pre * FPS): starts[h] + int(post * FPS)] for h in train]
    cov = coverage(W, 20)
    ref = int(np.argmax((cov >= 0.5).sum(axis=1)))
    regs = regions(cov[ref] >= 0.5, int(1.5 * FPS))
    if not regs:
        return None
    # negatives: the whole training span except ±window around every :00 and :30
    all_starts = sorted(starts.values())
    n0 = min(starts[h] for h in train) - int(120 * FPS)
    n1 = max(starts[h] for h in train) + int(3600 * FPS)
    n0, n1 = max(0, n0), min(len(fp), n1)
    span = fp[n0:n1]
    excl = np.zeros(len(span), dtype=bool)
    for p in marks_in(n0, n1, all_starts, True):
        excl[max(0, p - n0 - int(window_s * FPS)): p - n0 + int(window_s * FPS)] = True
    tops = [starts[h] - n0 for h in train]
    best = None
    for a, b in regs:
        for length in (2.0, 3.0, 4.0):
            T = int(length * FPS)
            for s in range(a, max(a + 1, b - T + 1), int(0.5 * FPS)):
                if s + T > b:
                    break
                tpl = W[ref][s:s + T]
                sc = scan(span, tpl)
                pos = [sc[max(0, t - int(window_s * FPS)): t + int(window_s * FPS)].min() for t in tops]
                neg = sc[~excl[:len(sc)]].min()
                worst_pos = sorted(pos)[len(pos) // 6]  # tolerate one odd hour in six
                margin = neg - worst_pos
                if best is None or margin > best["margin"]:
                    best = dict(template=tpl, offset_s=(s - pre * FPS) / FPS, margin=float(margin),
                                threshold=float((neg + worst_pos) / 2), pos=[round(float(x), 2) for x in pos],
                                neg=float(neg), length=length)
    return best


def candidate_lags(a, b, max_lag, min_votes=3):
    """lags (b index - a index) where a and b share exact fingerprint values, voted; skips flat values"""
    vals, counts = np.unique(np.concatenate([a, b]), return_counts=True)
    common = set(vals[counts > max(40, (len(a) + len(b)) // 200)].tolist()) | {0, 0xFFFFFFFF}
    idx = {}
    for j, v in enumerate(b.tolist()):
        if v not in common:
            idx.setdefault(v, []).append(j)
    votes = {}
    flips = [0] + [1 << k for k in range(32)]
    for i, v in enumerate(a.tolist()):
        if v in common:
            continue
        for j in (j for f in flips for j in idx.get(v ^ f, ())):
            lag = j - i
            if abs(lag) <= max_lag:
                votes[lag // 4] = votes.get(lag // 4, 0) + 1  # bins of 4 frames
    lags = set()
    for k, n in votes.items():
        if n >= min_votes:
            lags.update(range(4 * k - 2, 4 * k + 6))
    return sorted(lags)


def coverage_fast(windows, max_lag_s, thr=0.30, smooth_s=1.0):
    """like coverage, but only checks lags suggested by exact fingerprint hits"""
    L = len(windows[0]); ml = int(max_lag_s * FPS); sm = int(smooth_s * FPS)
    hits = np.zeros((len(windows), L))
    for i, a in enumerate(windows):
        for j, b in enumerate(windows):
            if i == j:
                continue
            best = np.zeros(L, dtype=bool)
            for lag in candidate_lags(a, b, ml):
                lo, hi = max(0, -lag), min(L, L - lag)
                if hi - lo < sm:
                    continue
                e = smooth(ber_track(a[lo:hi], b[lo + lag:hi + lag]), sm)
                best[lo:hi] |= e < thr
            hits[i] += best
    return hits / (len(windows) - 1)
