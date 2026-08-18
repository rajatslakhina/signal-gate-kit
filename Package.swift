// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "signal-gate-kit",
    // Only platforms CI actually builds are declared. The Linux job builds the
    // core module with swift build/test; the macOS job builds the demo app for
    // the iOS Simulator. Nothing here claims a platform nobody compiles.
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "SignalGate", targets: ["SignalGate"]),
        .library(name: "SignalGateUI", targets: ["SignalGateUI"]),
    ],
    targets: [
        // Pure-Foundation decision core. No UI, no networking, no model calls —
        // it consumes already-graded outcomes so it stays testable and hermetic.
        .target(name: "SignalGate"),
        // SwiftUI presentation layer. Every file is behind `#if canImport(SwiftUI)`
        // so the module still compiles (to nothing) on Linux CI.
        .target(name: "SignalGateUI", dependencies: ["SignalGate"]),
        .testTarget(name: "SignalGateTests", dependencies: ["SignalGate"]),
    ]
)
