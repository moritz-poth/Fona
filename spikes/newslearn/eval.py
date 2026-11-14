"""Honest check: learn markers on some hours, test detection on the others.
Usage: eval.py <recording dir> even|odd|<hh,hh,...>"""
import sys, os
import numpy as np
import learn as Lr

FPS = Lr.FPS
d, split = sys.argv[1], sys.argv[2]
fp, rms, st = Lr.load(d)
hours = sorted(st)[1:]  # first file is partial
if split in ("even", "odd"):
    train = [h for h in hours if int(h[-2:]) % 2 == (0 if split == "even" else 1)]
else:
    train = [h for h in hours if h[-2:] in split.split(",")]
starts = np.array([st[h] for h in sorted(st)])
names = sorted(st)


def where(i):
    k = np.searchsorted(starts, i, side="right") - 1
    s = (i - starts[k]) / FPS
    hh = int(names[k][-2:]) + int(s // 3600)
    return f"{hh:02d}:{int(s % 3600 // 60):02d}:{s % 60:04.1f}"


markers, tops = Lr.learn_starts(fp, st, train)
print(f"== {os.path.basename(d.rstrip('/'))}: train {[h[-2:] for h in train]} → {len(markers)} markers")
for m in markers:
    print(f"   {m['length']} s at {m['offset_s']:+.0f} s, thr {m['threshold']:.2f}, elsewhere ≥ {m['neg']:.2f}, explains {len(m['hits'])} training windows")
det = []
for m in markers:
    sc = Lr.scan(fp, m["template"])
    det += [(i, m) for i in Lr.peaks(sc, m["threshold"])]
marks = Lr.marks_in(starts[1], len(fp) - int(150 * FPS), sorted(st.values()), True)
hit = {}
out = []
for i, m in det:
    k = int(np.argmin(np.abs(marks - i)))
    if abs(marks[k] - i) < 90 * FPS:
        hit.setdefault(k, i - int(m["offset_s"] * FPS))
    else:
        out.append(i)
test = [k for k in range(len(marks)) if names[np.searchsorted(starts, marks[k], side="right") - 1] not in train]
print(f"test windows: {len(test)}, with detection {sum(k in hit for k in test)}; FALSE ALARMS (whole recording) {len(out)}")
print("  test detected:", " ".join(where(hit[k]) for k in test if k in hit))
print("  test missed:  ", " ".join(where(marks[k]) for k in test if k not in hit))
if out:
    print("  false:", " ".join(where(i) for i in out))
