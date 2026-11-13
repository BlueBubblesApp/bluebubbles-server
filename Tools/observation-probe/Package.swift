// swift-tools-version: 6.1
//
// The observation probe is a SEPARATE package, deliberately.
//
// It is investigation tooling, not product code: it gets injected into Messages.app, it
// links nothing from the server, and it should never end up in a shipped build by accident.
// Keeping it out of the main Package.swift makes that structural rather than a convention.
//
// Build and run it per docs/OBSERVATION_LADDER.md.

import PackageDescription

let package = Package(
    name: "ObservationProbe",
    platforms: [.macOS(.v14)],
    products: [
        // Dynamic, because DYLD_INSERT_LIBRARIES is the whole delivery mechanism.
        .library(name: "ObservationProbe", type: .dynamic, targets: ["ObservationProbe"])
    ],
    targets: [
        .target(
            name: "ProbeBootstrap"
        ),
        .target(
            name: "ObservationProbe",
            dependencies: ["ProbeBootstrap"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
