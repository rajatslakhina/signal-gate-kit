// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "signal-gate-kit",
    // Two platforms, and the split of what proves each is deliberate.
    //
    // This package's own CI runs `swift build`/`swift test` on Linux (core
    // module only — SignalGateUI is behind `#if canImport(SwiftUI)`) and on
    // macOS, where SwiftUI does exist and the view code is genuinely
    // type-checked. Neither job compiles for iOS.
    //
    // The `.iOS(.v17)` claim is instead backed by the companion demo app's CI,
    // which builds an iOS app against this package for `generic/platform=iOS
    // Simulator`. That is a real check living in another repository, not an
    // unbacked assertion here.
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
