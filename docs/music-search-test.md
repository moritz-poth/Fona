# Song search test – 2026-11-14 14:30

Title: `"Heartless" von Isabel van Gelder` → search `Isabel van Gelder - Heartless`

| Link | URL | Result |
|---|---|---|
| Spotify app (Fona) | `spotify:search:Isabel%20van%20Gelder%20-%20Heartless` | ✅ works |
| Spotify web (Fona, HTTP 200) | `https://open.spotify.com/search/Isabel%20van%20Gelder%20-%20Heartless` | ✅ works |
| Apple Music web (Fona, HTTP 200) | `https://music.apple.com/de/search?term=Isabel%20van%20Gelder%20-%20Heartless` | ✅ works |
| YouTube Music web (Fona, HTTP 200) | `https://music.youtube.com/search?q=Isabel%20van%20Gelder%20-%20Heartless` | ✅ works |
| Amazon Music web (Fona, HTTP 200) | `https://music.amazon.de/search/Isabel%20van%20Gelder%20-%20Heartless` | ❌ Didn't show up, maybe wrong URL |
| Deezer web (Fona, HTTP 200) | `https://www.deezer.com/search/Isabel%20van%20Gelder%20-%20Heartless` | ✅ works |
| TIDAL web (Fona, HTTP 403) | `https://listen.tidal.com/search?q=Isabel%20van%20Gelder%20-%20Heartless` | ✅ works |
| Qobuz web (Fona, HTTP 200) | `https://play.qobuz.com/search?q=Isabel%20van%20Gelder%20-%20Heartless` | ❌ Login showed up |
| SoundCloud web (Fona, HTTP 200) | `https://soundcloud.com/search?q=Isabel%20van%20Gelder%20-%20Heartless` | ✅ works |
| Apple Music app (candidate) | `music://music.apple.com/de/search?term=Isabel%20van%20Gelder%20-%20Heartless` | ❌ App opened but without serachresults. I also can't see tthe serch string |
| Apple Music app (candidate) | `itmss://music.apple.com/de/search?term=Isabel%20van%20Gelder%20-%20Heartless` | ❌ App opened but without a search |
| Apple Music app (candidate) | `musics://music.apple.com/de/search?term=Isabel%20van%20Gelder%20-%20Heartless` | ❌ same as before |
