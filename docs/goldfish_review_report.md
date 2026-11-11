# Goldfish-Review: Fona – Plan

**Ziel:** `docs/PLAN.md` (Zeilen 1–223, Stand 2026-11-12)
**Datum:** 2026-11-12
**Nicht neu verhandelt:** die Entscheidungen aus §2 (eigener HLS-Leser statt AVPlayer, Sandbox + FonaUpdater, kein Heimnetz, keine Logos, de+en, 80-ms-Überblendung). Wo ein Befund eine dieser Entscheidungen berührt, ändert der Vorschlag nur das Drumherum.

## Status der Reviewer

| Reviewer | Blickwinkel | Status |
| --- | --- | --- |
| `egm-design` | Architektur, Machbarkeit auf macOS | abgeschlossen |
| `egm-implementation-readiness` | Umsetzbarkeit ohne Rückfragen | abgeschlossen |
| `egm-zoom-out` | Einfachheit, Umfang | abgeschlossen |
| `egm-codebase-details` | Faktentreue, Abgleich mit Mountpoint und `dlf.log` | abgeschlossen |
| `security-reviewer` | Sicherheitslücken | abgeschlossen |

**Ergebnis:** 4 kritisch · 11 hoch · 13 mittel · 10 niedrig, nach dem Zusammenführen der Doppelungen.

**Gesamturteil:** Der Plan ist gut gegliedert, und die Sicherheitsidee (eine einzige Netzwerkstelle, alles Fremde ist feindlich) ist richtig. In seiner jetzigen Form ist er aber **noch nicht umsetzbar**:

- Zwei Grundannahmen zur Netzwerkschicht stimmen technisch nicht (K1, K2). Ohne Korrektur spielen entweder die meisten http-Sender nicht, oder der versprochene Heimnetz-Schutz existiert nicht.
- Der Selbsttest widerspricht der Sandbox (K3).
- Das Update mit Sandbox und Ad-hoc-Signatur birgt mehr Risiken, als Spike P0-a prüft (K4).

K1 bis K3 verändern NetGate und die Berechtigungen. Sie müssen deshalb **vor P1** entschieden werden.

Nicht geprüft: Kein Reviewer konnte macOS-Verhalten tatsächlich ausprobieren. Die Punkte, die mit „in P0 bestätigen“ markiert sind, beruhen auf Apple-Dokumentation und bekanntem Plattformverhalten.

---

## Kritisch

### K1 – Die ATS-Ausnahme `NSAllowsArbitraryLoadsForMedia` gilt nicht für NetGate
- **Reviewer:** alle fünf
- **Stelle:** §4.1 N10 (Z. 101); betrifft auch N5 (Z. 96) und §1 (Z. 18)
- **Was falsch ist:**
  - Der Schlüssel nimmt nur Medien aus, die AVFoundation lädt.
  - NetGate ist eine `URLSession` (Z. 88), und AVPlayer ist ausdrücklich ausgeschlossen (Z. 79). App Transport Security blockiert also jeden `http://`-Stream (Fehler −1022). Das betrifft einen Großteil der Icecast-/Shoutcast-Sender bei radio-browser.
  - Zusätzlich gilt: Ist ein `…ForMedia`-Schlüssel gesetzt, ignoriert macOS `NSAllowsArbitraryLoads`.
  - Die Regel „unverschlüsseltes http nur für Medien“ kann ATS also gar nicht durchsetzen.
- **Warum es wichtig ist:** Die Kernfunktion fällt bei vielen Sendern aus. Die naheliegende schnelle Reparatur, global `NSAllowsArbitraryLoads`, würde unbemerkt auch http für radio-browser, Updater und Berichte erlauben.
- **Korrektur am Plan:**
  - N10 neu formulieren. Entweder nur `NSAllowsArbitraryLoads = YES` (ohne ForMedia-Schlüssel) mit dem ausdrücklichen Satz „ATS schützt nicht; NetGate setzt die http-Regeln selbst durch“. Oder NetGate auf Network.framework bauen (siehe K2); dort gilt ATS nicht.
  - In NetGate **Anfrageklassen** einführen:
    - `stream`, `segment`, `playlist`: http erlaubt.
    - `directory`, `update`, `report`: nur https, Host auf fester Liste, auch bei jeder Weiterleitung.
  - Test ergänzen: „http-Icecast-Stream spielt im sandboxed Build“.

### K2 – Der Schutz gegen DNS-Rebinding (N4) lässt sich mit URLSession nicht bauen
- **Reviewer:** alle fünf
- **Stelle:** §4.1 N4 (Z. 95), §12 (Z. 220)
- **Was falsch ist:**
  1. `URLSessionTaskMetrics` kommen erst in `didFinishCollecting`, also wenn die Aufgabe endet. Ein Live-Stream endet nie. Die Prüfung „nach dem Verbinden“ läuft deshalb beim Radiohören **nie**.
  2. Bei kurzen Abrufen (Playlist, Segment) läuft die Prüfung zu spät: Die GET-Anfrage hat das Gerät im Heimnetz schon erreicht (blindes CSRF gegen Router oder NAS).
  3. URLSession löst den Namen selbst noch einmal auf (TTL 0, Happy Eyeballs). Die Vorabprüfung ist damit eine Prüf-/Nutzungs-Lücke.
  4. Mit System-Proxy oder PAC ist die Gegenstelle der Proxy. Die Prüfung würde dann alles abweisen, oder der Proxy erreicht das Heimnetz für den Angreifer. Dasselbe gilt für „Fake-IP“-Werkzeuge (198.18/15).
- **Warum es wichtig ist:** Das ist die Hauptverteidigung gegen Zugriffe ins Heimnetz, also genau die Sicherheitsentscheidung aus §2. So, wie sie geschrieben ist, gibt es sie nicht.
- **Korrektur am Plan (passend zu „Sicherheit zuerst“):** NetGate bekommt einen eigenen kleinen HTTP/1.1-Client auf `NWConnection`:
  1. Den Namen selbst auflösen (`getaddrinfo`).
  2. **Alle** zurückgegebenen Adressen prüfen.
  3. Genau zu der geprüften IP verbinden.
  4. Bei TLS den Servernamen per `sec_protocol_options_set_tls_server_name` setzen und die normale Hostnamen-Prüfung des Zertifikats verwenden.
  5. Im Zustand `.ready` die Gegenstelle (`currentPath?.remoteEndpoint`) erneut prüfen, **bevor** das erste Byte gesendet wird.
  6. Proxys abschalten (neue Regel N11). Im Handbuch steht dann: „Fona funktioniert nicht hinter Pflicht-Proxys oder mit Fake-IP-Werkzeugen.“

  Nebeneffekte, die der eigene Client gleich mit löst:
  - Shoutcast-v1 antwortet mit `ICY 200 OK`, was URLSession eventuell nicht annimmt (siehe H9).
  - Die Kopfzeilen- und Zeitgrenzen aus N6 werden genau einhaltbar.
  - Keine automatische Dekomprimierung, kein Alt-Svc/HTTP3, kein Kerberos/NTLM.

  Chunked-Transfer und Weiterleitungen müssen dafür selbst geschrieben werden. Das ist wenig Code und lässt sich fuzzen.
- **Alternative:** URLSession behalten. Dann muss §12 ehrlich sagen: „Rebinding nur nach bestem Bemühen; Restrisiko akzeptiert.“ Den Metrics-Satz streichen. Zusätzlich setzen: `connectionProxyDictionary = [:]`, `.ephemeral` ohne Cache/Cookies/Credentials, Authentifizierungs-Challenges außer ServerTrust abbrechen, `assumesHTTP3Capable = false`.
- Die Entscheidung als neuen Spike P0-f vor P1 eintragen.

### K3 – Der Loopback-Testserver im Selbsttest widerspricht der Sandbox und ist ein Schlupfloch
- **Reviewer:** alle fünf
- **Stelle:** §8.2 (Z. 176–177) gegen A1 (Z. 117) und N3
- **Was falsch ist:**
  - Ein lauschender Socket braucht in der Sandbox `com.apple.security.network.server`. A1 erlaubt nur `network.client`.
  - Eine zweite NetGate, die Loopback erlaubt, liegt im ausgelieferten Programm. Eine falsche Verdrahtung macht sie zum Weg ins Heimnetz, etwa über ein Singleton, ein `testMode`-Flag oder einen Stream, der startet, während der Selbsttest läuft. Damit stimmt „EINZIGE Stelle“ (Z. 62) nicht mehr.
  - Während der Selbsttest läuft, ist der Server auch für andere Prozesse erreichbar.
  - Punkt 1 in Z. 177 („gegen die echte NetGate-Konfiguration“) kann über Loopback gar nicht laufen, denn die echte NetGate sperrt Loopback.
- **Korrektur am Plan:**
  - Den Testserver und die zweite NetGate streichen.
  - Die NetGate-Regeln als reine Funktionen formulieren, zum Beispiel `prüfe(url, aufgelösteAdressen, anfrageklasse) → Entscheidung`, dazu `prüfe(weiterleitung)`, `prüfe(kopfzeilen)` und `prüfe(ersteBytes)`. Die Angriffsfälle rufen diese Funktionen mit der **Produktions**-Konfiguration auf, ganz ohne Netzwerk.
  - Die Abspielkette (Icy/HLS/TS/Decoder) bekommt eine abstrakte Bytequelle. Der Selbsttest speist mitgelieferte Testdateien aus dem Speicher ein, unterhalb von NetGate.
  - Einen Quelltext-Test ergänzen: „Die Produktions-NetGate kennt keine Ausnahme.“ A1 bleibt unverändert.

### K4 – Spike P0-a prüft die gefährlichsten Update-Fälle nicht
- **Reviewer:** design, codebase-details, implementation-readiness, security
- **Stelle:** §7 (Z. 160–163), §2 „ad-hoc signiert“, A4 (Z. 120), §10 P0-a
- **Was falsch ist (in P0 bestätigen):**
  - Ab macOS 14 sind Sandbox-Container an die Code-Identität gebunden. Bei Ad-hoc-Signatur ist das der Code-Hash, und der ändert sich mit jedem Build. Nach jedem Update kann macOS fragen („… unterscheidet sich vom ursprünglichen Programm“), oder Fona verliert den Zugriff auf `library.json`.
  - Ein nicht sandboxed FonaUpdater, der die ZIP aus `~/Library/Containers/<Fona>/` liest, löst die Abfrage „Zugriff auf Daten anderer Apps“ aus. Beides widerspricht §6 „Nichts öffnet sich von selbst“ und gefährdet die Favoriten.
  - `NSWorkspace` startet nur ein `.app`-Bundle. Ein nacktes Programm, gestartet mit `Process`, erbt die Sandbox.
  - Downloads aus der Sandbox tragen immer das Quarantäne-Attribut. Gatekeeper blockiert dann den Ad-hoc-Build.
  - `ditto` und `codesign` als Kindprozesse laufen in Fonas Sandbox (Mountpoint `Updater.swift:195, 201`).
- **Korrektur am Plan:**
  - P0-a erweitern. Auf macOS 14 **und** 15: v1 bauen, Favoriten anlegen, über den Helfer auf einen neu gebauten v2 aktualisieren, dann prüfen, ob Abfragen erscheinen und ob der Container-Zugriff noch geht.
  - Festschreiben:
    - Der Helfer liegt als `Contents/Helpers/FonaUpdater.app` mit `LSUIElement` im Bundle und wird über `openApplication` gestartet.
    - Signiert wird von innen nach außen: erst den Helfer **ohne** Sandbox-Rechte, dann Fona.app mit Rechten, **nie** mit `--deep` (Muster: Mountpoint `build-app.sh:58–110`).
    - Der Helfer entfernt die Quarantäne, aber erst nach erfolgreicher Prüfung.
  - Ausweichwege nennen, falls Abfragen kommen:
    - (a) ein stabiles, selbstsigniertes Codesignatur-Zertifikat statt Ad-hoc (bleibt ohne Apple-Konto);
    - (b) der Helfer lädt die ZIP selbst in seinen eigenen Temp-Ordner; Fona übergibt nur die Versionsnummer.
  - Der bestehende Fallback „Browser-Download“ bleibt.

---

## Hoch

### H1 – FonaUpdater ist ein Ausweg aus der Sandbox (Vertrauensgrenze)
- **Reviewer:** security, codebase-details, zoom-out
- **Stelle:** §7 (Z. 162), A4 (Z. 120)
- **Was falsch ist:** Jeder Prozess des Nutzers kann den Helfer starten, auch ein Fona, das über einen Decoder-Fehler übernommen wurde (H3). Daraus ergeben sich vier Lücken:
  - Über `OpenConfiguration.environment` lässt sich `DYLD_INSERT_LIBRARIES` setzen. Das bedeutet Codeausführung außerhalb der Sandbox.
  - Ein Pfad-Argument macht den Helfer zum „verwirrten Stellvertreter“: Er handelt im Auftrag eines fremden Aufrufers.
  - Die ZIP liegt dort, wo ein kompromittiertes Fona schreiben kann. Zwischen Prüfung und Auspacken ist ein Zeitfenster.
  - „Versionsschlüssel müssen stimmen“ verhindert keinen **Downgrade** auf eine ältere, signierte Version mit bekannter Lücke.
- **Korrektur am Plan (A4 ersetzen):**
  - Der Helfer läuft mit Hardened Runtime, ohne `allow-dyld-environment-variables` und ohne `disable-library-validation`. Die Umgebung wird beim Start ignoriert.
  - **Keine Argumente.** Das Ziel ergibt sich nur aus dem eigenen Ort (`Bundle.main` → umschließendes `Fona.app`). Die ZIP liegt unter einem festen Dateinamen im Container; Symlinks werden abgewiesen.
  - Ablauf im Helfer:
    1. ZIP einmal in den Speicher lesen.
    2. Ed25519-Signatur auf genau diesen Bytes prüfen.
    3. In einen eigenen `mkdtemp`-Ordner schreiben und dort mit `ditto -x -k` auspacken.
    4. Prüfen: genau ein `Fona.app`, keine Symlinks nach außen, Bundle-ID stimmt, Version **strikt neuer** als die installierte, `codesign --verify --deep --strict` besteht.
    5. Warten, bis Fona beendet ist; dann austauschen; Quarantäne entfernen.
  - Maßgeblich ist die Prüfung im Helfer, denn er ist die Vertrauensgrenze. Die Vorprüfung in Fona dient nur noch dazu, eine klare Fehlermeldung zu zeigen.

### H2 – Der macOS-Schutz „Lokales Netzwerk“ ist als zweite Mauer überschätzt
- **Reviewer:** codebase-details, design, security, zoom-out
- **Stelle:** N10 (Z. 101), P0-d (Z. 199), §12 (Z. 220)
- **Was falsch ist (in P0-d bestätigen):**
  - Den Schutz gibt es erst ab macOS 15. Das Ziel ist macOS 14.
  - Fehlt `NSLocalNetworkUsageDescription`, blockiert macOS 15 nicht still, sondern zeigt eine Abfrage, und der Nutzer kann „Erlauben“ klicken.
  - Loopback, 100.64/10 (Tailscale) und VPN-Routen sind nie abgedeckt.
- **Korrektur am Plan:** N10 und die Zeile in §12 als „Zusatz, kein Schutz“ kennzeichnen. N3/N4 (nach K2) müssen allein ausreichen. P0-d prüft nur noch, wie sich die Abfrage unter macOS 15 verhält.

### H3 – Apple-Decoder lesen feindliche Bytes in dem Prozess, der Netzwerkzugriff hat
- **Reviewer:** security
- **Stelle:** §3 Decoder (Z. 68), S5 (Z. 110), A1, §12 (Z. 219)
- **Was falsch ist:**
  - AudioFileStream und AVAudioConverter hatten 2025 eine aktiv ausgenutzte Speicherlücke (CVE-2025-31200).
  - Ein erfolgreicher Exploit im Fona-Prozess umgeht alle NetGate-Regeln, denn `network.client` erlaubt das ganze Netz. Er kann außerdem FonaUpdater starten (H1).
  - „Sandbox als zweite Mauer“ schützt das Dateisystem, nicht das Netzwerk.
- **Korrektur am Plan:**
  - Pflicht: ein eigener, strenger Frame-Prüfer vor den Apple-Decodern.
    - ADTS: nur AAC-LC/HE, `channel_config` 1–2, Abtastrate aus fester Liste, `frame_length` zwischen Kopflänge und 8 KB.
    - MP3: nur Layer III, gültige Bitraten- und Abtastraten-Indizes, höchstens 2 Kanäle.
    - ID3: höchstens etwa 64 KB.
  - Dieser Prüfer wird gefuzzt wie S5.
  - Optional (Nutzerentscheidung, mehr Aufwand): Demux und Decoder in einen XPC-Dienst im Bundle **ohne** Berechtigungen auslagern. Die Haupt-App schickt nur Bytes hinein und bekommt PCM zurück.

### H4 – Die Regeln der Nachrichten-Erkennung widersprechen sich oder lösen falsch aus
- **Reviewer:** design, implementation-readiness, zoom-out, codebase-details
- **Stelle:** §5.2 (Z. 133–137), §5.3 (Z. 141–142)
- **Was falsch ist:**
  - **12:00-Fall:** Der Ton löst aus, aber der Titel bleibt „Deutschlandfunk – Alles von Relevanz“. Nach Stufe 2 beendet „Titel ohne ‚Nachrichten‘“ die Nachrichten. Fona springt also beim nächsten Titel-Update (laut `dlf.log` alle 15–20 s) sofort zurück.
  - **Zeitplan als Auslöser:** „Weder Ton noch Titel binnen ±60 s“ trifft genau dann zu, wenn **keine** Nachrichten laufen (nachts, am Wochenende, in Sendeplätzen ohne Nachrichten). Fona würde dann stündlich für 3–10 min in normales Programm schalten. Bei +60 s reicht der 15-s-Ringpuffer außerdem nicht mehr an den Anfang zurück.
  - Es fehlt, welche Dauer (3/5/10 min) gilt, wenn nur der Ton ausgelöst hat.
  - „Enthält ‚Nachrichten‘“ trifft auch „Nachrichtenleicht“, „Sport-Nachrichten“ und „Wie Nachrichten entstehen“.
  - Titel-Erkennung gibt es nur bei ICY-Sendern. HLS-Sender haben kein `StreamTitle`.
- **Korrektur am Plan:**
  - Das Titel-Ende wird erst scharf, wenn in dieser Episode ein Titel mit „Nachrichten“ gesehen wurde. Sonst kommt das Ende aus dem Zeitplan.
  - Der Zeitplan liefert **nur** das Ende und das Plausibilitätsfenster und löst nie allein aus. Ob er doch auslösen darf, entscheidet P0-b.
  - Eine Dauertabelle (Uhrzeit/Wochentag → Minuten) ergänzen; `dlf.log` zeigt 11:00 und 11:30 mit je etwa 5 min.
  - Titelregel: als Wort am Anfang (`^Nachrichten\b`). Für Titel-Auslösung ohne Ton gilt zusätzlich das Zeitplanfenster.
  - Festhalten, dass ein HLS-Sender als Nachrichtensender nur über Ton und Zeitplan funktioniert, oder ihn ausschließen.

### H5 – Zustandsautomat sowie Fehler- und Systemereignisse sind nicht definiert
- **Reviewer:** implementation-readiness, design
- **Stelle:** §5.3 (Z. 143–144), §3, §6
- **Was fehlt:**
  - Übergänge für:
    - Pause während der Nachrichten;
    - Senderwechsel während der Nachrichten;
    - der Nachrichtensender selbst wird gewählt;
    - der Nachrichtenstream fällt aus (sofort zurück?);
    - der Programmstream fällt aus;
    - „Jetzt zurück“ (gilt die 10-min-Sperre?);
    - 12 min erreicht;
    - der Titel sagt schon „Nachrichten“, wenn der Watcher startet.
  - Ein- und Ausstieg für den Zustand „zurück“; die Sperrzeit als eigener Zustand `sperre`.
  - Wiederverbinden (Anzahl, Abstände, Aufgeben, Anzeige), Ruhezustand und Aufwachen, Netzwechsel (`NWPathMonitor`), Wechsel des Ausgabegeräts (`AVAudioEngineConfigurationChange` stoppt die Engine), HLS-404 und verlorene Live-Kante.
  - Ein Fehlerkatalog: jede Ablehnung aus N/S zu einem Klartext in de/en. Z. 156 nennt nur ein Beispiel.
- **Korrektur am Plan:**
  - In §5.3 eine vollständige Übergangstabelle (Zustand × Ereignis → Aktion, Folgezustand).
  - Neuer Abschnitt „Fehler und Wiederaufnahme“: Ereignis → Verhalten → Meldung. Zum Beispiel Wiederverbinden nach 1/2/5/10 s, höchstens N Versuche, dann ein Hinweis.
  - Jede Zeile bekommt einen Test mit simulierter Uhr (§8.1).

### H6 – „Programm angehalten, Verbindung bleibt offen, kein Puffern“ lässt sich so nicht umsetzen
- **Reviewer:** design, implementation-readiness
- **Stelle:** §5.3 (Z. 141)
- **Was falsch ist:**
  - Wird der ICY-Socket bis zu 12 min nicht gelesen, staut TCP, Icecast trennt langsame Clients, und N6 („20 s Stillstand“) schlägt selbst zu.
  - Bei HLS müssen Playlist und Segmente weiter geladen werden. Sonst heißt Zurückkehren „Puffern“.
- **Korrektur am Plan:** „Die Programmkette läuft stumm weiter (lesen, dekodieren, ICY-Parser synchron) in einen kurzen Ringpuffer von 1–2 s, der überschrieben wird. Die Rückkehr spielt live aus diesem Puffer.“

### H7 – Zwei `AVAudioPlayerNode`s passen nicht zu Überblendung und Ringpuffer
- **Reviewer:** design
- **Stelle:** §3 Player (Z. 69, 77), §5.3 (Z. 141)
- **Was falsch ist:**
  - `AVAudioPlayerNode.volume` lässt sich nicht pro Sample rampen. Schrittweises Setzen über 80 ms aus einem anderen Thread erzeugt Knackser und Zippern, also genau das, was die Überblendung verhindern soll.
  - Der „stumme Nachrichten-Node“ spielt live, der Umschaltpunkt liegt aber 2–4 s zurück im Ringpuffer. Dafür muss der Node gestoppt und neu bestückt werden, mit einer Lücke.
- **Korrektur am Plan:** Ein `AVAudioSourceNode` liest aus zwei lock-freien Ringpuffern (Programm, Nachrichten) und mischt mit einer Gleichleistungs-Rampe pro Sample im Render-Thread. Die Nachrichtenkette füllt nur ihren Ringpuffer und hat keinen eigenen Node. Nie `engine.inputNode` anfassen, sonst kommt die Mikrofon-Abfrage.

### H8 – Inhaltstyp (N7) und Byte-Prüfung (N8) weisen echte Sender ab und sind zugleich zu schwach
- **Reviewer:** codebase-details, design, zoom-out, implementation-readiness
- **Stelle:** N7 (Z. 98), N8 (Z. 99)
- **Was falsch ist:**
  - N7 kennt die Typen nicht, die echte Sender liefern: TS-Segmente kommen als `video/mp2t` (1LIVE, P3 würde scheitern), Icecast und CDNs schicken oft `application/octet-stream`, `binary/octet-stream` oder gar keinen Typ, Playlists kommen auch als `audio/mpegurl` oder `application/x-mpegURL`.
  - N8: Ein ICY-Stream beginnt mitten in einem Frame. „Die ersten Bytes“ schlägt deshalb oft fehl, und ein einzelnes 11-Bit-Sync kommt in Zufallsdaten auch vor.
  - HLS-Packed-Audio beginnt mit einem ID3-PRIV-Tag.
- **Korrektur am Plan:**
  - N7 wird eine Sperrliste (HTML, Bilder, Archive, Programme, `application/ogg`). Der Inhaltstyp dient nur zum Weiterleiten (Playlist/HLS/Audio) und für die Klartext-Meldung.
  - N8 entscheidet: in den ersten 8–16 KB (ohne ICY-Metadaten, nach einem übersprungenen ID3-Tag) ein Sync suchen. Dann 2–3 aufeinanderfolgende gültige Frames verlangen, deren Längen zusammenpassen.

### H9 – Bei ICY fehlen der Anfrage-Header und das richtige Parsen des Titels
- **Reviewer:** codebase-details, design, implementation-readiness
- **Stelle:** §3 IcyReader, S3 (Z. 108)
- **Was falsch ist:**
  - `Icy-MetaData: 1` wird nirgends verlangt. Ohne diesen Header schicken Server weder `icy-metaint` noch Titel. Damit fallen Titelanzeige **und** Titel-Erkennung aus.
  - Titel enthalten `;` und Zusatzfelder (`dlf.log:124`: `…Leon Merfort; PIK, Britta Fecke';json='{}';`). Wer am `;` trennt, schneidet den Titel ab.
  - Ob URLSession die Statuszeile `ICY 200 OK` von Shoutcast v1 annimmt, ist ungeprüft.
- **Korrektur am Plan:**
  - S3 um „Anfrage mit `Icy-MetaData: 1`“ ergänzen.
  - Parsen: `StreamTitle='` bis zum nächsten `';` oder bis zum Blockende.
  - Shoutcast v1 in P0 testen. Mit dem eigenen Client aus K2 ist das Problem gelöst.

### H10 – Datenmodelle, Einstellungen und Tonprofil fehlen
- **Reviewer:** implementation-readiness, security
- **Stelle:** §3 (Z. 81), A3 (Z. 119), §5.2, §12 (Z. 218)
- **Was fehlt:**
  - **`library.json`:** `schemaVersion`. Senderfelder: id, Quelle `radiobrowser|custom`, `stationuuid`, name, eigener Name, url, Ländercode, addedAt. Favoriten als geordnete id-Liste. Verlauf: maximal 10, ohne Doppelte, wandert ein wieder gehörter Sender nach oben? Längengrenzen. Schreiben über Temp-Datei + `replaceItemAt`. Text des Hinweises bei defekter Datei.
  - **Einstellungen:** jeder Schlüssel mit Typ, Standard und erlaubten Werten. Dazu gehören Umschaltung an/aus, Nachrichtensender, Zeitplan, Dauer, Länderfilter (Standard = Systemregion?), letzter Sender bzw. Fortsetzen beim Start, Anmeldestart. UserDefaults sind von außen änderbar (`defaults write`) und müssen beim Lesen wie A3 geprüft werden.
  - **Tonprofil:** `NewsProfile` mit 780 Hz, Toleranz, Fenster, Schwellen, Stillewerten, Stichwort, Zeitplan. Wie wird ein Sender seinem Profil zugeordnet? Laut Z. 218 soll es „per Update anpassbar“ sein: als Konstante im Code, nicht als ladbares Datenformat.
- **Korrektur am Plan:** Neuer Abschnitt §3.1 mit JSON-Beispiel, Einstellungstabelle und `NewsProfile`. Für das Format gilt: unbekannte höhere Version = defekt (→ `.broken`). Echte Migration erst bei der ersten Formatänderung (siehe N3 unten).

### H11 – radio-browser-Anbindung fehlt, und der Nachrichtensender ist fälschbar
- **Reviewer:** implementation-readiness, security
- **Stelle:** §3 Directory (Z. 61), §6 (Z. 154), S6 (Z. 111), §5
- **Was fehlt:**
  - Serverwahl (DNS `all.api.radio-browser.info` → Spiegel, Ausweichreihenfolge, nur https, die Server durchlaufen N3).
  - Endpunkte (`/json/stations/search?…&hidebroken=true&order=clickcount&reverse=true&limit=100`, `/json/countries`).
  - `url` oder `url_resolved`.
  - Mehrländerfilter: die API nimmt nur einen `countrycode`; also N Anfragen und zusammenführen?
  - Klick-Meldung ja/nein, Zwischenspeichern der Länderliste, Verhalten ohne Netz.
  - **Sicherheit:** Jeder kann radio-browser bearbeiten. Wenn Favoriten ihre URL von dort aktualisieren oder der Standard-Nachrichtensender über Name oder UUID gefunden wird, lenkt ein geänderter Eintrag Fona auf einen fremden Stream, und die Umschaltung spielt ihn automatisch.
- **Korrektur am Plan:**
  - Neuer Abschnitt „radio-browser“ mit den Punkten oben.
  - Festlegen:
    - Favoriten behalten die URL von dem Zeitpunkt, an dem sie hinzugefügt wurden, und werden nie still aktualisiert.
    - Deutschlandfunk und sein Tonprofil hängen an einer festen URL bzw. einem festen Host im Code.
    - Das Feld `homepage` wird nie angezeigt oder geöffnet.

---

## Mittel

### M1 – Adressliste in N3 lückenhaft; Prüfung besser an der Binäradresse
- **Reviewer:** security, codebase-details, design, zoom-out
- **Stelle:** N3 (Z. 94)
- **Was fehlt:**
  - IPv4: 0.0.0.0/8 (ganz), 192.0.0.0/24, TEST-NETs, 198.18/15, 240/4.
  - IPv6: `::/128`, `::/96` (IPv4-kompatibel), NAT64 `64:ff9b::/96` und `64:ff9b:1::/48` (`64:ff9b::c0a8:101` wird zu 192.168.1.1), 6to4 `2002::/16`, Teredo `2001::/32`, `fec0::/10`, Zonen-IDs.
- **Korrektur am Plan:**
  - N3 behält nur die Namensregeln: `localhost`, `*.local`, `*.home.arpa`, `*.internal`, Einzelwort, abschließender Punkt.
  - **Alle** Adressregeln werden eine Bereichsprüfung auf der aufgelösten Binäradresse (Tabelle aus dem IANA-Register). IPv6 als Erlaubnisliste: nur 2000::/3 minus Sonderblöcke. Eingebettetes IPv4 wird herausgelöst und geprüft.
  - Damit entfällt das eigene Parsen von Dezimal-, Oktal- und Hex-Schreibweisen, denn `getaddrinfo` normalisiert sie.
  - Die Anfrage aus den geprüften Teilen neu bauen, damit sich zwei URL-Parser nicht uneinig sind.
  - Tests ergänzen: `127.1`, `0177.0.0.1`, `0x7f000001`, `127.0.0.1.`, `%31%32%37.0.0.1`, Vollbreitenziffern, `[::127.0.0.1]`, `[64:ff9b::c0a8:101]`, `[2002:c0a8:101::]`, `localhost.`.

### M2 – Die Downgrade-Regel in N5 ist nicht entscheidbar; NetGate kennt kein Update und keinen Bericht
- **Reviewer:** alle außer security (dort niedrig)
- **Stelle:** N5 (Z. 96), N6/N7, §7 (Z. 160)
- **Was falsch ist:**
  - Zum Zeitpunkt der Weiterleitung weiß niemand, ob das Ziel „ein Medien-Stream ist“.
  - N6 und N7 kennen weder JSON (GitHub-API, Worker) noch ZIP, und es gibt keine Größengrenze für die Update-ZIP.
  - GitHub leitet Release-Downloads seit 2025 auch auf `release-assets.githubusercontent.com` um. Die feste Hostliste würde den Updater brechen.
- **Korrektur am Plan:**
  - Die Entscheidung hängt an der Anfrageklasse aus K1: Downgrade nur für `stream` und `segment`.
  - NetGate-Profile mit Typen und Grenzen: `update` erlaubt JSON + ZIP bis etwa 50 MB auf den GitHub-Hosts inklusive `release-assets.githubusercontent.com`, `report` erlaubt POST an den Worker-Host.

### M3 – Erschöpfung von Ressourcen nicht abgedeckt
- **Reviewer:** security
- **Stelle:** N6 (Z. 97), S2 (Z. 107)
- **Was fehlt:**
  - gzip/br-Bomben (URLSession entpackt selbst);
  - Slowloris (ein Byte alle 19 s schlägt die 20-s-Regel);
  - Gesamtfrist für Kopfzeilen;
  - `EXT-X-TARGETDURATION` 0 oder riesig (Neuladen in Dauerschleife);
  - Segmente im Voraus (1000 × 4 MB = 4 GB);
  - ID3-Größe 256 MB;
  - Parser-Schleifen ohne Fortschritt;
  - Größe der PCM-Warteschlange;
  - Anzahl der Varianten.
- **Korrektur am Plan (N6 ergänzen):**
  - `Accept-Encoding: identity`; jedes andere `Content-Encoding` abweisen.
  - Kopfzeilen binnen 15 s vollständig.
  - Mindestdurchsatz nach dem Start (zum Beispiel ≥ 25 % der Nennbitrate über 30 s).
  - HLS-Neuladen zwischen 1 s und Zieldauer (höchstens 30 s).
  - Höchstens 3 Segmente voraus, höchstens 8 Varianten.
  - Jeder Parserdurchlauf muss Fortschritt machen.
  - Nur Streaming-APIs, nie den ganzen Body puffern.

### M4 – Die Textbereinigung ist unvollständig und gilt nur für `StreamTitle`
- **Reviewer:** security
- **Stelle:** S4 (Z. 109), S6, §6 (Z. 156)
- **Was fehlt:**
  - Zeichen: U+061C, Nullbreiten- und Formatzeichen (U+200B–200D, U+2060–2064, U+FEFF), U+2028/2029 (fälschen auch Logzeilen), U+FFF9–FFFB, Tag-Zeichen U+E0000–E007F, Zalgo-Fluten, NFC.
  - Weitere Quellen fremden Texts: `icy-name`/`icy-description`, `#EXTINF`, `Title1=`, alle radio-browser-Felder, `error.localizedDescription` in Hinweisen.
  - Das eigentliche Markdown-Risiko sind `LocalizedStringKey(serverText)`, `AttributedString(markdown:)` und `String(format: serverText)`.
- **Korrektur am Plan:**
  - Eine einzige Funktion `Sanitize.display(_:)` für jeden fremden Text (per Quelltext-Test erzwungen). Schritte: dekodieren → NFC → nur Kategorien L, M (höchstens 2 pro Grundzeichen), N, P, S → Leerraum zusammenfassen → ≤ 200 Grapheme und ≤ 800 Byte.
  - Fremder Text ist nie Formatstring oder Lokalisierungsschlüssel.
  - Dieselbe Funktion gilt vor dem Schreiben ins Log.

### M5 – Berichte und Log: Downloads-Ablage geht nicht, Hash ist umkehrbar, Hörverhalten kann abfließen
- **Reviewer:** codebase-details, security, zoom-out, design, implementation-readiness
- **Stelle:** §8.2 (Z. 188), A1, A5 (Z. 121), §3 (Z. 81)
- **Was falsch ist:**
  - Ohne `files.downloads.read-write` kann eine sandboxed App nicht nach `~/Downloads` schreiben. Der Mountpoint-Ausweg (`Reporter.swift:41–53`) schlägt fehl, und der Bericht geht verloren.
  - Den Log-Pfad `~/Library/Logs/Fona` gibt es in der Sandbox nicht. Tatsächlich liegt das Log unter `~/Library/Containers/<id>/Data/Library/Logs/Fona/Fona.log`; „gespiegelt“ ist undefiniert.
  - Ein ungesalzener Hash einer öffentlichen Stream-URL lässt sich über die rund 50 000 radio-browser-URLs zurückrechnen.
  - Sendernamen und Titel können politische oder religiöse Haltung verraten (DSGVO Art. 9).
  - Titel im Log gelangen ins Bericht-Repo und von dort in spätere Claude-Sitzungen. Das ist ein Kanal für Prompt-Injection, den jeder Streambetreiber steuern kann.
  - Mountpoint `anonymize()` ersetzt in der Sandbox den Container-Pfad, nicht `/Users/<name>`.
- **Korrektur am Plan:**
  - Den echten Log-Pfad nennen, „gespiegelt“ streichen, als Ausnahme zu SKILL.md vermerken. Rotation 2 × 1 MB, wiederholte Fehler drosseln.
  - Bericht-Ausweg: entweder das eine Recht `files.downloads.read-write` in A1 aufnehmen (Nutzerentscheidung) oder unter `Application Support/Fona/Reports/` ablegen und im Finder zeigen. Als Ausnahme zu SKILL.md:54 in §9 eintragen.
  - A5 neu fassen: **keine** URLs, Sendernamen oder Titel in Berichten und Logs. Nur Anfrageklasse, Schema, Fehlerklasse, Inhaltstyp, Hostkategorie. Wo nötig HMAC mit einem Schlüssel pro Installation. `/Users/<name>` vor dem Senden entfernen, mit Test.

### M6 – Goertzel-Parameter passen nicht zusammen
- **Reviewer:** codebase-details, design, implementation-readiness
- **Stelle:** §5.2 Stufe 1 (Z. 135)
- **Was falsch ist:**
  - 100 ms bei 48 kHz ergibt 10-Hz-Bins. Ein einzelner Goertzel bei 780 Hz erfüllt „± 20 Hz“ nicht.
  - „≥ 5 Fenster ohne Überlappung“ bei einem 0,6-s-Ton lässt kaum Spielraum.
  - „Anteil am Gesamtpegel“ ist nicht definiert (Mono-Downmix? RMS?).
- **Korrektur am Plan:**
  - Energie über 760–800 Hz (mehrere Bins oder Hann-Fenster, stärkster Bin).
  - 50 % Überlappung, insgesamt etwa 0,45 s Ton verlangen.
  - Das Maß genau definieren und angeben, wo 780 Hz gemessen wurde (Clip, FFT-Größe). P0-b kalibriert die Werte und trägt sie in `NewsProfile` ein.

### M7 – §5.1 behauptet mehr, als die Rohdaten zeigen
- **Reviewer:** codebase-details, design
- **Stelle:** §5.1 (Z. 126–129)
- **Was falsch ist:**
  - `dlf.log` beginnt um 11:02:00, schon mitten in den Nachrichten (`dlf.log:1`). Den Start um 11:00 und „0,7 s nach Sprachbeginn“ belegen die Daten nicht; einen Clip für 11:00 gibt es nicht.
  - Belegt sind: 11:30-Wechsel um 11:30:04 (`dlf.log:100–101`), Ende 11:05:06 und 11:35:05 (`dlf.log:12, 118`), kein Wechsel um 12:00 (`dlf.log:196–228`).
  - Nicht erwähnt: Der Titel wechselt alle 15–20 s zwischen zwei Formen, sowohl während der Nachrichten als auch außerhalb.
- **Korrektur am Plan:**
  - Zeile berichtigen: „11:30 gemessen; 11:00 nur Titel (Mitschnitt ab 11:02)“.
  - Den Wechselrhythmus festhalten, weil davon abhängt, wie schnell das Ende erkannt wird.
  - Die „4 s vor dem Titelwechsel“ an P0-b binden.

### M8 – Decoder und HLS sind unterspezifiziert
- **Reviewer:** codebase-details, design, implementation-readiness
- **Stelle:** §3 Decoder/HlsReader (Z. 66–68), S2
- **Was fehlt:**
  - HE-AAC: AudioFileStream meldet ohne `kAudioFileStreamProperty_FormatList` nur AAC-LC. Ergebnis: halbe Abtastrate bzw. dumpfer Klang ohne SBR.
  - Formatwechsel mitten im Stream, `#EXT-X-DISCONTINUITY` (Parser und Converter neu aufbauen, `kAudioFileStreamParseFlag_Discontinuity`).
  - ID3 je Packed-Audio-Segment entfernen.
  - LATM (TS-Streamtyp 0x11) ausdrücklich ablehnen.
  - Variantenwahl, Startposition an der Live-Kante, Neulade-Intervall.
  - Ablehnen ergänzen: `#EXT-X-SESSION-KEY`, `SAMPLE-AES`, riesige `EXT-X-BYTERANGE`.
- **Korrektur am Plan:** Diese Punkte in §3 und S2 aufnehmen.

### M9 – Selbsttest und `swift test` prüfen dasselbe doppelt
- **Reviewer:** zoom-out
- **Stelle:** §8.1 (Z. 168–173) gegen §8.2 (Z. 177–185)
- **Was falsch ist:** Angriffsliste, Nachrichtenlogik mit simulierter Uhr, Überblendung, Library und eigene Links stehen zweimal da. Es sind deterministische Prüfungen am selben Programm. Zwei Testsammlungen laufen mit der Zeit auseinander.
- **Korrektur am Plan:**
  - „Ein Prüfkatalog, zwei Aufrufer.“ Jede Prüfung steht einmal als Funktion im App-Ziel, wie in Mountpoint `SelfTest.swift`. `swift test` ruft denselben Katalog über eine dünne XCTest-Hülle auf (wie Mountpoint `SelfTestTests.swift`).
  - §8.1 ergänzt nur, was nicht in die App gehört: Fuzzing, Quelltext-Test, Lokalisierungsprüfung, die P0-Mitschnitte (urheberrechtlich geschützt, §11).
  - Das erfüllt weiterhin „ausführlich, testet alle Funktionen“ aus §2.

### M10 – Die „Fertig, wenn“-Kriterien sind nicht messbar
- **Reviewer:** implementation-readiness
- **Stelle:** §10 (Z. 199–206), §8.2
- **Was falsch ist:**
  - P5 („24-h-Test: jede Ausgabe erkannt“) hängt am Live-Programm und lässt sich nicht wiederholen.
  - P2 nennt keine Sender und keine Dauer.
  - P4 sagt nicht, wie „Barrierefreiheit geprüft“ wird.
  - P0 sagt nicht, welche Entscheidung jeder Spike liefern muss.
  - Für P1 ist unklar, wie N8 ohne die Parser aus P2 getestet wird.
  - Im Selbsttest: kein Schwellwert für die Überblendung, kein Verhalten ohne Netz (Schritte 2 und 10: rot oder übersprungen?).
- **Korrektur am Plan:**
  - P5: NewsWatcher auf den gespeicherten P0-b-Mitschnitten, 100 % Treffer, 0 Fehlalarme in 24 h, plus 2 h live. Ohne Mitschnitte wird der Test übersprungen.
  - P2: 3–5 benannte Sender, je 30 min ohne Aussetzer.
  - P4: Checklisten für VoiceOver, Tastatur und Kontrast.
  - Für jeden Spike die Ja/Nein-Frage nennen.
  - Den Schwellwert für die Überblendung als Zahl angeben; ohne Netz gilt „übersprungen“.

### M11 – Design-Quelle liegt außerhalb des Repos; Dateigrenzen fehlen
- **Reviewer:** implementation-readiness
- **Stelle:** §9 (Z. 191), §3
- **Was falsch ist:**
  - Der Canvas ist ein claude.ai-Link. Spätere Sitzungen können ihn eventuell nicht öffnen, und P4 hängt daran.
  - Es fehlen: Targets in `Package.swift`, Pfade unter `Sources/`, Ressourcen (String Catalog, Testdateien), Entitlements beider Programme, Info.plist-Schlüssel, Änderungen an `build-app.sh` (Helfer einbetten, Signierreihenfolge).
- **Korrektur am Plan:**
  - Den Canvas als HTML und PNGs nach `design/canvas/` exportieren und die Ansichten mit Größen und Zuständen auflisten (leer, Fehler, Menüleisten-Symbol).
  - Eine Dateitabelle pro Phase.

### M12 – Bestehenden Worker wiederverwenden und härten
- **Reviewer:** codebase-details, security
- **Stelle:** §8.2 (Z. 188), §11 (Z. 211)
- **Was falsch ist:**
  - Der vorhandene Worker bedient schon mehrere Apps über das Feld `product` (`worker/src/index.js:23`). Ein neuer Worker ist nicht nötig.
  - Unabhängig davon: Rohe IPs liegen als KV-Schlüssel, ein globales Tageslimit lässt sich missbrauchen, und vom Angreifer geschriebenes Markdown landet im Repo.
  - Mountpoints Reporter nutzt `URLSession.shared`, was der Quelltext-Test zu Recht anmahnen würde.
- **Korrektur am Plan:**
  - In P6 `"fona": "moritz-poth/fona-reports"` in `REPOS` eintragen und einen feingranularen Token nur für dieses Repo verwenden.
  - IPs mit Geheimnis hashen, Felder in Codeblöcken escapen, Tag-Zeichen entfernen.
  - Der Reporter läuft über NetGate (Profil `report`).

### M13 – Update-Schlüssel: nicht Mountpoints Schlüssel übernehmen
- **Reviewer:** codebase-details, security
- **Stelle:** §7 (Z. 161)
- **Was falsch ist:** `update-key.swift` nutzt den festen Schlüsselbund-Eintrag „Mountpoint update key“ (`update-key.swift:13`). Eine direkte Kopie würde Fona mit Mountpoints Schlüssel signieren. Ein Leck träfe dann beide Apps.
- **Korrektur am Plan:**
  - Eigener Eintrag „Fona update key“, neues Schlüsselpaar.
  - Schlüsselbund-Eintrag mit `WhenUnlockedThisDeviceOnly` plus Touch ID pro Signatur, Offline-Sicherung.
  - In §7 ausdrücklich nennen: Info.plist-Schlüssel `FonaRelease`, Asset `Fona-<version>.zip`, Tag `v<version>`, Test-Versionen, `.manual`-Marker, Ablauf bei Schlüsselverlust (wie `Updater.swift:46–72`).

---

## Niedrig

- **N1 – S7 „bei jedem Abspielen erneut geprüft“ (Z. 112):** Eine volle Probe mit 2 s Dekodierung verzögert den Start ohne Sicherheitsgewinn. Ersetzen durch: „durchläuft wie jede URL NetGate + N8“.
- **N2 – Doppelte Schleifenregeln (S1/S2, §8.1):** „Selbst einbindende Playlist“ ist durch „eine Ebene tief“ abgedeckt, Weiterleitungsschleifen durch „höchstens 5“. Die Sonderregel streichen. Falls sie bleibt: normalisierte URL vergleichen und die besuchten URLs über die ganze Kette merken.
- **N3 – Umfang (§6 Z. 153, §8.1 Z. 172, §8.2 Z. 186):**
  - „Umbenennen“ fehlt in §1. Entweder in §1 aufnehmen oder aus §6 streichen.
  - „Migration“ ist in 1.0 noch nicht nötig. Nur das Feld `schemaVersion` behalten (H10).
  - Selbsttest-Punkt 10 (Live-Hinweis) ist kein Funktionstest. Optional.
- **N4 – Quelltext-Test erweitern (Z. 88):** Außerhalb von NetGate zusätzlich verbieten: `NWConnection`, `CFStream`, `getaddrinfo`, `String(contentsOf:)`, `NSImage(contentsOf:)`, `AsyncImage`, `AVURLAsset`, `WKWebView`, jede zweite `URLSession(configuration:`, `engine.inputNode`.
- **N5 – Streuung (S1/S2):** Eine Playlist mit 100 Einträgen oder Segmente auf vielen Hosts machen Fona zum Anfrage-Verteiler mit der IP des Nutzers. Höchstens 3 Playlist-Einträge probieren, Segment-Hosts pro Stream begrenzen, optional bekannte Nicht-HTTP-Ports sperren.
- **N6 – Ringpuffer (Z. 140):** 15 s reichen. Nur anpassen, wenn P0-b andere Zeiten zeigt.
- **N7 – MenuBarExtra (§6):** Damit Einstellungen und Handbuch unter macOS 14 vorne erscheinen, braucht es `SettingsLink`/`openSettings` plus `NSApp.activate`. Im Plan vermerken.
- **N8 – Lokalisierung:** Mechanismus (String Catalog, `defaultLocalization`) und Sprachwahl (System oder Einstellung) nennen. „Beliebtheit“ als `clickcount` oder `votes` festlegen.
- **N9 – Datenverbrauch (§12 Z. 222):** Rechnerisch stimmt es (2 × 128 kbit/s ≈ 1,9 MB/min). Fürs Handbuch nützlicher: „etwa 115 MB pro Stunde, etwa 2,7 GB pro Tag bei Dauerbetrieb“.
- **N10 – Verlaufsregeln:** Wie werden eigene Sender und umbenannte Sender im Verlauf behandelt? Übernimmt ein Umbenennen den Verlaufseintrag?

---

## Was gut ist (laut Reviewern)

- NetGate als einzige Netzwerkstelle samt Quelltext-Test.
- Die Grenzen in N6, `Text(verbatim:)` in S4, Fuzzing der Parser, `.broken` in A3.
- Der Browser-Fallback beim Updater und die P0-Spikes vor dem Bau.
- Ed25519-Prüfung vor dem Entpacken, Prüfung von Bundle-ID und Releaseschlüssel, `codesign --verify --deep --strict`: deckt sich mit Mountpoint.
- Fakten, die stimmen: ICY-Block ≤ 4080 Byte, TS-Sync `0x47`/188 Byte, AudioFileStream kann ADTS, Ringpuffer ≈ 5,8 MB.

## Empfohlene Reihenfolge

1. **Vor P1 entscheiden:** K1 + K2 (NetGate auf `NWConnection`, Anfrageklassen), K3 (Selbsttest ohne Server), H2 und M1 in N3/N4/N10 einarbeiten.
2. **P0 erweitern:** P0-a nach K4/H1; neuer P0-f „NetGate-Transport + http-Stream + Shoutcast v1 + Proxy“; P0-d nur noch als Kontrolle.
3. **Plan ergänzen:** H4–H7 (Nachrichtenlogik, Zustände, Fehler, Audio-Graph), H10–H11 (Datenmodelle, radio-browser), M5 (Log/Bericht in der Sandbox).
4. Danach erneut prüfen lassen.
