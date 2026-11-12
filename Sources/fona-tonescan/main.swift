// Developer tool: fona-tonescan <file.mp3> … – decodes local MP3 recordings and prints every news-tone detection
// (time into the file). Used to calibrate NewsProfile against the P0-b recordings.
import Foundation
import FonaCore

for path in CommandLine.arguments.dropFirst() {
    guard let data = FileManager.default.contents(atPath: path) else { print("cannot read \(path)"); continue }
    var g = FrameGuard(format: .mp3)
    let dec = DecoderCore(format: .mp3)
    let det = ToneDetector()
    var i = 0
    var hits: [String] = []
    while i < data.count {
        let n = min(65_536, data.count - i)
        let pcm = dec.decode((try? g.feed(data.subdata(in: i..<i + n))) ?? Data())
        for d in det.feed(pcm) {
            hits.append(String(format: "%.1fs (tone %.2fs)", Double(d.toneStartFrame) / DecoderCore.sampleRate, d.toneSeconds))
        }
        i += n
    }
    print("\((path as NSString).lastPathComponent): \(hits.isEmpty ? "–" : hits.joined(separator: ", "))")
}
