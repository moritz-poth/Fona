#!/bin/bash
# Checks the song search by hand: opens every link Fona would open for a known song, you answer whether the
# service shows the search for it. Also tries candidate app links (not yet used by Fona) for installed apps.
# Usage: scripts/test-music-search.sh ["Stream title"]   → results in docs/music-search-test.md
set -u
cd "$(dirname "$0")/.."
TITLE=${1:-"\"Heartless\" von Isabel van Gelder"}
OUT=docs/music-search-test.md
swift build -q --product fona-probe || exit 1
LINES=$(.build/debug/fona-probe musicsearch "$TITLE") || { echo "Fona finds no artist/track in: $TITLE"; exit 1; }
Q=$(echo "$LINES" | head -1 | cut -f2)
QE=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$Q")
echo "Title: $TITLE"; echo "Search: $Q"; echo

# candidate app links per service, tried only when the app is installed: "Service|bundle id|url"
CANDIDATES="Apple Music|com.apple.Music|music://music.apple.com/de/search?term=$QE
Apple Music|com.apple.Music|itmss://music.apple.com/de/search?term=$QE
Apple Music|com.apple.Music|musics://music.apple.com/de/search?term=$QE
Deezer|com.deezer.deezer-desktop|deezer://www.deezer.com/search/$QE
TIDAL|com.tidal.desktop|tidal://search?q=$QE
Amazon Music|com.amazon.music|amznmp3://search?keywords=$QE
Qobuz|com.qobuz.QobuzDesktop|qobuzapp://search?q=$QE"

installed() { [ -n "$(mdfind "kMDItemCFBundleIdentifier == '$1'" 2>/dev/null | head -1)" ]; }
ask() {  # $1 label, $2 url → appends a row
    echo "→ $1"; echo "  $2"
    open "$2" 2>/dev/null || { echo "  (macOS cannot open it)"; echo "| $1 | \`$2\` | cannot open |" >> "$OUT"; return; }
    read -r -p "  Search for the song visible? [j/n/s=skip] " a </dev/tty
    case $a in j|J|y) r="✅ works";; n|N) read -r -p "  What happened? " w </dev/tty; r="❌ $w";; *) r="skipped";; esac
    echo "| $1 | \`$2\` | $r |" >> "$OUT"
}

{ echo "# Song search test – $(date '+%Y-%m-%d %H:%M')"; echo; echo "Title: \`$TITLE\` → search \`$Q\`"; echo
  echo "| Link | URL | Result |"; echo "|---|---|---|"; } > "$OUT"
echo "$LINES" | tail -n +2 | while IFS=$'\t' read -r name bundle app web; do
    if [ "$bundle" != "-" ] && installed "$bundle"; then ask "$name app (Fona)" "$app"; fi
    code=$(curl -s -o /dev/null -L --max-time 10 -w '%{http_code}' "$web")
    echo "  web $name answers HTTP $code"
    ask "$name web (Fona, HTTP $code)" "$web"
done
echo "$CANDIDATES" | while IFS='|' read -r name bundle url; do
    installed "$bundle" && ask "$name app (candidate)" "$url"
done
echo; echo "Results: $OUT"; cat "$OUT"
