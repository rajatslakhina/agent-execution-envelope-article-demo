// swift-tools-version:5.9
import PackageDescription

// Library only. The runnable demo lives in Demo.xcodeproj, which consumes this
// package through a local package reference. There is deliberately no
// .executableTarget here.
let package = Package(
    name: "AgentEnvelope",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AgentEnvelope", targets: ["AgentEnvelope"]),
    ],
    targets: [
        .target(name: "AgentEnvelope"),
        .testTarget(name: "AgentEnvelopeTests", dependencies: ["AgentEnvelope"]),
    ]
)
