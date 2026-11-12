// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Fona",
    platforms: [.macOS(.v14)],
    targets: [
        // everything that can be checked without UI: NetGate, parsers, check catalogue
        .target(name: "FonaAtomics", path: "Sources/FonaAtomics"),
        .target(name: "FonaCore", dependencies: ["FonaAtomics"], path: "Sources/FonaCore"),
        // the menu bar app and its decoder XPC service (bundled by scripts/build-app.sh)
        .executableTarget(name: "Fona", dependencies: ["FonaCore"], path: "Sources/Fona"),
        .executableTarget(name: "FonaDecoder", dependencies: ["FonaCore"], path: "Sources/FonaDecoder"),
        // developer tool: runs one URL through NetGate and prints what came back (live checks)
        .executableTarget(name: "fona-probe", dependencies: ["FonaCore"], path: "Sources/fona-probe"),
        .executableTarget(name: "fona-play", dependencies: ["FonaCore"], path: "Sources/fona-play"),
        // developer tool: decodes a local file through FrameGuard + DecoderCore (compare against ffmpeg)
        .executableTarget(name: "fona-decodecheck", dependencies: ["FonaCore"], path: "Sources/fona-decodecheck"),
        .executableTarget(name: "fona-tonescan", dependencies: ["FonaCore"], path: "Sources/fona-tonescan"),
        .testTarget(name: "FonaCoreTests", dependencies: ["FonaCore"], path: "Tests/FonaCoreTests"),
    ]
)
