#!/usr/bin/env python3
"""P0-b: records Deutschlandfunk (MP3 + ICY titles) in hourly files for news-detection calibration.

Usage: record-dlf.py <out_dir> <hours>
Writes <out_dir>/YYYYMMDD-HH.mp3 and titles.log ("<iso time> <file> <seconds into file> <title>").
Reconnects after drops. Recordings are copyrighted: keep them out of the repo (design/research is git-ignored).
"""
import sys, time, datetime, urllib.request, os

URL = "https://st01.sslstream.dlf.de/dlf/01/128/mp3/stream.mp3"
BYTES_PER_SEC = 16000  # 128 kbit/s


def main():
    out, hours = sys.argv[1], float(sys.argv[2])
    os.makedirs(out, exist_ok=True)
    end = time.time() + hours * 3600
    log = open(os.path.join(out, "titles.log"), "a", buffering=1)
    while time.time() < end:
        try:
            req = urllib.request.Request(URL, headers={"Icy-MetaData": "1", "User-Agent": "Fona-research/0"})
            r = urllib.request.urlopen(req, timeout=20)
            metaint = int(r.headers["icy-metaint"])
            name, f, nbytes, last = None, None, 0, None
            log.write(f"{datetime.datetime.now().isoformat(timespec='seconds')} - - CONNECT\n")
            while time.time() < end:
                hour = datetime.datetime.now().strftime("%Y%m%d-%H")
                if hour != name:
                    if f:
                        f.close()
                    name, nbytes = hour, 0
                    f = open(os.path.join(out, name + ".mp3"), "ab")
                chunk = r.read(metaint)
                if len(chunk) < metaint:
                    raise IOError("short read")
                f.write(chunk)
                nbytes += len(chunk)
                n = r.read(1)[0] * 16
                if n:
                    meta = r.read(n).rstrip(b"\0").decode("utf-8", "replace")
                    if meta != last:
                        last = meta
                        log.write(f"{datetime.datetime.now().isoformat(timespec='seconds')} {name}.mp3 {nbytes / BYTES_PER_SEC:.1f} {meta}\n")
        except Exception as e:  # keep recording through network hiccups
            log.write(f"{datetime.datetime.now().isoformat(timespec='seconds')} - - ERROR {e!r}\n")
            time.sleep(5)


if __name__ == "__main__":
    main()
