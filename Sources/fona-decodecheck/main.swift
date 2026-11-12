import Foundation
import FonaCore
let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
var g = FrameGuard(format: CommandLine.arguments[3] == "adts" ? .adts : .mp3)
let dec = DecoderCore(format: g.format)
var pcm = [Float]()
var i = 0
while i < data.count { let n = min(7000, data.count - i); pcm += dec.decode(try! g.feed(data.subdata(in: i..<i+n))); i += n }
FileManager.default.createFile(atPath: CommandLine.arguments[2], contents: pcm.withUnsafeBufferPointer { Data(buffer: $0) })
print("frames", pcm.count / 2, "dropped", g.droppedBytes, "errors", dec.errors)
