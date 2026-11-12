import Foundation

/// What comes out of a station: whole audio frames and (sanitized) titles.
public enum StreamEvent: Sendable {
    case format(FrameGuard.Format)
    case frames(Data)
    case title(String)
}

public enum SourceError: Error, Equatable {
    case hlsNotYet  // shortcut: HLS reader arrives in P3
}

/// Opens a station URL: follows .pls/.m3u playlists (S1), detects the real format from the bytes (N8),
/// strips ICY metadata (S3), lets only valid frames through (S5) and sanitizes titles (S4).
public enum StreamSource {
    public static func open(_ url: String, gate: NetGate = .shared, depth: Int = 0) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let r = try await gate.open(url, .stream)
        var icy = r.head.icyMetaInt.flatMap(IcyDemuxer.init(metaInt:))
        var it = r.body.makeAsyncIterator()
        var head = Data()
        var titles: [String] = []
        var kind: Sniffer.Kind?
        // read until the bytes tell what this is (max 16 KB audio + one ID3 tag)
        while kind == nil {
            guard let piece = try await it.next() else { break }
            if icy != nil { let (a, t) = icy!.feed(piece); head += a; titles += t } else { head += piece }
            switch Sniffer.sniff(head) {
            case .success(let k)?: kind = k
            case .failure(let e)?: r.cancel(); throw e
            case nil: continue
            }
        }
        guard let kind else { r.cancel(); throw Rejection.notAudio }

        switch kind {
        case .plsPlaylist, .m3uPlaylist:
            while head.count <= Limits.plainPlaylistBytes, let piece = try await it.next() { head += piece }
            r.cancel()
            guard head.count <= Limits.plainPlaylistBytes, depth == 0 else { throw Rejection.notAudio }
            var lastError: Error = Rejection.notAudio
            for entry in PlaylistParser.entries(head).prefix(PlaylistParser.maxTries) {
                do { return try await open(entry, gate: gate, depth: 1) } catch { lastError = error }
            }
            throw lastError
        case .hlsPlaylist, .mpegTS:
            r.cancel()
            throw SourceError.hlsNotYet
        case .mp3, .adts:
            let format: FrameGuard.Format = kind == .mp3 ? .mp3 : .adts
            return AsyncThrowingStream { cont in
                let task = Task {
                    var guardian = FrameGuard(format: format)
                    var demux = icy
                    var lastTitle: String?
                    func publish(_ raw: [String]) {
                        for t in raw {
                            let clean = Sanitize.display(t)
                            if clean != lastTitle { lastTitle = clean; cont.yield(.title(clean)) }
                        }
                    }
                    do {
                        cont.yield(.format(format))
                        publish(titles)
                        let first = try guardian.feed(head)
                        if !first.isEmpty { cont.yield(.frames(first)) }
                        while let piece = try await it.next() {
                            try Task.checkCancellation()
                            var audio = piece
                            if demux != nil { let (a, t) = demux!.feed(piece); audio = a; publish(t) }
                            let frames = try guardian.feed(audio)
                            if !frames.isEmpty { cont.yield(.frames(frames)) }
                        }
                        cont.finish()
                    } catch {
                        cont.finish(throwing: error)
                    }
                    r.cancel()
                }
                cont.onTermination = { _ in task.cancel(); r.cancel() }
            }
        }
    }
}
