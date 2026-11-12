import Foundation

/// Live HLS (PLAN S2, §3): master → variant → media playlist; starts 3 segments before the live edge, reloads every
/// target duration (delta updates with `_HLS_skip=YES` when the server allows), fetches each segment through NetGate,
/// demuxes TS or strips the ID3 tag of packed audio, and emits whole frames through `FrameGuard`.
public enum HlsReader {
    public static let startBehindEdge = 3
    public static let maxSegmentHosts = 4

    public static func events(playlistURL: String, gate: NetGate = .shared) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    try await run(playlistURL, gate: gate, cont: cont)
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    static func fetchPlaylist(_ url: String, gate: NetGate) async throws -> (CheckedURL, HlsPlaylist) {
        let (r, data) = try await gate.fetch(url, .playlist)
        return (r.url, try HlsPlaylist.parse(data).get())
    }

    static func run(_ start: String, gate: NetGate, cont: AsyncThrowingStream<StreamEvent, Error>.Continuation) async throws {
        var (url, list) = try await fetchPlaylist(start, gate: gate)
        if case .master(let variants) = list {
            guard let v = HlsPlaylist.choose(variants), case .success(let next) = URLPolicy.check(v.uri, .playlist, relativeTo: url) else {
                throw Rejection.notAudio
            }
            (url, list) = try await fetchPlaylist(next.text, gate: gate)
        }
        guard case .media(var media) = list else { throw Rejection.notAudio }
        let mediaURL = url

        cont.yield(.bufferHint(2 * media.targetDuration))
        var nextSeq = media.segments[max(0, media.segments.count - startBehindEdge)].sequence
        var hosts = Set<String>()
        var guardian: FrameGuard?
        var lastTitle: String?
        var announced = false

        while true {
            try Task.checkCancellation()
            let todo = media.segments.filter { $0.sequence >= nextSeq }
            if let first = media.segments.first, nextSeq < first.sequence { nextSeq = media.segments[max(0, media.segments.count - startBehindEdge)].sequence }
            for seg in todo.prefix(startBehindEdge) {
                try Task.checkCancellation()
                nextSeq = seg.sequence + 1
                guard case .success(let segURL) = URLPolicy.check(seg.uri, .segment, relativeTo: mediaURL) else { continue }
                hosts.insert(segURL.host)
                guard hosts.count <= maxSegmentHosts else { throw Rejection.hostNotAllowed }
                let data: Data
                do { data = try await gate.fetch(segURL.text, .segment).1 } catch Rejection.httpStatus(404) { continue }

                // container: MPEG-TS or packed audio (ID3 + raw ADTS/MP3)
                var es = Data()
                var format: FrameGuard.Format?
                if Sniffer.isTS([UInt8](data.prefix(188 * 6))) {
                    var ts = TsDemuxer()
                    es = try ts.feed(data) + ts.flush()
                    format = ts.format
                } else {
                    let stripped = stripID3(data, titles: { t in
                        let clean = Sanitize.display(t)
                        if !clean.isEmpty, clean != lastTitle { lastTitle = clean; cont.yield(.title(clean)) }
                    })
                    if case .success(let k)? = Sniffer.sniff(stripped) { format = k == .mp3 ? .mp3 : k == .adts ? .adts : nil }
                    es = stripped
                }
                guard let format else { throw Rejection.notAudio }
                if !announced || guardian?.format != format || seg.discontinuity {
                    if announced { cont.yield(.discontinuity) }
                    cont.yield(.format(format))
                    guardian = FrameGuard(format: format)
                    announced = true
                }
                let frames = try guardian!.feed(es)
                if !frames.isEmpty { cont.yield(.frames(frames)) }
            }
            if media.ended && media.segments.allSatisfy({ $0.sequence < nextSeq }) { return }

            let gotNew = !todo.isEmpty
            let wait = gotNew ? media.targetDuration : max(1, media.targetDuration / 2)
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            var reload = mediaURL.text
            if media.canSkip { reload += (mediaURL.pathAndQuery.contains("?") ? "&" : "?") + "_HLS_skip=YES" }
            guard case .media(let fresh) = try await fetchPlaylist(reload, gate: gate).1 else { throw Rejection.notAudio }
            media = fresh
        }
    }

    /// Packed audio segments start with an ID3 tag (timestamp, sometimes a title in TIT2). Removes it.
    static func stripID3(_ d: Data, titles: (String) -> Void) -> Data {
        let b = [UInt8](d.prefix(10))
        guard b.count == 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return d }
        let size = Int(b[6] & 0x7F) << 21 | Int(b[7] & 0x7F) << 14 | Int(b[8] & 0x7F) << 7 | Int(b[9] & 0x7F)
        let total = 10 + size
        guard size <= Limits.maxID3Bytes, total <= d.count else { return Data() }
        return d.subdata(in: d.startIndex + total..<d.endIndex)
    }
}
