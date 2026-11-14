# Song search test – 2026-11-14 14:56

Title: `"Heartless" von Isabel van Gelder` → search `Isabel van Gelder - Heartless`

| Link | URL | Result |
|---|---|---|
| Spotify app (candidate) | `spotify:search:Isabel%20van%20Gelder%20Heartless` | ❌ App öffnet sich im Startfenster aber sucht nicht nach dem Song |
| Spotify app (candidate) | `spotify://search/Isabel%20van%20Gelder%20Heartless` | ✅ works |
| Spotify app (candidate) | `spotify:search:Isabel+van+Gelder+Heartless` | ✅ works |
| Amazon Music web (candidate) | `https://music.amazon.de/search/Isabel%20van%20Gelder%20Heartless?filter=IsLibrary%7Cfalse&sc=none` | ❌ Es zeigt eine Website wo ich mindestens drei Künstler aussuchen soll |
| Amazon Music web (candidate) | `https://music.amazon.de/search?keywords=Isabel%20van%20Gelder%20Heartless` | ❌ es kam wieder die gleiche anzeige |
| Amazon Music web (candidate) | `https://www.amazon.de/s?k=Isabel+van+Gelder+Heartless&i=digital-music` | ✅ works |
| Qobuz web (candidate) | `https://www.qobuz.com/de-de/search?q=Isabel%20van%20Gelder%20Heartless` | ❌ du hast nach alben gesucht. in der url musst du statt nach albums tracks einfügen |
