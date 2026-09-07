// swift-tools-version: 6.1
//
// The send probe drives the real AppleScript send path against a real Messages.app.
//
// It is a SEPARATE executable rather than a test, and that is not a workaround — it is the
// only shape that can work. AppleScript's remote send waits on the CARBON event loop
// (`GetNextEventMatchingMask` -> `RunCurrentEventLoopInMode`), and that reply is delivered
// through a main event loop. An ordinary process has one. The `swift test` bundle host does
// not, so the identical call blocks forever there. See Tests/BBAppleScriptTests.
//
// Usage:
//   swift run --package-path Tools/send-probe send-probe 'iMessage;-;someone@example.com'

import PackageDescription

let package = Package(
    name: "send-probe",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "send-probe",
            dependencies: [
                .product(name: "BBAppleScript", package: "swift"),
                .product(name: "BBCore", package: "swift")
            ],
            path: "Sources/SendProbe"
        )
    ]
)
