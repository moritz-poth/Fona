import Foundation

/// Interface of the FonaDecoder XPC service (PLAN §3): the service has no network and no file access;
/// it receives compressed bytes and returns PCM. It runs `FrameGuard` again before Apple's decoders.
@objc public protocol FonaDecoderProtocol {
    /// Starts a new stream. `format`: 0 = MP3, 1 = ADTS.
    func open(format: Int, reply: @escaping (Bool) -> Void)
    /// Interleaved Float32 stereo 48 kHz PCM (as raw bytes) for the given compressed bytes; empty Data on error.
    func decode(_ bytes: Data, reply: @escaping (Data, Bool) -> Void)
}

public enum DecoderXPC {
    public static let serviceName = "io.github.moritz-poth.fona.decoder"
}

/// App side of the decoder service. Restarts transparently after a crash of the service (next call relaunches it;
/// the stream format is sent again).
public final class DecoderClient: @unchecked Sendable {
    private var connection: NSXPCConnection?
    private var format: FrameGuard.Format?
    private let lock = NSLock()
    public private(set) var restarts = 0

    public init() {}

    private func proxy() -> FonaDecoderProtocol? {
        lock.lock(); defer { lock.unlock() }
        if connection == nil {
            let c = NSXPCConnection(serviceName: DecoderXPC.serviceName)
            c.remoteObjectInterface = NSXPCInterface(with: FonaDecoderProtocol.self)
            c.interruptionHandler = { [weak self] in self?.interrupted() }
            c.invalidationHandler = { [weak self] in self?.interrupted() }
            c.resume()
            connection = c
        }
        return connection?.synchronousRemoteObjectProxyWithErrorHandler { _ in } as? FonaDecoderProtocol
    }

    private func interrupted() {
        lock.lock()
        if connection != nil { restarts += 1 }
        connection?.interruptionHandler = nil
        connection?.invalidationHandler = nil
        connection?.invalidate()
        connection = nil
        lock.unlock()
    }

    public func open(_ f: FrameGuard.Format) -> Bool {
        format = f
        var ok = false
        proxy()?.open(format: f == .mp3 ? 0 : 1) { ok = $0 }
        return ok
    }

    /// nil = the service failed twice in a row (PLAN §5: restart once, then give up); the caller ends the stream.
    public func decode(_ frames: Data) -> [Float]? {
        for _ in 0..<2 {
            lock.lock(); let needsOpen = connection == nil; lock.unlock()
            if needsOpen, let f = format { _ = open(f) }
            var result: [Float]?
            proxy()?.decode(frames) { data, ok in
                guard ok else { return }
                result = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
            if let result { return result }
            interrupted()  // don't wait for XPC's own callback (race): drop the connection now, reopen on retry
        }
        return nil
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        connection?.invalidationHandler = nil
        connection?.invalidate()
        connection = nil
    }
}
