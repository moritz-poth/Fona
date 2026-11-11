// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Fona",
    platforms: [.macOS(.v14)],
    targets: [
        // everything that can be checked without UI: NetGate, parsers, check catalogue
        .target(name: "FonaCore", path: "Sources/FonaCore"),
        // developer tool: runs one URL through NetGate and prints what came back (live checks)
        .executableTarget(name: "fona-probe", dependencies: ["FonaCore"], path: "Sources/fona-probe"),
        .testTarget(name: "FonaCoreTests", dependencies: ["FonaCore"], path: "Tests/FonaCoreTests"),
    ]
)
