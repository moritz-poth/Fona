"""Honest check of the news END: learn on even (or odd) hours, predict on the others, compare with the title end.
Starts and true ends come from the learned title rule (titles.py), so only stations with news titles can be checked.
Predictors: (a) learned audio end marker (learn.learn_end), (b) typical length from the training bulletins.
Usage: endeval.py <recording dir> even|odd
"""
import sys, os, datetime as D, statistics as S
import numpy as np
import learn as Lr
import titles as T

FPS = Lr.FPS
d, split = sys.argv[1], sys.argv[2]
fp, rms, st = Lr.load(d)
names = sorted(st)
log = T.read(d)
news, filler, _ = T.learn(log)
first = log[0][0]  # first file starts at connect


def frame(ts):
    h = ts.strftime("%Y%m%d-%H")
    if h not in st:
        return None
    t0 = first if h == names[0] else D.datetime.strptime(h, "%Y%m%d-%H")
    return st[h] + int((ts - t0).total_seconds() * FPS)


b = [(frame(a), frame(e), a) for a, e in T.bulletins(log, news, filler)]
b = [(s, e, a) for s, e, a in b if s is not None and e is not None and s + int(900 * FPS) < len(fp)]
is_train = lambda a: a.hour % 2 == (0 if split == "even" else 1)
train = [x for x in b if is_train(x[2])]
test = [x for x in b if not is_train(x[2])]
typical = S.median((e - s) / FPS for s, e, _ in train)
m = Lr.learn_end(fp, [s for s, _, _ in train], share=float(os.environ.get("NL_SHARE", "0.6")))
print(f"== {os.path.basename(d.rstrip('/'))} {split}: {len(train)} train / {len(test)} test bulletins, typical length {typical / 60:.1f} min,"
      f" end marker {'none' if not m else f'{m['at_s']:.0f} s after start, thr {m['threshold']:.2f}'}")
err_m, err_t, miss = [], [], 0
for s, e, a in test:
    true = (e - s) / FPS
    err_t.append(typical - true)
    if m:
        w = fp[s + int(60 * FPS): s + int(900 * FPS)]
        sc = Lr.scan(w, m["template"])
        k = int(np.argmin(sc))
        if sc[k] < m["threshold"]:
            err_m.append((k + len(m["template"])) / FPS + 60 - true)
        else:
            miss += 1
f = lambda xs: f"median |err| {S.median(abs(x) for x in xs):.0f} s, worst early {min(xs):.0f} s, worst late {max(xs):.0f} s" if xs else "–"
print(f"   typical length: {f(err_t)}")
print(f"   end marker:     {f(err_m)}; no match in {miss} of {len(test)}")
