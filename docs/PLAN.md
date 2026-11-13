# Fona – Plan

Stand: 2026-11-12 · Version 2 (nach Goldfish-Review, `docs/goldfish_review_report.md`) · Status: bereit für erneuten Review

Fona ist eine macOS-Menüleisten-App für Internetradio:

1. **Radio hören:** Favoriten, „Zuletzt gehört“, alle Sender aus radio-browser.info mit Suche und Länderfilter, eigene Stream-Links über „+“, Anzeige des laufenden Titels.
2. **Nachrichten-Umschaltung:** Deutschlandfunk läuft stumm mit. Beginnen dort Nachrichten, blendet Fona vom laufenden Sender hinüber und danach zurück – wie früher die Verkehrsfunk-Taste (TA).

**Oberste Priorität ist Sicherheit** (Nutzerentscheidung 2026-11-11): Kein Stream, keine Senderliste und kein Titeltext darf ein Einfallstor in App oder System sein.

---

## 1 Umfang

**Drin (1.0)**
- Menüleisten-Fenster (SwiftUI `MenuBarExtra`, Stil `.window`) mit den Ansichten aus `design/canvas/` (§10).
- Icecast/Shoutcast (auch Shoutcast v1 `ICY 200 OK`) mit MP3 oder AAC/ADTS (LC und HE-AAC); HLS mit MPEG-TS- oder Packed-Audio-Segmenten (AAC/MP3).
- Laufender Titel (ICY `StreamTitle`), bereinigt.
- Favoriten (sortieren, entfernen, umbenennen), „Zuletzt gehört“ (10), alle Sender mit Suche, Länderfilter, „+“ für eigene Links.
- Nachrichten-Umschaltung für **Deutschlandfunk** (§6).
- Einstellungen, Support (Selbsttest, Problem melden, Protokoll, Buy me a coffee), Updater, Handbuch – Deutsch und Englisch.

**Nicht drin**
- Senderlogos aus dem Netz; Streams im Heimnetz oder auf dem eigenen Rechner; Pflicht-Proxys und Fake-IP-VPNs (Folge von N11).
- Verschlüsseltes HLS (AES, SAMPLE-AES), HLS mit fMP4, LATM, Ogg/Opus/FLAC.
- Andere Nachrichtensender als Deutschlandfunk; andere Stichworte als „Nachrichten“.
- Lautstärke, Mediatasten, Sleep-Timer, Aufnahme, Equalizer, Podcasts; Französisch und Spanisch.

## 2 Entscheidungen (alle vom Nutzer bestätigt)

| Thema | Entscheidung |
|---|---|
| Name | **Fona** (griech. *phōnē*; Phonograph) |
| Design | Entwurf A + „Zuletzt gehört“; eigener Look, nicht der Ferry/Mountpoint-Look |
| Farben | Aqua-Salbei `#BAD8D1`, Zeile `#E2EEEB`, Schalter `#6DB6A5`; Schrift auf Pastell immer `#1D1D1F` |
| App-Icon | Variante 7 (`design/icon/`) |
| Sprachen | Deutsch + Englisch |
| Vertrieb | GitHub-Releases, Updater mit Ed25519, universal (arm64 + x86_64) |
| macOS | Ziel 14; falls ein Baustein 15 erzwingt, 15 (Entscheidung in P0) |
| Überblendung | 80 ms Gleichleistung („2 Frames“ bei 25 fps) |
| Bei Pause | keine Umschaltung |
| Heimnetz | immer gesperrt |
| Logos | keine aus dem Netz |
| Sandbox | an; Austausch beim Update durch Hilfsprogramm |
| HLS | eigener Leser, kein AVPlayer |
| Netzwerk | **eigener HTTP/1.1-Client auf `NWConnection`** (2026-11-12): verbindet nur zu geprüften Adressen, keine Proxys |
| Decoder | **eigener XPC-Dienst ohne Rechte** für Demux + Dekodieren (2026-11-12) |
| Signatur | erst ad-hoc testen; verliert Fona nach Updates den Container-Zugriff oder fragt macOS → **eigenes, dauerhaftes Signaturzertifikat** im Schlüsselbund (2026-11-12) |
| Selbsttest | ausführlich, alle Funktionen; Bericht an `moritz-poth/fona-reports` |

## 3 Architektur

Swift Package (wie Mountpoint), SwiftUI, keine Fremdbibliotheken. Drei Programme im Bundle:

```
Fona.app                              Sandbox: network.client · Hardened Runtime
├─ Contents/MacOS/Fona
├─ Contents/XPCServices/FonaDecoder.xpc   Sandbox ohne jede Berechtigung · Hardened Runtime
└─ Contents/Helpers/FonaUpdater.app       keine Sandbox · Hardened Runtime · LSUIElement
```

**Module in Fona**
| Modul | Aufgabe |
|---|---|
| AppShell | MenuBarExtra, Einstellungen (`SettingsLink`/`openSettings` + `NSApp.activate`), Handbuch, About |
| UI | Popover-Ansichten, Dialog „Sender hinzufügen“, Hinweiskarten |
| Library | Favoriten, Verlauf, eigene Sender (§3.1) |
| Directory | radio-browser-Client (§3.3) |
| **NetGate** | einzige Netzwerkstelle (§4.1), HTTP/1.1 auf `NWConnection` |
| Stream | `SourceResolver` (Playlist → Stream, ICY oder HLS), `IcyReader`, `HlsReader`; reicht Rohbytes an FonaDecoder |
| Player | `AVAudioEngine` mit **einem** `AVAudioSourceNode`, der aus zwei lock-freien PCM-Ringpuffern (Programm, Nachrichten) liest und pro Sample mischt (Gleichleistungs-Rampe 80 ms). `engine.inputNode` wird nie angefasst. |
| News | NewsWatcher: ToneDetector, TitleMatcher, Zeitplan, Zustandsautomat (§6) |
| Sanitize | `Sanitize.display(_:)` – einzige Funktion für fremden Text (S4) |
| Support | Prüfkatalog, Selbsttest, Reporter, Log, Toast |
| Updater | Suche + Download über NetGate; übergibt an FonaUpdater (§7) |

**FonaDecoder (XPC)**: bekommt Rohbytes (TS-Pakete, ADTS/MP3-Frames, Packed-Audio-Segmente) und gibt PCM 48 kHz Float Stereo zurück. Enthält: `TsDemuxer` (PAT/PMT/PES, nur Audio; Streamtyp 0x0F ADTS, 0x03/0x04 MP3; 0x11 LATM abgelehnt), `FrameGuard` (strenger Frame-Prüfer vor Apples Decodern, S5), `AudioFileStream` + `AVAudioConverter` (HE-AAC über `kAudioFileStreamProperty_FormatList`; Formatwechsel und `#EXT-X-DISCONTINUITY` → Parser und Converter neu). Der Dienst hat weder Netz noch Dateien; stürzt er ab, startet Fona ihn neu und meldet „Stream abgebrochen“.

**Datenfluss:** URL → NetGate → SourceResolver → IcyReader/HlsReader (Bytes, Titel) → FonaDecoder (PCM) → Ringpuffer → AVAudioSourceNode.
Programm- und Nachrichtenkette laufen beide dauerhaft (Lesen, Dekodieren, Titel). Die Programmkette läuft während Nachrichten stumm weiter in ihren Ringpuffer – so bleibt die Verbindung lebendig, und die Rückkehr ist sofort live.

**Speicherorte (Sandbox-Container `~/Library/Containers/com.moritzpoth.fona/Data/…`)**
- `Library/Application Support/Fona/library.json`
- `Library/Application Support/Fona/Reports/` (Berichte, falls Senden scheitert)
- `Library/Logs/Fona/Fona.log` (2 × 1 MB Rotation; „Protokoll zeigen“ öffnet diesen Ort im Finder) – Ausnahme von den gemeinsamen App-Regeln (§10)
- Einstellungen in UserDefaults (beim Lesen geprüft, §3.2)

### 3.1 library.json
```json
{
  "schemaVersion": 1,
  "stations": [
    { "id": "UUID", "source": "radiobrowser", "stationuuid": "…", "name": "radioeins",
      "customName": null, "url": "https://…", "countryCode": "DE", "addedAt": "2026-11-12T10:00:00Z" },
    { "id": "UUID", "source": "custom", "stationuuid": null, "name": "Mein Sender",
      "customName": null, "url": "http://…", "countryCode": null, "addedAt": "…" }
  ],
  "favorites": ["UUID", "UUID"],
  "history": [ { "id": "UUID", "playedAt": "…" } ]
}
```
- Grenzen: Namen ≤ 120 Zeichen (nach `Sanitize.display`), URL ≤ 2048, ≤ 500 Sender, ≤ 200 Favoriten, Verlauf 10.
- Verlauf: ein erneut gehörter Sender wandert nach oben, keine Doppelten; Umbenennen ändert nur `customName`, der Verlaufseintrag bleibt.
- **URLs werden nie still aktualisiert** – auch nicht aus radio-browser (H11).
- Schreiben atomar (Temp-Datei, `replaceItemAt`). Beim Laden wie fremde Daten geprüft; Fehler oder unbekannte höhere `schemaVersion` → Datei wird zu `library.broken.json`, Start mit leerer Bibliothek, Hinweis „Deine Senderliste war beschädigt und wurde zurückgesetzt. Die alte Datei liegt als library.broken.json im Ordner von Fona.“

### 3.2 Einstellungen
| Schlüssel | Typ | Standard | Erlaubt |
|---|---|---|---|
| `newsEnabled` | Bool | true | – |
| `newsSchedule` | Enum | `hourly` | `hourly`, `hourlyAndHalf` |
| `newsMaxMinutes` | Int | 6 | 3…10 (Ende, wenn kein anderes Signal) |
| `countries` | [String] | Systemregion, sonst `["DE"]` | 0–20 Codes `[A-Z]{2}` |
| `resumeOnLaunch` | Bool | false | – |
| `launchAtLogin` | Bool | false | – |
| `autoUpdateCheck` | Bool | true | – |
| `language` | Enum | `system` | `system`, `de`, `en` |
| `lastStationID` | UUID? | nil | muss in library.json existieren |

Ungültige Werte (z. B. per `defaults write`) → Standard + Logeintrag.

### 3.3 radio-browser
- Server: DNS `all.api.radio-browser.info` → Liste, zufällige Reihenfolge, Ausweichen bei Fehler; nur https; Hosts durchlaufen N3/N4.
- Suche: `/json/stations/search?name=<q>&countrycode=<cc>&hidebroken=true&order=clickcount&reverse=true&limit=100` – eine Anfrage pro Land (≤ 20), Ergebnisse zusammengeführt, nach `clickcount` sortiert, auf 100 begrenzt. Ab 2 Zeichen, 300 ms Verzögerung.
- Länderliste: `/json/countries`, 7 Tage zwischengespeichert.
- Benutzt wird `url_resolved`, sonst `url`. Felder `homepage`, `favicon` werden nie geladen, angezeigt oder geöffnet. Keine Klick-Meldung an radio-browser.
- Ohne Netz: Hinweis „Keine Verbindung zum Senderverzeichnis“; Favoriten und Verlauf funktionieren weiter.
- **Deutschlandfunk** als Nachrichtensender und sein Tonprofil hängen an einer **im Code festen URL** (`https://st01.sslstream.dlf.de/dlf/01/128/mp3/stream.mp3`), nicht an radio-browser.

## 4 Sicherheit (höchste Priorität)

Drei Quellen gelten als feindlich: eigene Links, radio-browser-Daten, alles aus Streams. Jede Regel steht als **reine Funktion** im Prüfkatalog (`prüfe(url)`, `prüfe(adressen, anfrageklasse)`, `prüfe(weiterleitung)`, `prüfe(kopfzeilen)`, `prüfe(ersteBytes)`, …) und wird mit der Produktionskonfiguration getestet (§9).

### 4.1 NetGate
**Anfrageklassen**
| Klasse | Schema | Hosts | Inhalt | Grenze |
|---|---|---|---|---|
| `stream` | http, https | öffentlich | Audio | Dauerstrom |
| `playlist` | http, https | öffentlich | .pls/.m3u/.m3u8 | 64 KB (HLS-Media-Playlist 2 MB) |
| `segment` | http, https | öffentlich, ≤ 4 Hosts pro Stream | TS/Packed Audio | 4 MB |
| `directory` | https | radio-browser-Server | JSON | 2 MB |
| `update` | https | `api.github.com`, `github.com`, `objects.githubusercontent.com`, `release-assets.githubusercontent.com` | JSON, ZIP, .sig | 50 MB |
| `report` | https | Worker-Host | POST JSON | 256 KB |

| # | Regel |
|---|---|
| N1 | Schema laut Klasse; alles andere (`file`, `data`, `javascript`, `ftp`, eigene) abgelehnt. |
| N2 | Keine Zugangsdaten in der URL; URL ≤ 2048 Zeichen; die Anfrage wird aus den geprüften Teilen neu gebaut. |
| N3 | Namensregeln: abgelehnt `localhost`, `*.local`, `*.home.arpa`, `*.internal`, Einzelwort-Hosts, abschließender Punkt. |
| N4 | **Adressprüfung:** NetGate löst selbst auf (`getaddrinfo`), prüft **jede** Adresse binär gegen die IANA-Sonderbereiche (IPv4: 0/8, 10/8, 100.64/10, 127/8, 169.254/16, 172.16/12, 192.0.0/24, 192.0.2/24, 192.168/16, 198.18/15, 198.51.100/24, 203.0.113/24, 224/4, 240/4, 255.255.255.255; IPv6 nur 2000::/3 erlaubt, abzüglich 2001::/32 Teredo, 2001:db8::/32, 2002::/16 6to4, 64:ff9b::/96 und 64:ff9b:1::/48; eingebettetes IPv4 wird herausgelöst und geprüft). Ist eine Adresse verboten → abgelehnt. Verbunden wird **genau zu einer geprüften Adresse**; im Zustand `.ready` wird `remoteEndpoint` vor dem ersten Byte erneut geprüft. Bei TLS wird der Servername gesetzt und das Zertifikat normal gegen den Hostnamen geprüft. |
| N5 | Weiterleitungen: höchstens 5, jede durchläuft N1–N4; https → http nur in den Klassen `stream`/`segment`/`playlist`; besuchte URLs werden gemerkt (Schleifen). |
| N6 | Grenzen: Verbindungsaufbau 10 s; Kopfzeilen vollständig in 15 s und ≤ 16 KB; `Accept-Encoding: identity`, jedes andere `Content-Encoding` abgelehnt; Chunked-Transfer selbst gelesen; nach dem Start Mindestdurchsatz ≥ 25 % der Nennbitrate über 30 s, sonst Abbruch; Größen laut Klassentabelle; nur gestreamt, nie ganzer Body im Speicher. |
| N7 | Inhaltstyp ist **Sperrliste** (HTML, Bilder, Archive, Programme, `application/ogg`, Video außer `video/mp2t`) und dient sonst nur der Weiterleitung (Playlist/HLS/Audio) und der Fehlermeldung. |
| N8 | Byte-Prüfung: in den ersten 16 KB (ohne ICY-Metadaten, nach übersprungenem ID3-Tag ≤ 64 KB) Sync suchen und **3 aufeinanderfolgende gültige Frames** mit passenden Längen verlangen (MP3, ADTS) bzw. TS-Sync `0x47` an 5 aufeinanderfolgenden 188-Byte-Grenzen, `#EXTM3U`, `[playlist]`. |
| N9 | Keine Cookies, kein Cache, keine Authentifizierung, `User-Agent: Fona/<Version>`, für Streams `Icy-MetaData: 1`. |
| N10 | ATS spielt für `NWConnection` keine Rolle; NetGate setzt alle http-Regeln selbst durch. Kein `NSLocalNetworkUsageDescription` – der macOS-15-Schutz „Lokales Netzwerk“ ist nur ein **Zusatz** (er fragt den Nutzer, statt still zu sperren); N3/N4 müssen allein reichen. |
| N11 | Keine Proxys. Handbuch: „Fona funktioniert nicht hinter Pflicht-Proxys oder mit Fake-IP-Werkzeugen.“ |
| N12 | Streuung begrenzt: aus Playlists höchstens 3 Einträge probieren; ≤ 4 Segment-Hosts pro HLS-Stream. |

### 4.2 Inhalte
| # | Regel |
|---|---|
| S1 | Playlists (.pls/.m3u): Text, ≤ 100 Einträge gelesen, ≤ 3 probiert, eine Ebene tief; jede URL durch NetGate. |
| S2 | HLS: Master → eine Ebene Media-Playlist; ≤ 8 Varianten (gewählt: niedrigste ≥ 96 kbit/s, sonst höchste); Start 3 Segmente vor der Live-Kante; ≤ 3 Segmente voraus; Neuladen zwischen 1 s und `TARGETDURATION` (≤ 30 s); ≤ 10 000 Segmente pro Playlist (1LIVE hält 4575 = 5 h); nur die letzten 6 Segmente werden ausgewertet; gibt der Server `EXT-X-SERVER-CONTROL:CAN-SKIP-UNTIL` an, wird ab dem zweiten Abruf mit `_HLS_skip=YES` nur die verkürzte Liste geladen (`#EXT-X-SKIP`); abgelehnt: `#EXT-X-KEY`/`#EXT-X-SESSION-KEY` ≠ NONE, `SAMPLE-AES`, `#EXT-X-MAP`, `EXT-X-BYTERANGE` > 4 MB. HTTP 404 auf Segment → nächstes; Live-Kante verloren → neu an der Kante einsteigen. |
| S3 | ICY: Anfrage mit `Icy-MetaData: 1`; `icy-metaint` 1…65 536; Metadatenblock ≤ 4080 Byte; Titel = `StreamTitle='` bis zum nächsten `';` oder Blockende; `StreamUrl` und Rest ignoriert. |
| S4 | **`Sanitize.display(_:)`** für jeden fremden Text (Titel, `icy-name`/`icy-description`, `#EXTINF`, `Title1=`, alle radio-browser-Felder, Fehlertexte): UTF-8 sonst Latin-1 → NFC → nur Unicode-Kategorien L, M (≤ 2 pro Grundzeichen), N, P, S und Leerzeichen → Leerraum zusammenfassen → ≤ 200 Grapheme, ≤ 800 Byte. Anzeige mit `Text(verbatim:)`. Fremder Text ist **nie** Formatstring, Lokalisierungsschlüssel oder Markdown (Quelltext-Test). |
| S5 | FrameGuard vor Apples Decodern: ADTS nur AAC-LC/HE, `channel_config` 1–2, Abtastrate aus fester Liste, `frame_length` 7…8192; MP3 nur Layer III, gültige Bitraten-/Abtastraten-Indizes, ≤ 2 Kanäle; ID3 ≤ 64 KB; TS: jede Länge gegen den Puffer, unbekannte Typen übersprungen; jeder Parser-Durchlauf muss Fortschritt machen; PCM-Warteschlange ≤ 5 s. Fehler → Stream beenden, nie abstürzen. Alles gefuzzt. |
| S6 | radio-browser: jeder Eintrag geprüft (S4 für Texte, N1–N3 für URLs schon beim Anzeigen, `countrycode` nur `[A-Z]{2}`); ungültige Einträge ausgeblendet. |
| S7 | Eigene Links: vor dem Speichern volle Probe (NetGate + N8 + 2 s Dekodierung). Später durchlaufen sie wie jede URL NetGate + N8. |

### 4.3 App und System
| # | Regel |
|---|---|
| A1 | Fona: Sandbox mit nur `network.client`; FonaDecoder: Sandbox ohne Berechtigung; alle drei mit Hardened Runtime, ohne `allow-dyld-environment-variables` und `disable-library-validation`. |
| A2 | Kein URL-Schema, keine Dokumenttypen, keine Dienste. |
| A3 | `library.json` und Einstellungen beim Laden geprüft (§3.1, §3.2). |
| A4 | Updater siehe §7: Prüfung im Hilfsprogramm ist maßgeblich, keine Argumente, kein Downgrade. |
| A5 | Berichte und Log enthalten **keine** URLs, Sendernamen oder Titel – nur Anfrageklasse, Schema, Fehlerklasse, Inhaltstyp, Hostkategorie (öffentlich/abgelehnt). Wo eine Wiedererkennung nötig ist: HMAC mit Schlüssel pro Installation. Benutzername und Pfade werden vor dem Senden entfernt (Test). |
| A6 | Quelltext-Test: außerhalb von NetGate verboten `URLSession`, `NWConnection`, `CFStream`, `getaddrinfo`, `Data(contentsOf:)`, `String(contentsOf:)`, `NSImage(contentsOf:)`, `AsyncImage`, `AVPlayer`, `AVURLAsset`, `WKWebView`, `engine.inputNode`; NetGate kennt keine Ausnahme- oder Testmodi. |

## 5 Fehler und Wiederaufnahme
| Ereignis | Verhalten | Meldung (Beispiel de) |
|---|---|---|
| Verbindung bricht ab | Wiederverbinden nach 1, 2, 5, 10, 10 s; danach aufgeben | „Verbindung zu radioeins verloren. Erneut versuchen?“ |
| Netzwechsel (`NWPathMonitor`) | sofort neu verbinden | – |
| Ruhezustand | beim Einschlafen beenden, nach dem Aufwachen nicht automatisch starten | – |
| Ausgabegerät wechselt (`AVAudioEngineConfigurationChange`) | Engine neu aufbauen, weiterspielen | – |
| FonaDecoder stürzt ab | Dienst neu starten, einmal neu verbinden | „Stream abgebrochen.“ |
| Ablehnung durch NetGate/S-Regeln | nicht wiederholen | Klartext je Fehlerklasse, z. B. „Dieser Link liefert keinen Ton, sondern eine Webseite.“, „Sender im Heimnetz sind aus Sicherheitsgründen gesperrt.“ |

Der vollständige Fehlerkatalog (jede Ablehnungsklasse → Text de/en) entsteht in P1 als Tabelle im Code; ein Test prüft, dass jede Klasse einen Text hat.

## 6 Nachrichten-Umschaltung

### 6.1 Messung (2026-11-11, Mitschnitt 11:02–12:08)
- 11:00: nur Titel belegt (Mitschnitt beginnt 11:02 mitten in den Nachrichten); Ende-Titelwechsel 11:05:06.
- 11:30: Titel wechselt 11:30:04 auf „Nachrichten, Deutschlandfunk-Nachrichtenredaktion“, im Ton ≈ 0,7 s nach Beginn der Sprache. Ende-Titelwechsel 11:35:05, ≈ 4,5 s nach Ende von Nachrichten + Wetter.
- 12:00: **kein** Titelwechsel.
- 11:30 und 12:00: vor der Sprache ein Ton um 780 Hz (stärkster Bin bei Goertzel-Suche 100–2000 Hz in 10-Hz-Schritten, 8 kHz Mono, 0,5-s-Fenster), ≈ 0,6 s, danach ≈ 2,4 s Stille.
- Der Titel wechselt alle 15–20 s zwischen zwei Formen (z. B. „Nachrichten“ / „Nachrichten, Deutschlandfunk-Nachrichtenredaktion“) – das Ende ist also mit bis zu 20 s Verzögerung erkennbar.
- Rohdaten: `design/research/` (nie ins Repo).

### 6.2 NewsProfile (Konstante im Code, Werte kalibriert in P0-b)
```
host: st01.sslstream.dlf.de · tone: 760–800 Hz (Hann-Fenster, stärkster Bin)
window: 100 ms, 50 % Überlappung · toneRatio ≥ 0,5 (Bandenergie / Gesamtenergie, Mono-Downmix)
toneMinDuration: 0,45 s · silenceAfter: ≥ 1 s unter −40 dBFS innerhalb 4 s
titleRule: ^Nachrichten\b (ohne Groß/Klein) · scheduleWindow: ±90 s um :00 (und :30)
```

### 6.3 Erkennung
- **Start** durch (a) **Ton** innerhalb des Zeitplanfensters, oder (b) **Titel** passend zu `^Nachrichten\b` innerhalb des Zeitplanfensters. Der Zeitplan löst **nie allein** aus (ob doch, entscheidet P0-b).
- **Ende** durch (a) Titel, der nicht mehr passt, wenn in dieser Episode ein passender Titel gesehen wurde – sonst erst der erste Titel, der auch nicht reiner Sendername („Deutschlandfunk…“) ist (P0-b: 09:00/00:00); (b) sonst `newsMaxMinutes` (Standard 10 min – Ausgaben dauern 5–10 min); (c) „Jetzt zurück“; (d) Höchstdauer 12 min.
- **Wiedergabe:** Der Nachrichten-Ringpuffer (15 s PCM) liefert ab dem Tonbeginn bzw. 4 s vor dem Titelwechsel (Wert aus P0-b); 80-ms-Überblendung; zurück wird live aus dem Programm-Ringpuffer übergeblendet.

### 6.4 Zustandsautomat
| Zustand | Ereignis | Aktion | Folgezustand |
|---|---|---|---|
| `aus` | Umschaltung an + Programm läuft | Nachrichtenkette starten | `bereit` |
| `bereit` | Start-Signal (6.3) | Überblenden zu Nachrichten | `nachrichten` |
| `bereit` | Programm = Deutschlandfunk | Nachrichtenkette stoppen | `aus` |
| `bereit`/`nachrichten` | Pause | Wiedergabe stoppen, Nachrichtenkette stoppen | `aus` |
| `nachrichten` | Ende-Signal (6.3) | Überblenden zurück | `sperre` |
| `nachrichten` | Nutzer wählt anderen Sender | neuen Sender starten, nach Nachrichtenende auf ihn | `nachrichten` |
| `nachrichten` | Nutzer wählt Deutschlandfunk | Nachrichten werden Programm | `aus` |
| `nachrichten` | Nachrichtenstream fällt aus | sofort zurück | `sperre` |
| `nachrichten` | Programmstream fällt aus | Nachrichten zu Ende spielen, dann Wiederverbinden (§5) | `nachrichten` |
| `sperre` | 10 min vergangen | – | `bereit` |
| beliebig | Umschaltung aus | ggf. zurück, Kette stoppen | `aus` |
| `bereit` beim Start | Titel passt schon | **nicht** auslösen (Mitte der Sendung) | `bereit` |

Jede Zeile hat einen Test mit simulierter Uhr und simulierten Signalen.

## 7 Updater
- Fona sucht Releases (`repos/moritz-poth/Fona/releases`) und lädt `Fona-<version>.zip` + `.sig` über NetGate (`update`), in den eigenen Container unter **festem Namen** `Updates/pending.zip`.
- **FonaUpdater** (`Contents/Helpers/FonaUpdater.app`, über `NSWorkspace.openApplication` gestartet) ist die Vertrauensgrenze:
  1. ignoriert Umgebungsvariablen und Argumente; Ziel ergibt sich aus `Bundle.main` (umschließendes `Fona.app`);
  2. liest `pending.zip` einmal in den Speicher (Symlinks abgewiesen), prüft die Ed25519-Signatur auf genau diesen Bytes;
  3. schreibt in einen eigenen `mkdtemp`-Ordner, packt mit `ditto -x -k` aus;
  4. prüft: genau ein `Fona.app`, keine Symlinks nach außen, Bundle-ID, `FonaRelease` == Tag, Version **strikt neuer**, `codesign --verify --deep --strict`, Signaturzertifikat gleich dem der laufenden App;
  5. wartet, bis Fona beendet ist; alte App in den Papierkorb, neue an ihren Platz; Quarantäne entfernen; Fona starten.
- Schlüssel: eigenes Paar, Schlüsselbund-Eintrag „Fona update key“ (`WhenUnlockedThisDeviceOnly`), Offline-Sicherung; nicht Mountpoints Schlüssel. Testversionen, `.manual`-Marker und Ablauf bei Schlüsselverlust wie Mountpoint `Updater.swift`.
- Signierreihenfolge im Build: FonaDecoder.xpc, dann FonaUpdater.app, dann Fona.app – jeweils mit eigenen Entitlements, **nie** `--deep`.
- Fallback: Hinweis mit Download im Browser.

## 8 Oberfläche
Entsprechend `design/canvas/`. Regeln:
- Nichts öffnet sich von selbst; Hinweise im Popover als Karten.
- Zeile klicken = spielen; Rechtsklick: zu Favoriten / entfernen / umbenennen; Favoriten per Ziehen sortierbar.
- „+“: Dialog „Sender hinzufügen“ mit Probe (S7) und Ergebnis in Klartext.
- Leere Zustände: keine Favoriten („Füge Sender über ‚Alle Sender‘ hinzu“), keine Treffer, kein Netz.
- Barrierefreiheit: Kontrast ≥ 4,5 : 1, VoiceOver-Beschriftungen, Schalter melden An/Aus, Tastaturbedienung, Zustand nie nur über Farbe.
- Lokalisierung: String Catalog, `defaultLocalization: "en"`, Sprache laut `language`-Einstellung.

## 9 Tests

**Ein Prüfkatalog, zwei Aufrufer** (Muster Mountpoint `SelfTest.swift` / `SelfTestTests.swift`): Jede Prüfung steht einmal als Funktion im App-Ziel. `swift test` ruft den ganzen Katalog auf; der Selbsttest in der App ebenfalls.

### 9.1 Prüfkatalog (läuft in `swift test` und im Selbsttest)
1. **Angriffe (zuerst; eine Fehlannahme = rot):** alle N-/S-Regeln als reine Funktionen mit Produktionskonfiguration, u. a. `file:///etc/passwd`, `javascript:`, `data:`, `127.1`, `0177.0.0.1`, `0x7f000001`, `127.0.0.1.`, `%31%32%37.0.0.1`, Vollbreitenziffern, `[::1]`, `[::127.0.0.1]`, `[::ffff:192.168.1.1]`, `[64:ff9b::c0a8:101]`, `[2002:c0a8:101::]`, `router.local`, `localhost.`, Weiterleitung auf `file:`/Heimnetz, Schleife, 6 Weiterleitungen, https→http für `directory`, HTML als `audio/mpeg`, Programm als `.mp3`, gzip-Antwort, 10-MB-Playlist, Playlist mit `file:`, überlange Kopfzeile, `icy-metaint` 0 und 10⁹, Titel mit Bidi/Nullbreite/Tag-Zeichen/Markdown-Link, Link mit Zugangsdaten, HLS mit `#EXT-X-KEY`, `#EXT-X-MAP`, `SAMPLE-AES`, Segment im Heimnetz, `TARGETDURATION` 0.
2. Abspielkette aus dem Speicher (abstrakte Bytequelle, **kein Server, kein Netz**): mitgelieferte, selbst erzeugte Testdateien MP3, AAC-LC, HE-AAC, HLS-TS, Packed Audio → PCM kommt an, Titel aus ICY-Testdatei korrekt bereinigt.
3. Nachrichten: Ton-Testdatei löst aus, Musik-Testdatei nicht; jede Zeile aus §6.4 mit simulierter Uhr.
4. Überblendung: größter Sprung zwischen zwei Samples an der Schnittstelle ≤ 0,05 (Vollaussteuerung 1,0) bei zwei Sinus-Testsignalen.
5. Eigener Link: Probe-Logik mit Testdateien (gültig, Webseite, kein Ton).
6. Library: Testspeicher – hinzufügen, sortieren, umbenennen, entfernen, neu laden, defekte Datei, unbekannte Version.
7. Einstellungen: ungültige Werte → Standard.

### 9.2 Nur im Selbsttest (braucht Netz; ohne Netz = „übersprungen“, nicht rot)
8. radio-browser erreichbar, Suche liefert Ergebnisse, Länderfilter greift.
9. Deutschlandfunk-Stream: Verbindung über NetGate, 3 gültige Frames, Titel kommt (Information).

Ergebnis als Toast; Bericht (A5) über NetGate (`report`) an den bestehenden Worker (Eintrag `"fona": "moritz-poth/fona-reports"`, eigener feingranularer Token). Scheitert das Senden: Ablage in `Application Support/Fona/Reports/` und „Im Finder zeigen“. Worker-Härtung in P6: IPs mit Geheimnis hashen, Felder escapen, Tag-Zeichen entfernen.

### 9.3 Nur in `swift test`
- Fuzzing: IcyReader, Playlist-Parser, HLS-Parser, TsDemuxer, FrameGuard (zufällig + mutiert, ≥ 1 Mio. Eingaben je Parser in CI-Lauf; keine Abstürze, keine Hänger > 100 ms).
- Quelltext-Tests (A6, S4).
- Lokalisierung: jeder Text in de und en, jede Fehlerklasse mit Text.
- NewsWatcher auf den P0-b-Mitschnitten (falls lokal vorhanden, sonst übersprungen): 100 % Treffer, 0 Fehlalarme.

## 10 Design-Referenz und Abweichungen
- Ansichten: `design/canvas/` (Export aus dem Design-Canvas, vor P4): Favoriten, Nachrichten laufen, Alle Sender, Sender hinzufügen, Einstellungen, Dunkel; dazu leere Zustände, Fehlerkarte, Menüleisten-Symbol.
- Export liegt in `design/canvas/project/*.dc.html` (Quelltext der Entwürfe, 2026-11-12). Beim Umsetzen in P4 angleichen: „Tuner“ → „Fona“; in den Einstellungen wird „Nachrichtensender“ ein fester Text („Deutschlandfunk“), das Menü „Erkennung“ entfällt, „Dauer“ heißt „Höchstdauer, falls kein Ende erkannt wird“ (3–10 min, Standard 10).
- Icon: `design/icon/`.
- Bewusste Abweichungen von `~/.claude/skills/moe-apps/SKILL.md`: eigener Look (Systemschrift, Pastell, hell/dunkel nach System); Einstellungen als ein gruppiertes Fenster; zwei Sprachen; Log und Berichtsablage im Sandbox-Container; Signatur ggf. mit eigenem Zertifikat. Übernommen: Updater-Ablauf, Ed25519, Support, Handbuch, About, Release-Ablauf, Datensicherheit.

## 11 Phasen

| Phase | Inhalt | Fertig, wenn |
|---|---|---|
| **P0-a** Update & Sandbox | v1 bauen (ad-hoc), Favoriten anlegen, über FonaUpdater auf neu gebautes v2 aktualisieren – macOS 14 **und** 15 | Ja/Nein: bleibt der Container-Zugriff ohne Abfrage? Nein → eigenes Zertifikat einrichten, Test wiederholen |
| **P0-b** Nachrichten-Messung | 24-h-Mitschnitt DLF (Werktag) + 24 h Wochenende; Abschrift der Ausgaben | Ja/Nein: Ton vor jeder Ausgabe? Fehlalarme? Werte für NewsProfile und Dauertabelle eingetragen |
| **P0-c** HLS | 1LIVE über eigenen Leser (Prototyp) dekodieren | Ja/Nein: TS-Demux + ADTS → PCM läuft 30 min ohne Aussetzer |
| **P0-d** Lokales Netzwerk | Verhalten der macOS-15-Abfrage ohne Usage-Description | Verhalten dokumentiert |
| **P0-e** Icon | Icon-Composer-Icon (`.icon`) mit `actool` im SwiftPM-Build | Ja/Nein: Icon erscheint auf 14 (flach) und 26 (Liquid Glass) |
| **P0-f** NetGate-Transport | `NWConnection`-Client: http-Icecast, https, Shoutcast v1, Chunked, Weiterleitung | Ja/Nein: alle vier Arten liefern Bytes; Mindestversion macOS entschieden |
| **P0-g** XPC-Decoder | FonaDecoder als XPC ohne Rechte, PCM zurück | Ja/Nein: Latenz < 50 ms pro Paket, Neustart nach Absturz klappt |
| **P1 NetGate** | §4.1 vollständig + Prüfkatalog Angriffe + Fehlerkatalog | Prüfkatalog Punkt 1 grün |
| **P2 ICY** | SourceResolver, IcyReader, FonaDecoder, Player | radioeins, Deutschlandfunk, SWR3, 1LIVE (MP3), FluxFM je 30 min ohne Aussetzer; Fuzz grün |
| **P3 HLS** | HlsReader, TsDemuxer | 1LIVE HLS und 1 Packed-Audio-Sender je 30 min; HLS-Angriffe grün |
| **P4 Oberfläche** | Popover, Library, Directory, Dialog, Einstellungen, de/en | alle Ansichten aus `design/canvas/`; Checklisten VoiceOver, Tastatur, Kontrast abgehakt |
| **P5 Nachrichten** | NewsWatcher | 100 % Treffer, 0 Fehlalarme auf P0-b-Mitschnitten + 2 h live mit 2 Ausgaben |
| **P6 Support** | Selbsttest, Reporter, Worker-Eintrag + Härtung, Log | Selbsttest grün, Bericht im Repo `fona-reports` |
| **P7 Release** | Updater, Handbuch de/en, README, About, Icon | Prerelease über eigenen Updater installiert und vom Nutzer geprüft |

**Dateien (Überblick):** `Package.swift` (Targets `Fona`, `FonaDecoder`, `FonaUpdater`, `FonaCore` für den Prüfkatalog, Tests), `Sources/Fona/{App,UI,Library,Directory,NetGate,Stream,Player,News,Support,Updater}/`, `Sources/FonaDecoder/`, `Sources/FonaUpdater/`, `Resources/{Localizable.xcstrings,TestMedia/,help/de.md,help/en.md}`, `Entitlements/{Fona,FonaDecoder,FonaUpdater}.entitlements`, `scripts/{build-app.sh,update-key.swift,make-test-media.swift}`.

## 12 Repo und Daten
- Repo `moritz-poth/Fona` (öffentlich erst nach Freigabe), GPL-3.0-or-later.
- `design/research/` (Mitschnitte Deutschlandfunk) ist urheberrechtlich geschützt → `.gitignore`. Testmedien werden von `scripts/make-test-media.swift` selbst erzeugt (Sinus, Rauschen, synthetischer 780-Hz-Ton, Stille).
- Report-Repo `moritz-poth/fona-reports` (privat) – Anlage in P6.

## 13 Risiken
| Risiko | Folge | Gegenmaßnahme |
|---|---|---|
| Container-Zugriff nach Update (ad-hoc) | Abfragen oder verlorene Favoriten | P0-a; eigenes Zertifikat |
| Ton nicht bei allen Ausgaben | verpasste Nachrichten | Titel als zweite Stufe; P0-b |
| Deutschlandfunk ändert Ton/Titel/URL | Erkennung fällt aus | NewsProfile per Update; Selbsttest Punkt 9 zeigt es |
| Eigener HTTP-Client hat Lücken | Fehlfunktion/Angriffsfläche | wenig Code, Fuzzing, Prüfkatalog |
| Decoder-Lücke bei Apple | Codeausführung | FonaDecoder ohne Rechte (A1) |
| Proxy-/Fake-IP-Umgebung | Fona spielt nicht | im Handbuch genannt (N11) |
| Datenverbrauch zweier Streams | ≈ 115 MB/h, ≈ 2,7 GB/Tag | Handbuch; Umschaltung abschaltbar |

## 14 P0-Ergebnisse

### P0-a Update & Sandbox – 2026-11-12, macOS 15.5 (arm64) · Ergebnis: **Ja** (auf 15)
Spike: `spikes/p0a/` (sandboxed App + nicht sandboxed Hilfsprogramm in `Contents/Helpers`, ad-hoc, von innen nach außen signiert).
- Sandboxed App startet `Contents/Helpers/FonaSpikeUpdater.app` per `NSWorkspace.openApplication` – klappt.
- Hilfsprogramm liest `pending.zip` aus dem Container der App (`~/Library/Containers/<id>/Data/Library/Updates/`) ohne Fehler; im Log keine Blockade (Dialog-Beobachtung durch den Nutzer: offen).
- Download aus der Sandbox trägt Quarantäne (`quarantine=true`); nach `ditto` + `xattr -dr com.apple.quarantine` startet die neue Version ohne Gatekeeper-Stopp.
- **Container-Zugriff bleibt erhalten:** v2 (anderer CDHash) liest Daten von v1, v3 liest Daten von v2. Automatischer Durchlauf v2 → v3 in 1,2 s.
- Lehre: Die App muss sich nach dem Start des Hilfsprogramms **sofort** beenden (nicht auf dessen Rückmeldung warten); das Hilfsprogramm bricht ab, wenn die App nach 10 s noch läuft.
- macOS 14: nicht getestet – keine Testumgebung, Nutzer hat den Test am 2026-11-13 gestrichen. Restrisiko: Container-Abfrage nach Update auf 14 unbekannt.
- Rest: ein leerer Container-Ordner `io.github.moritz-poth.fona.spike` bleibt (macOS schützt ihn vor dem Löschen per Terminal; im Finder löschbar).

### P0-b Nachrichten-Messung – Werktag ausgewertet 2026-11-13 · Ergebnis: **Ja**; Wochenende offen
24,5-h-Mitschnitt 2026-11-12 00:20 – 2026-11-13 00:50 (`scripts/record-dlf.py` → `design/research/24h/`, stündliche Dateien + `titles.log`), geprüft mit `fona-tonescan` (Stundengrenzen als zusammengefügte 60-s-Stücke, weil das Zeitzeichen um :59:58 über zwei Dateien läuft).
- **Zeitzeichen: 38 von 38 Ausgaben, 0 Fehlalarme** – alle 24 vollen Stunden (01:00 … 00:00) und alle 14 halben (04:30 … 17:30). Langer Piep 0,75–0,80 s, Beginn ≈ 2 s vor der Stunde.
- Zeitplan: volle Stunde rund um die Uhr, halbe Stunde nur 04:30–17:30 (nicht 00:30–03:30 und 18:30–23:30).
- **Titel fehlt bei 2 von 24 vollen Stunden (09:00, 00:00)** – dort nur „Deutschlandfunk“ / „Deutschlandfunk - Alles von Relevanz“, erster Sendungstitel nach ≈ 5:15 min. Mit der Höchstdauer 10 min liefe dann ≈ 5 min DLF-Programm statt des eigenen Senders → Ende-Regel offen (siehe unten).
- Titel erscheint 1–7 s nach der Stunde; Dauer (Titel an → aus): halbe Stunde 4:19–5:10, volle Stunde 4:59–5:05 oder 9:48–10:07 (06, 08, 10, 12, 13, 14, 16, 18, 20, 23 Uhr). Längste Ausgabe ab Zeitzeichen ≈ 10:12.
- Titelregel `^Nachrichten\b` hält: „Nachrichtendienstreform: …“ (15:36, @mediasres) passt nicht; liegt zudem außerhalb des Zeitfensters.
- Reconnects des Rekorders nur um xx:20 (Stream bricht alle 6 h ab), keine Lücke an einer Nachrichtenausgabe.
- **Ende ohne Nachrichten-Titel (umgesetzt 2026-11-13):** Episode endet beim ersten Titel, der weder `^Nachrichten\b` noch reiner Sendername („Deutschlandfunk…“) ist; Höchstdauer bleibt als Rückfall. Auf den Werktags-Titeln nachgespielt: endet um 09:00 und 00:00 nach ≈ 5:16 min, bei keiner anderen Ausgabe zu früh.
- Wochenend-Mitschnitt läuft seit 2026-11-13 16:35 bis 2026-11-16 00:20 → `design/research/weekend/`.

### P0-c HLS – 2026-11-12 · Ergebnis: **Ja** (Dekodierung); Dauertest → P3
Spike: `spikes/p0c/main.swift` (eigener TS-Demuxer PAT/PMT/PES → ADTS → `AudioFileStream` + `AVAudioConverter`).
- 1LIVE: Master mit 96/192 kbit/s AAC-LC 48 kHz Stereo, Segmente 3,99 s MPEG-TS, Audio-PID 101, Streamtyp 0x0F.
- 3 Segmente → 11,97 s PCM, **sample-genau identisch mit ffmpeg** (größte Abweichung 0,0), keine Demux-Fehler.
- Fund: Die Media-Playlist ist **425 KB mit 4575 Segmenten** (5-h-Zeitfenster) und `CAN-SKIP-UNTIL=24` → Grenzen in N-Tabelle und S2 angepasst (2 MB, 10 000 Segmente, Delta-Abruf).
- Der 30-Minuten-Dauertest braucht den Lese-Kreislauf und wandert nach P3.

### P0-f NetGate-Transport – 2026-11-12 · Ergebnis: **Ja**
Spike: `spikes/p0f/main.swift` (HTTP/1.1 auf `NWConnection`, eigene Auflösung, Verbindung zur geprüften IP, TLS-Servername + Hostnamen-Prüfung per `SecPolicyCreateSSL`, Gegenstelle vor dem ersten Byte geprüft, `preferNoProxies`).
- Spielen/liefern Bytes: Deutschlandfunk (https + 302 auf anderen Host), FFH, NDR Info, Sunshine Live (http-Icecast), zwei Shoutcast-v1-Server (`ICY 200 OK`), 1LIVE-HLS-Master, radio-browser- und GitHub-API, Chunked-Antwort.
- Abgewiesen: `localhost`, `127.1`, `0x7f000001`, `[::1]`, `192.168.1.1`, `file:`, 6 Weiterleitungen, falscher Hostname und selbstsigniertes Zertifikat (TLS −9808), gzip-Antwort.
- Erkenntnisse für P1: (1) Ein Server (Sunshine Live) trennt Kopfzeilen teils nur mit `\n` → Parser muss `\r\n` **und** `\n` akzeptieren. (2) `Transfer-Encoding: identity` kommt vor. (3) Zufallsdaten enthielten ein „MP3-Sync“ bei Byte 5094 → bestätigt N8: 3 aufeinanderfolgende gültige Frames verlangen. (4) Die Weiterleitung auf `127.0.0.1` konnte mangels Testserver nicht live geprüft werden (httpbin antwortet 403) → Unit-Test mit simulierter Antwort in P1.
- Mindestversion: alle benutzten APIs gibt es ab macOS 10.14 → **macOS 14 bleibt Ziel**.

### P0-g XPC-Decoder – 2026-11-12 · Ergebnis: **Ja**
Spike: `spikes/p0g/` (sandboxed Host + `Contents/XPCServices/FonaDecoder.xpc` mit Sandbox ohne jede Berechtigung, `NSXPCConnection`, ADTS → PCM Float32 48 kHz).
- 3 Segmente 1LIVE (287 KB ADTS) in 18 Aufrufen à 16 KB → 11,97 s PCM, vollständig.
- Dauer pro Aufruf: Mittel 3,8–8,4 ms; der erste Aufruf nach (Neu-)Start des Dienstes 54–136 ms (Prozessstart + Converter). Bei mehreren Sekunden Puffer unkritisch → Kriterium „Mittel < 10 ms“ statt „jeder < 50 ms“.
- Rechte im Dienst geprüft: Dateien **gesperrt**, Netzwerk **gesperrt** (`connect` → errno 1).
- Absturz (`abort()`) → `interruptionHandler` in der App; der nächste Aufruf über dieselbe Verbindung startet den Dienst neu (≈ 300 ms), danach wieder vollständige Dekodierung.

### P0-d Lokales Netzwerk – entfällt
NetGate verbindet nie zu Heimnetz-Adressen (P0-f: Abweisung **vor** jedem Verbindungsversuch), deshalb kann die macOS-15-Abfrage „Lokales Netzwerk“ durch Fona gar nicht ausgelöst werden. Die Abfrage, die der Nutzer am 2026-11-12 sah („Python … Netzwerk“), kam vom Python-Testserver aus P0-a (eingehende Verbindungen), nicht von Fona.

### P0-e Icon – blockiert
Auf diesem Mac sind nur die Command Line Tools installiert, **kein Xcode**. Icon Composer und `actool` (für das Liquid-Glass-Icon) brauchen Xcode 26, das wiederum mindestens macOS 15.6 verlangt (installiert: 15.5). Bis dahin: `.icns` aus den Ebenen-SVGs wie bei Mountpoint (`iconutil`).

## 15 Stand der Phasen

### P1 NetGate – 2026-11-12 · **fertig**
- `Sources/FonaCore/NetGate/`: Anfrageklassen + Grenzen, URL-Prüfung (N1–N3, neu gebaute Anfrage), binäre Adressprüfung (N4, IPv6 nur 2000::/3), eigene Auflösung mit austauschbarem `Resolver`, HTTP/1.1 auf `NWConnection` (TLS-Servername + Hostnamen-Prüfung, Gegenstelle vor dem ersten Byte geprüft, keine Proxys), Weiterleitungen (N5), Kopfzeilen-Parser (CRLF/LF, `ICY 200 OK`, Doppel-`Content-Length` abgewiesen), Inhaltstyp-Sperrliste (N7), Byte-Prüfung mit 3 Frames (N8), Chunked- und ICY-Zerleger, Mindestdurchsatz, Fehlerkatalog de/en.
- `Sources/FonaCore/Checks/CheckCatalog.swift`: ~100 Prüfungen (Angriffe + echte Formen), läuft in `swift test` und später im Selbsttest; Gegenprobe: Entfernen von 192.168/16 aus der Sperrliste lässt 3 Prüfungen scheitern.
- Fuzzing (1 Mio. Eingaben je Parser) fand **einen echten Absturz**: Chunk-Größe „-5“ wurde von `Int(_:radix:)` angenommen → behoben, Fall im Katalog; dieselbe Schwäche bei `Content-Length`/`icy-metaint` vorsorglich behoben.
- Live geprüft (`fona-probe`, `FONA_LIVE=1`): Deutschlandfunk, FFH, Sunshine Live, zwei Shoutcast-v1-Server, 1LIVE-HLS-Master, radio-browser, GitHub-API; abgewiesen: falsches Zertifikat, gzip, Webseite, localhost, `127.1`, `file:`, 6 Weiterleitungen.
- Noch nicht drin (folgt mit P2): `Sanitize.display`, Mindestdurchsatz live erprobt, `Limits.reportHost` wird in P6 auf den Fona-Eintrag des Workers gesetzt.

### P2 ICY-Wiedergabe – 2026-11-12 · in Arbeit
- Neu in `FonaCore`: `Sanitize.display` (S4), `PlaylistParser` (S1), `StreamSource` (Playlist → Format per Bytes → ICY-Zerleger → `FrameGuard` → Titel bereinigt), `FrameGuard` (S5, Frame erst frei, wenn der nächste Kopf gültig ist), `DecoderCore` (AudioFileStream + AVAudioConverter, HE-AAC über FormatList, Mono → beide Kanäle), `Player` (ein `AVAudioSourceNode`, zwei Ringpuffer, 80-ms-Gleichleistungsblende).
- `FonaDecoder.xpc` (Sandbox ohne Rechte, prüft Frames ein zweites Mal) + `DecoderClient` (startet den Dienst nach Absturz neu, ein Wiederholversuch); erste App-Hülle `Fona.app` (`scripts/build-app.sh`, Sandbox, ad-hoc, von innen nach außen signiert). Die echte Oberfläche folgt in P4.
- Geprüft: Dekodierung gegen ffmpeg – AAC bitgenau, MP3 größte Abweichung 0,00002 (≈ −94 dB). Sandbox-App spielt Deutschlandfunk über NetGate + XPC-Decoder; 3 gewaltsame Abstürze des Decoders hintereinander → Wiedergabe läuft weiter.
- Fund: Der erste Ringpuffer kopierte Sample für Sample unter Sperre → die Tonausgabe fand die Sperre ~2×/s belegt (Aussetzer). Jetzt `memcpy` in 4096er-Stücken → 0 Aussetzer.
- Offen: 30-min-Dauertest der 5 Sender (läuft), Mindestdurchsatz live, Wiederverbinden nach Netzabbruch (§5).

### P3 HLS – 2026-11-12 · in Arbeit (Dauertest läuft)
- Neu: `HlsPlaylist` (Master/Media, Variante: niedrigste ≥ 96 kbit/s, nur reine Audio-Codecs; abgewiesen: AES/SAMPLE-AES, Session-Key, fMP4, Byte-Ranges, Zieldauer außerhalb 1–30 s, > 10 000 Segmente), `HlsReader` (Start 3 Segmente vor der Live-Kante, Neuladen pro Zieldauer, Delta-Abruf `_HLS_skip=YES`, ≤ 4 Segment-Hosts, 404 überspringen, Discontinuity → Decoder neu), `TsDemuxer` (geprüfte Längen, ADTS/MP3, LATM abgewiesen).
- **Abweichung von §3:** Der TS-Zerleger läuft in der App, nicht im XPC-Dienst. Er ist reines Swift mit Grenzprüfung (im schlimmsten Fall ein Absturz, kein Speicherüberschreiben); Apples Decoder bleiben im Dienst ohne Rechte.
- **Neu entschieden:** Streams mit Videospur (Fernsehsender wie „BBC News HD“) werden abgewiesen – sie luden 3–5 Mbit/s Video für nichts.
- Live geprüft: 1LIVE (TS), FIP, BBC 6 Music (TS), NHK World und TRT Türkü (Packed Audio), Radio Italia (`METHOD=NONE` korrekt angenommen); NHK-Japan (fMP4) und BBC News HD (Video) abgewiesen. 0 Aussetzer.

### P4 Oberfläche – 2026-11-12 · in Arbeit
- `FonaCore/Library` (library.json nach §3.1, atomar, beim Laden geprüft, defekte Datei → `.broken`), `FonaCore/Directory/RadioBrowser` (Serverliste mit Ausweichen, eine Anfrage pro Land, Einträge geprüft, `homepage`/`favicon` nie gelesen).
- App: `AppModel` (Einstellungen §3.2 geprüft gelesen, Wiedergabe über `StationPlayer` + XPC-Decoder), `PopoverView` (Favoriten + Zuletzt gehört, Alle Sender mit Suche/Länderfilter, Sender hinzufügen mit Probe, Umbenennen, Nachrichten-Kopfzeile), `SettingsView` (ein Fenster, passt sich dem Inhalt an), Texte de/en in `L10n.swift` (fehlende Übersetzung = Compilerfehler).
- Prüfung per `--snapshot` (zeichnet alle Ansichten hell/dunkel mit Beispieldaten, speichert nichts): stimmt mit `design/canvas` überein. Korrigiert nach Sichtung: Menüs zeigten den macOS-Popup-Stil (Rahmen weg, Pfeil links), Nachrichten-Kopfzeile im Dunkelmodus dunkel auf dunkel, Logos in Großbuchstaben, „in 0 Sek.“ → „jetzt“.
- **Fehler meinerseits behoben:** Der Entwickler-Start `--play-url` schrieb einen Testsender in die echte Senderliste des Nutzers → entfernt, Teststarts speichern nichts mehr.
- P2-Dauertest (5 Sender × 30 min): 0 Dekodierfehler, aber 3–7 Sperr-Aussetzer je Sender → Tonausgabe versucht die Sperre jetzt einige µs lang erneut und liest den Nachrichtenpuffer nur, wenn er hörbar ist. Kontrolllauf läuft.
- **Zurückgestellt (Nutzer 2026-11-13):** Barrierefreiheit insgesamt. Befund des Nutzers: VoiceOver erkennt nur die Play-Taste. Kontrastwerte sind im Code berechnet (`Theme.swift`).
- Offen in P4: Checkliste Tastatur, Hover-Zustände, Menüleisten-Symbol aus `design/icon` statt SF Symbol, App-Icon (`.icns`).
- Kontrolllauf 2026-11-12 nach Umbau (sperrfreier Ringpuffer, HLS-Startpuffer = 2 Segmente): 7 Sender × 15 min (radioeins, DLF, SWR3, 1LIVE MP3, FluxFM 44,1 kHz, FIP HLS, 1LIVE HLS) → **0 Aussetzer, 0 Dekodierfehler**. FIP-Puffer zeitweise nur 3 s – beobachten.

### P5 Nachrichten – 2026-11-12 · Logik fertig, Live-Test bestanden
- **Kalibrierung (10 h Mitschnitt):** Vor den Nachrichten kommt das **Zeitzeichen** – kurze Pieps im 1-s-Abstand, dann ein langer (≈ 0,75–0,8 s), alles ≈ 780 Hz. Die Stille danach schwankt (0,55–2,4 s) → nicht mehr verlangt. „Ton + Stille“ fand 9 von 13 Ausgaben, das Zeitzeichen-Muster **14 von 14, 0 Fehlalarme**. Nachts nur volle Stunde, ab 04:30 auch halbe → Standard-Zeitplan „volle und halbe Stunde“.
- Gemessene Längen: halbe Stunde ≈ 5 min, volle Stunde 5–10 min (06:00/08:00 ≈ 10 min) → Höchstdauer ohne Nachrichten-Titel Standard 10 min.
- `NewsLogic` (reiner Zustandsautomat, §6.4, Tests mit simulierter Uhr), `NewsWatcher` (stumme DLF-Kette, 15 s Gedächtnis, Wiedergabe ab dem ersten Piep, 80-ms-Blende), Prüfkatalog: synthetisches Zeitzeichen erkannt, Musik/Rauschen/Einzelton/Dauerton nicht.
- **Live in der App** (stumm, Programm FluxFM): 09:30 – Rückkehr 1 s nach Titelwechsel (09:34:22 → 09:34:23); dabei Fehler gefunden: erster Titel nach dem Start löste mitten in der Sendung aus → behoben (erster Titel = Ausgangslage). 10:00 – **Umschaltung durch das Zeitzeichen** um 10:00:01,7 (vor dem Titel um 10:00:03), Wiedergabe ab 3,1 s zurück; Rückkehr 10:07:57, 1 s nach Titelwechsel.
- Offen: Hörtest durch den Nutzer; Ende-Erkennung am Ton (Abschlussmelodie) für den seltenen Fall ohne Nachrichten-Titel; Auswertung des kompletten 24-h-Mitschnitts.

### P6 Support – 2026-11-12 · App-Seite fertig, Dienst vorbereitet
- `FileLog` (Container `Library/Logs/Fona/Fona.log`, 1 MB + `.old.log`, Zeilen bereinigt, Wiederholungen gedrosselt; nie URLs/Namen/Titel), `Report` + `Reporter` (Schema des bestehenden Workers, Feld `product: "fona"`, Prüfkatalog nach Bereichen gruppiert wegen ≤ 100 Ergebnissen, Benutzername/Pfade entfernt), Versand über NetGate (`report`, POST nur für diese Klasse, keine Weiterleitung beim Senden), sonst Ablage `Application Support/Fona/Reports/`.
- Selbsttest in der App: Prüfkatalog + live Senderverzeichnis und Deutschlandfunk (offline = „übersprungen“), danach anonymer Bericht. „Problem melden …“: Beschreibung, freiwillige E-Mail, Systeminfo + Protokoll optional.
- Worker (Mountpoint `worker/`, **nicht committet, nicht deployt**): Eintrag `"fona": "moritz-poth/fona-reports"`, Härtung aus Review M12 (IP nur als gesalzener Hash, Steuer-/Bidi-/Tag-Zeichen entfernt, Problemtext als Codeblock).
- 2026-11-12 erledigt: Repo `moritz-poth/fona-reports` (privat) angelegt, vom Nutzer im Token freigegeben, Worker committet (Mountpoint `2cae717`) und deployt inkl. `cd909e7`, Secret `IP_SALT` gesetzt. **Ende-zu-Ende geprüft:** `--selftest` → Issue #1 „8/8 passed“ (147 Prüfungen), Bericht ohne Namen, Pfade, URLs oder Sendernamen; Protokoll im Bericht nur „start Fona …“ und „self-test …“.
- Nicht geprüft: Berichte von Mountpoint/MediaFiles Check nach dem Deploy.

### P7 Release – 2026-11-12 · lokal fertig, Veröffentlichung offen
- Eigener Schlüssel „Fona update key“ (Schlüsselbund), `UpdateKey.publicKey`; `UpdateCheck` (Releases nur mit `.sig`, Downloads nur von `github.com/moritz-poth/Fona/releases/download/`, Testversionen per Einstellung), `AppUpdater` (Suche beim Start + alle 6 h über NetGate, Download, Vorprüfung, Übergabe, sofort beenden), `FonaUpdater.app` (Vertrauensgrenze, §7), Hinweis bei App Translocation.
- Handbuch de/en (`Resources/help`, eigenes Fenster), Abschnitte „Updates“ und „Über Fona“ in den Einstellungen, README.
- **Lokaler Update-Test:** 0.1.0 → signiertes 0.1.1: ausgetauscht, neu gestartet. Abgewiesen: manipulierte ZIP („signature does not match“), signiertes 0.1.0 („no downgrades“), Symlink statt ZIP („no download“).
- 2026-11-12 veröffentlicht: Repo https://github.com/moritz-poth/Fona (öffentlich, Historie vorher von Plugin-Statusdateien bereinigt), Prerelease **v0.1.0-beta.1** (universell, ZIP + Signatur; Selbsttest des Release-Builds = Issue #2). Live geprüft: API → neueste Version → ZIP + Signatur über NetGate inkl. Weiterleitung → Signatur gültig.
- Offen: Ende-zu-Ende-Update in der App mit dem nächsten Prerelease; macOS-14-Test (P0-a).

### P4 Barrierefreiheit – 2026-11-12
Code-Prüfung gegen `accessibility.md`/`voiceover.md` (HIG); 10 Befunde behoben:
1. Senderzeilen waren nur per Maus bedienbar → echte Schaltflächen (Tab/Leertaste mit Full Keyboard Access).
2. Rechtsklick-Aktionen auch als VoiceOver-Aktionen (Favorit, Umbenennen, Entfernen).
3. Suchtreffer: Abspielen und Stern als zwei getrennte Schaltflächen (vorher Knopf in Knopf).
4. Schalter melden „Ein/Aus“ in der App-Sprache (vorher immer „On/Off“).
5. Such-, Link-, Namens-, Beschreibungs- und Kontaktfeld beschriftet.
6. „Sender hinzufügen“/„Umbenennen“: Fokus springt ins Feld, für VoiceOver als Dialog gekennzeichnet.
7. Ansagen für VoiceOver: Hinweise, Fehler, Wiederverbinden, Prüfergebnis eines Links und **Wechsel zu den Nachrichten / zurück**.
8. „Kontrast erhöhen“: kräftigere Rahmen und Grautexte (≥ 10:1) über die High-Contrast-Erscheinungsbilder. **Nicht sichtbar prüfbar:** macOS erzeugt diese Erscheinungsbilder nur bei eingeschalteter Systemeinstellung.
9. Auswahlmenüs in den Einstellungen nennen ihren Zweck (z. B. „Zeitplan“), nicht nur den Wert.
10. Schalter-Animation folgt „Bewegung reduzieren“.
- Automatischer Prüflauf des Bedienungsbaums versucht und verworfen: SwiftUI baut ihn erst, wenn ein Hilfsprogramm (VoiceOver) von außen fragt.
- Offen: Gegenprobe mit echtem VoiceOver (⌘F5) und „Kontrast erhöhen“ durch den Nutzer.

### Rückmeldung Nutzer 2026-11-12 (nach erstem Hören)
- Umschaltung zu Deutschlandfunk funktioniert, war aber „sehr knapp“ → Wiedergabe beginnt jetzt 1,5 s **vor** dem ersten Piep (`NewsWatcher.leadInSeconds`).
- Suche: ⓧ zum Löschen. Lautstärkeregler unter dem Senderkopf (gespeichert). Zahnrad auch während der Nachrichten (vorher fehlte es dort → Einstellungen nicht erreichbar).
- Menüleisten-Symbol: abgerundetes Quadrat mit Kreis und F (Variante A), wie das App-Icon.
- Einstellungen/Handbuch: Fona wird solange zur normalen App (Dock, ⌘-Tab, Menü „Fona“/„Bearbeiten“ wie Mountpoint: Über Fona, Fona ausblenden, Einstellungen schließen ⌘Q, verstecktes ⌘W; Fenstertitel überall „Fona“). **Kein zweites Programm wie in Mountpoint:** in der Sandbox bekäme es einen eigenen Datenbereich (gemeinsame Daten nur per App Group = Apple-Entwicklerkonto).
- Fehler gefunden und behoben: Abschnitt „Über Fona“ lag seit P7 außerhalb der Fensterstruktur. Einstellungen scrollen jetzt (560 × 720).
- Veröffentlichung jetzt immer mit DMG (wie Mountpoint: App neben Programme-Verknüpfung, Titel „FONA“), ZIP + Signatur bleiben für den Updater. README-Kopf wie Mountpoint.
- Veröffentlicht 2026-11-12: Prerelease **v0.1.0-beta.2** (DMG + ZIP + Signatur). Live geprüft: API liefert beta.2, ZIP-Signatur gültig. **Update in der App beta.1 → beta.2 vom Nutzer bestätigt (2026-11-12)** – P7 damit Ende-zu-Ende geprüft.

### Absturz 2026-11-12 11:30 (Nutzer, beta 2) · behoben
- Absturzbericht: „Can't take a suffix of negative length“ in `NewsSink.activate`; Protokoll: `fadeToNews(replaySeconds: -133.6)`.
- Ursache: Beim Neustart der stummen DLF-Kette (jeder Senderwechsel) wurde der Sample-Zähler des Puffers auf 0 gesetzt, der des Tonerkenners nicht → „Sekunden seit dem ersten Piep“ negativ.
- Behoben: ein Zähler (der des Erkenners), Erkenner wird mit dem Puffer neu angelegt; Wiedergabelänge auf 0–15 s begrenzt (NaN/∞ → 0); die Kette läuft beim Senderwechsel weiter (Programm gilt beim Verbinden/Puffern/Wiederverbinden als an). Regressionstests `replayLengthStaysValidAfterRestarts`, `activateNeverCrashesOnBadLengths`.
- Veröffentlicht 2026-11-12: Prerelease **v0.1.0-beta.3** (Absturz-Korrektur, Menüleisten-Symbol Variante 3, Update-Hinweis unten, Lautstärke-Balken). Selbsttest des Release-Builds = Issue #3.

### Rückmeldung Nutzer 2026-11-12 (nach beta 3)
- Nach dem Neustart steht der zuletzt gespielte Sender schon im Kopf (Play startet ihn), auch ohne „beim Start weiterspielen“.
- Pegel-Animation (Vorschlag 4 „Echte Pegel“): neben dem laufenden Sender fünf Balken = die letzten fünf Messungen der echten Lautstärke (RMS im Render-Callback, vor der Lautstärke; −36…−8 dBFS → 3…14 pt, alle 0,08 s). Läuft nur bei offenem Fenster; mit „Bewegung reduzieren“ statisches Wellensymbol. Live: Musik 8–12 pt, Sprache 4–11 pt. `fona-play --levels` zeigt die Werte.

### Rückmeldung Nutzer 2026-11-12 (Lautstärke, Namen)
- Lautstärke: kein dicker blauer Fokusrahmen mehr (eigene dünne Markierung, Tastatur geht weiter); Mausrad/Trackpad über dem Regler (1 Raste = 5 %, Rad hoch = lauter, auch bei „natürlichem Scrollen“).
- Update-Hinweis: sitzt seit beta 3 am unteren Rand (Snapshot `6-update`); der Nutzer hatte ihn noch in beta 2 gesehen.
- Anzeigenamen: Umbenennen gab es schon (Rechtsklick auf einen Sender); neu auch per Rechtsklick auf den Namen im Kopf. Handbuch ergänzt.
- Veröffentlicht 2026-11-12: Prerelease **v0.1.0-beta.4** (letzter Sender im Kopf, Pegelbalken, Mausrad-Lautstärke, Umbenennen im Kopf). Vorher 1-Mio.-Fuzzing grün; API liefert beta.4, Downloads identisch mit dem Build.

### Rückmeldung Nutzer 2026-11-12 (nach beta 4)
- Lautstärke: auch die dünne Markierung beim Anklicken entfernt (keine Umrandung mehr; Pfeiltasten gehen weiter, VoiceOver ansagbar).
- Einstellungen/Handbuch über das Zahnrad schließen jetzt sofort das Menüleisten-Fenster (vorher blieb es offen und verschwand erst beim Schließen des anderen Fensters).
- „Zuletzt gehört“: Grenze 10 bestand schon (Favoriten zählen mit, werden dort aber nicht gezeigt) – Nutzer: so lassen.
- Veröffentlicht 2026-11-12: Prerelease **v0.1.0-beta.5** (Fenster schließt beim Öffnen von Einstellungen/Handbuch, keine Umrandung am Lautstärke-Balken). API liefert beta.5, Downloads identisch.
- Update-Hinweis: unten 12 pt Abstand wie seitlich. Einstellungen und Handbuch mit Kopfzeile: App-Icon + „Fona – Einstellungen/Handbuch“ (leichte Schrift, 28 pt, `WindowTitle`); erste Zeile der Handbuch-Dateien dafür entfernt. „Jetzt suchen“ mit gefundenem Update öffnet das Menüleisten-Fenster (Klick auf das Statusleisten-Symbol per Code, `MenuTarget.showMenuBarWindow`; noch nicht live geprüft). Snapshot `7-manual` neu.
- Veröffentlicht 2026-11-12: Prerelease **v0.1.0-beta.6** (Kopfzeilen mit Icon, Update-Abstand, „Jetzt suchen“ öffnet Menüleisten-Fenster). API liefert beta.6, Downloads identisch.
- Veröffentlicht 2026-11-12: Prerelease **v0.1.0-beta.7** (Sicherheitsfunde F1 und F2 behoben, README mit Screenshots).
- Veröffentlicht 2026-11-12: Prerelease **v0.1.0-beta.8** (Play/Pause-Taste, Kopfhörertaste und Kontrollzentrum über `NowPlaying.swift`; Sender und Titel im Kontrollzentrum).

### Rückmeldung Nutzer 2026-11-13 (nach beta 8)
- Nachrichten ohne Nachrichten-Titel enden beim ersten Sendungstitel (§6.3, P0-b).
- Play/Pause-Taste „geht nicht“: macOS gibt die Taste der App, die zuletzt zu spielen *begann* (Chrome um 16:24) – kein Fona-Fehler; Pause/Play in Fona holt sie zurück.
- Titel im Kopf läuft durch, wenn er nicht passt (`Marquee`, hin und zurück, still bei „Bewegung reduzieren“).
- Favoriten: eigene Liste statt `List` (die zeichnete beim Rechtsklick einen blauen Rahmen); Rechtsklick-Rahmen jetzt Salbei, Sortieren per Ziehen selbst gebaut (`FavoriteDrop`).
- Zahnrad-Menü entfällt: Fußleiste mit Symbolen Zahnrad (Einstellungen, ⌘,), aufgeschlagenes Buch (Handbuch), rechts Ein/Aus (Beenden) – Canvas-Variante C ohne Text. Update-Hinweis sitzt jetzt über der Fußleiste.

### Sicherheits-Scan 2026-11-12 (Claude Security, ganzes Repo, medium, Revision c28d63e) · offen
- Bericht lokal: `CLAUDE-SECURITY-20261112-135126/` (git-ignoriert). 2 Funde, beide LOW, je 3/3 bestätigt; 2 weitere Kandidaten 0/3 verworfen.
- **F1 behoben 2026-11-12** (`localNets()` per getifaddrs, gilt in `choose`, URL-Literal und Peer-Recheck; 5 Checks im Katalog; live: eigene Adresse und eigenes /64 gesperrt, DLF spielt). Rest: Router-WAN-IPv4 per Hairpin-NAT ist lokal nicht erkennbar und bleibt offen. – `AddressPolicy.isPublic`: eigene IPv6-Adresse des Macs und Adressen im eigenen /64 gelten als öffentlich (auch Router-WAN-IPv4 per Hairpin-NAT) → blinde GETs an Mac/Router möglich. Korrektur: beim Verbinden `getifaddrs` lesen, eigene Adressen und On-Link-Präfixe in `choose` und Peer-Recheck ablehnen; Fälle in `CheckCatalog`.
- **F2 behoben 2026-11-12** (Helfer loggt nur noch über `os.Logger`). – `FonaUpdater` schreibt sein Log ohne Sandbox in den Container-Ordner und folgt dabei Symlinks (nur relevant nach Übernahme des Sandbox-Prozesses). Korrektur: Helfer loggt über `os.Logger` statt in den Container.
- Nutzer entscheidet noch: direkt beheben oder erst als Patch-Vorschlag.
