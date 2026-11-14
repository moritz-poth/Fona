"""Learn one station from its recording folder and check the result on every recorded hour.

Usage: run.py <recording dir> [train hours, e.g. 03,04,05,06]   (default: the first six complete hours)
Prints: learned start marker, detections (inside/outside the :00/:30 windows, misses), repeated sounds after the
start (end candidates) and learned news titles.
"""
import sys, re, os, collections
import numpy as np
import learn as Lr
import fp as F

FPS = Lr.FPS


def titles(d):
    """[(frame, title)] on the joined timeline (byte offset → seconds assumes 128 kbit/s)"""
    out = []
    p = os.path.join(d, "titles.log")
    if not os.path.exists(p):
        return out
    for l in open(p, errors="replace"):
        m = re.match(r"\S+ (\d{8}-\d\d)\.mp3 ([\d.]+) StreamTitle='(.*?)';", l)
        if m:
            out.append((m.group(1), float(m.group(2)), m.group(3).strip()))
    return out


def main():
    d = sys.argv[1]
    fp, rms, st = Lr.load(d)
    hours = sorted(st)
    full = [h for h in hours[1:-1]]  # first and last file are partial
    train = [h for h in full if h[-2:] in sys.argv[2].split(",")] if len(sys.argv) > 2 else full[:6]
    starts = np.array([st[h] for h in hours])

    def where(i):
        k = np.searchsorted(starts, i, side="right") - 1
        s = (i - starts[k]) / FPS
        return f"{hours[k][6:8]}/{hours[k][-2:]}:{int(s // 60):02d}:{s % 60:04.1f}"

    print(f"== {os.path.basename(d.rstrip('/'))}: {len(hours)} files {hours[0]}..{hours[-1]}, train {[h[-2:] for h in train]}")
    m = Lr.learn_start(fp, st, train)
    if not m:
        print("no repeated sound around :00 in the training hours")
        return
    print(f"start marker: {m['length']} s at {m['offset_s']:+.1f} s from :00, threshold {m['threshold']:.2f}, "
          f"training scores {m['pos']}, best elsewhere {m['neg']:.2f}, margin {m['margin']:.2f}")
    sc = Lr.scan(fp, m["template"])
    det = Lr.peaks(sc, m["threshold"])
    marks = Lr.marks_in(starts[1], len(fp), sorted(st.values()), True)
    near = lambda i: np.min(np.abs(marks - i)) < 90 * FPS
    inwin = [i for i in det if near(i)]
    out = [i for i in det if not near(i)]
    found = {int(np.argmin(np.abs(marks - i))) for i in inwin}
    print(f"detections in :00/:30 window {len(inwin)}, OUTSIDE {len(out)}")
    if out:
        print("  outside:", " ".join(f"{where(i)}({sc[i]:.2f})" for i in out))
    print("  found:", " ".join(where(i) for i in inwin))
    print("  marks without:", " ".join(where(marks[k]) for k in range(len(marks)) if k not in found))

    # end candidates: sounds repeating 1–15 min after the detected starts
    news0 = [i - int(m["offset_s"] * FPS) for i in inwin]  # news start ≈ marker position − offset
    a0, a1 = 60, 900
    W = [fp[s + int(a0 * FPS): s + int(a1 * FPS)] for s in news0 if s + int(a1 * FPS) < len(fp)][:10]
    if len(W) >= 3:
        cov = Lr.coverage_fast(W, 180)
        print("end candidates (time after start, length, share of other bulletins):")
        for i, w in enumerate(W):
            rs = Lr.regions(cov[i] >= 0.15, int(1.5 * FPS))
            print("  ", where(news0[i]), [(f"{int((a / FPS + a0) // 60)}:{(a / FPS + a0) % 60:04.1f}", round((b - a) / FPS, 1),
                                         round(float(cov[i][a:b].mean()), 2)) for a, b in rs])

    e = Lr.learn_end(fp, news0)
    if e:
        print(f"END marker: ends {e['at_s']:.0f} s after the start in the reference bulletin, threshold {e['threshold']:.2f}, scores {e['scores']}")
        lens = []
        for n in news0:
            w = fp[n + int(60 * FPS): n + int(900 * FPS)]
            if len(w) <= len(e["template"]):
                continue
            s2 = Lr.scan(w, e["template"])
            k = int(np.argmin(s2))
            lens.append(f"{where(n)}→{(k + len(e['template'])) / FPS / 60 + 1:.1f}min" if s2[k] < e["threshold"] else f"{where(n)}→none")
        print("  bulletin lengths:", " ".join(lens))
    else:
        print("END marker: none (title / max length only)")

    # titles: what the station sends around the detected starts vs. elsewhere
    T = titles(d)
    if T:
        at = lambda h, s: st[h] + int(s * FPS) if h in st else None
        near_news = collections.Counter(); elsewhere = collections.Counter()
        for h, s, t in T:
            p = at(h, s)
            if p is None:
                continue
            key = re.sub(r"\d", "#", t)[:60]
            if any(-30 * FPS <= p - n <= 120 * FPS for n in news0):
                near_news[key] += 1
            else:
                elsewhere[key] += 1
        print("titles near news starts (count near / elsewhere):")
        for k, n in near_news.most_common(6):
            print(f"   {n:3d} / {elsewhere[k]:4d}  {k!r}")
        print("  titles over time after each start:")
        for n in news0[:4]:
            seq = [(round((st[h] + int(s * FPS) - n) / FPS), t[:40]) for h, s, t in T if h in st and -20 * FPS < st[h] + int(s * FPS) - n < 900 * FPS]
            print("   ", where(n), seq[:12])


if __name__ == "__main__":
    main()
