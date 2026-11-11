import Foundation

let decoderServiceName = "io.github.moritz-poth.fona.spike.decoder"

@objc protocol DecoderService {
    /// Feeds ADTS bytes; replies with interleaved Float32 stereo PCM at 48 kHz (possibly empty).
    func decode(_ bytes: Data, reply: @escaping (Data) -> Void)
    /// Test hook: kills the service process to check that the app recovers.
    func crash()
    /// Test hook: tries to reach the network and the home folder from inside the service.
    func probeRights(reply: @escaping (String) -> Void)
}
