"""Learns which stream titles mean "news is on" from a station's title log – no per-station rules.

A title is a candidate if it contains a news word (German/English: "Nachrichten", "News" as a whole word). It is kept only if it
behaves like a bulletin: it comes and goes in short episodes (1–12 min), about once or twice an hour, in most hours.
A constant slogan ("MDR AKTUELL – Das Nachrichtenradio") or a rare one-off fails that test.
Bulletin: starts at the first news title, ends at the first other title that is not the learned filler (station slogan).
Usage: titles.py <recording dir> [<recording dir> …]
"""
import sys, os, re, datetime as D, statistics as S

NEWS_WORD = re.compile(r"\bnachrichten\b|\bnews\b", re.I)  # whole word: not "Nachrichtenradio", "…redaktion"


def norm(t):
    return re.sub(r"\s+", " ", re.sub(r"\d+", "#", t)).strip()


def read(d):
    out = []
    for l in open(os.path.join(d, "titles.log"), errors="replace"):
        m = re.match(r"(\S+) \S+ \S+ StreamTitle='(.*?)';", l)
        if m:
            out.append((D.datetime.fromisoformat(m.group(1)), norm(m.group(2))))
    return out


GAP = D.timedelta(minutes=3)


def clusters(times):
    """[(first, last)] of occurrence times closer than GAP to each other"""
    out = []
    for ts in times:
        if out and ts - out[-1][1] <= GAP:
            out[-1][1] = ts
        else:
            out.append([ts, ts])
    return out


def learn(log, min_hour_share=0.25, max_per_hour=2.5, max_span=12.0, filler_s=30):
    """Returns (news titles, filler titles, report). News title: contains a news word and comes in short clusters
    in most hours. Filler: the title that follows a news title within filler_s in most bulletins (station slogan)."""
    hours = (log[-1][0] - log[0][0]).total_seconds() / 3600
    news, report = set(), []
    for t in sorted({t for _, t in log if NEWS_WORD.search(t)}):
        cl = clusters([ts for ts, x in log if x == t])
        spans = [(b - a).total_seconds() / 60 for a, b in cl]
        hrs = {a.replace(minute=0, second=0, microsecond=0) for a, _ in cl}
        ok = len(hrs) >= min_hour_share * hours and len(cl) <= max_per_hour * hours and S.median(spans) <= max_span
        report.append((t, len(cl), round(len(hrs) / hours, 2), round(S.median(spans), 1), ok))
        if ok:
            news.add(t)
    onsets = [a for a, _ in clusters([ts for ts, x in log if x in news])]
    follow = {}
    for o in onsets:
        nxt = next(((ts, x) for ts, x in log if ts > o and x not in news), None)
        if nxt and (nxt[0] - o).total_seconds() <= filler_s + 60:  # first other title soon after the start
            follow[nxt[1]] = follow.get(nxt[1], 0) + 1
    filler = {x for x, n in follow.items() if n >= 0.3 * len(onsets)}
    return news, filler, report


def bulletins(log, news, filler, max_min=12):
    """[(start, end)]: start = first news title of a cluster, end = first later title that is neither news nor filler"""
    out = []
    for o, _ in clusters([ts for ts, x in log if x in news]):
        e = next((ts for ts, x in log if ts > o and x not in news and x not in filler), None)
        out.append((o, min(e, o + D.timedelta(minutes=max_min)) if e else o + D.timedelta(minutes=max_min)))
    return out


if __name__ == "__main__":
    for d in sys.argv[1:]:
        log = read(d)
        news, filler, rep = learn(log)
        print(f"== {os.path.basename(d.rstrip('/'))}: {len(log)} titles over {(log[-1][0] - log[0][0]).total_seconds() / 3600:.0f} h")
        for t, n, share, med, ok in rep:
            print(f"   {'NEWS' if ok else 'drop'} {n:4d} clusters, in {share:.0%} of hours, median span {med} min  {t[:60]!r}")
        print(f"   filler: {[f[:40] for f in filler]}")
        b = bulletins(log, news, filler)
        lens = [round((e - a).total_seconds() / 60, 1) for a, e in b]
        print(f"   → {len(b)} bulletins, length min/median/max {min(lens, default=0)}/{S.median(lens) if lens else 0}/{max(lens, default=0)} min")
        print("   ", " ".join(f"{a:%H:%M}+{l}" for (a, _), l in zip(b[:12], lens)))
