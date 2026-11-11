# Fona

macOS menu bar internet radio with automatic switch to Deutschlandfunk news. Plan, decisions and P0 results: `docs/PLAN.md` (German). Review: `docs/goldfish_review_report.md`.

## Rules
- **Security first** (user decision): every byte from a station, radio-browser or a user link is hostile. All network access goes through `Sources/FonaCore/NetGate/` – a test (`noNetworkOutsideNetGate`) fails on `URLSession`, `NWConnection`, `getaddrinfo`, `AVPlayer` … anywhere else. NetGate has no test or bypass modes.
- New parser or limit → add the hostile case to `CheckCatalog` (same catalogue runs in `swift test` and in the in-app self-test) and to the fuzz tests.
- Numbers from servers: digits only (`ResponseHead.digits`) – `Int("-5")` crashed the chunk decoder once (found by fuzzing).
- Own look (not the Ferry/Mountpoint look), German + English only. Other shared rules: `~/.claude/skills/moe-apps/SKILL.md`.
- `design/research/` holds Deutschlandfunk recordings: copyrighted, never commit.

## Build and test
- No Xcode on the dev Mac (Command Line Tools only, macOS 15.5): XCTest is missing, tests use **Swift Testing** (`import Testing`).
- `swift test` – check catalogue (~100 cases), source scan, fuzz (20 000 rounds each).
- `FONA_FUZZ=1 swift test --filter fuzz` – 1 000 000 rounds per parser (before a release).
- `FONA_LIVE=1 swift test --filter liveStream` – real stations over the internet.
- `swift run fona-probe stream <url>` – one URL through NetGate, prints head, sniffed format, titles.
- Spikes from P0 (throwaway prototypes): `spikes/p0a` (sandbox + updater helper), `p0c` (HLS TS demux), `p0f` (NWConnection client), `p0g` (XPC decoder).
