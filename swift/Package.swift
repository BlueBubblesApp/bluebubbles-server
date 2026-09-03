// swift-tools-version: 6.1
// The tools version is pinned deliberately: GRDB 7 requires Swift 6.1 / Xcode 16.3.
// See DEPENDENCIES.md before changing it.

import PackageDescription

// Applied to every target. Strict concurrency is on from the first commit —
// retrofitting Sendable later is far more expensive than starting with it.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "BlueBubbles",
    platforms: [
        // macOS 14 (Sonoma).
        //
        // Raised from the originally-planned Ventura floor because Hummingbird 2.x gates its
        // entire public API behind `@available(macOS 14)` via an availability macro — its
        // manifest says `.macOS(.v11)`, which is what the plan originally read and which is
        // misleading. Read availability macros, not just `platforms:`, when checking a floor.
        .macOS(.v14)
    ],
    products: [
        .executable(name: "bluebubbles-server", targets: ["BlueBubblesServer"]),

        // What ships in BlueBubbles.app. The CLI above stays as its own product: a genuinely
        // headless server should not need a WindowServer connection at all, and CI runs it
        // without one.
        .executable(name: "BlueBubblesApp", targets: ["BlueBubblesApp"]),

        // Injected into Messages.app via DYLD_INSERT_LIBRARIES. Must be dynamic.
        .library(name: "BlueBubblesHelper", type: .dynamic, targets: ["BlueBubblesHelper"]),
        // The FaceTime helper is its own injectable dylib — see the target for why.
        .library(name: "BlueBubblesFaceTimeHelper", type: .dynamic, targets: ["BlueBubblesFaceTimeHelper"]),

        // Shared by the server and the injected helper. Kept as its own product so the
        // helper never links anything else from the server.
        .library(name: "BBPrivateAPIContract", targets: ["BBPrivateAPIContract"]),


        // Exposed so Tools/send-probe can drive the real send path. That check cannot live
        // in a test: AppleScript's remote send waits on the Carbon event loop, which the
        // `swift test` bundle host does not pump. See Tests/BBAppleScriptTests.
        .library(name: "BBAppleScript", targets: ["BBAppleScript"]),
        .library(name: "BBCore", targets: ["BBCore"]),

        // The development tools.
        //
        // Declared as PRODUCTS so the target can have a Swift module name and the command
        // can keep the name people type. They used to be executable targets called
        // `bb-openapi` and friends, which SwiftPM turns into modules named `bb_openapi` —
        // not a valid identifier anyone would choose, and the only targets in the package
        // that were not PascalCase. `swift run bb-openapi` is unchanged, which is what
        // CONTRIBUTING.md and both workflows invoke.
        .executable(name: "bb-openapi", targets: ["OpenAPITool"]),
        .executable(name: "bb-parity", targets: ["ParityTool"]),
        .executable(name: "bb-appcast", targets: ["AppcastTool"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.8.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.11.0"),
        // Engine.IO's second transport. Socket.IO clients open on polling and UPGRADE to
        // websocket; advertising the upgrade without being able to serve it makes every
        // client wait out `upgradeTimeout` (30s) before falling back, on every connect.
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.7.0"),
        // Used directly by the Private API transports, not only through Hummingbird: the
        // helper connections are raw TCP and Unix-domain sockets with their own framing.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // Self-signed certificate generation for the HTTPS listener.
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
        // For the raw-bytes IP address in a certificate's SAN extension.
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0"),
        // Firebase has no Swift Admin SDK, so FCM and the Google APIs are spoken over REST.
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
        // Replaces google-libphonenumber. Verified against the macOS 14 floor at adoption as
        // the dependency policy requires — platforms: .macOS(.v10_13), and, per the lesson
        // Hummingbird taught, NO availability macros, so its declared floor is its real one.
        .package(url: "https://github.com/marmelroy/PhoneNumberKit.git", from: "4.0.0"),
        // Both of the following are already in the graph underneath Hummingbird. They are
        // declared HERE because BBSocketIO imports them DIRECTLY — `HTTPFields` for the CORS
        // headers, and `WebSocketInboundStream`/`WebSocketOutboundWriter` for the Engine.IO
        // upgrade. Relying on the transitive path would mean a Hummingbird upgrade that
        // reorganised its own dependencies could break this package for a reason nothing in
        // the manifest hinted at.
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.6.0"),
        .package(url: "https://github.com/hummingbird-project/swift-websocket.git", from: "1.6.1")
    ],
    targets: [

        // MARK: - Foundation layer

        .target(
            name: "BBCore",
            swiftSettings: swiftSettings
        ),

        .target(
            name: "BBDiagnostics",
            dependencies: ["BBCore", .product(name: "Logging", package: "swift-log")],
            swiftSettings: swiftSettings
        ),

        .target(
            name: "BBPersistence",
            dependencies: [
                "BBCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Logging", package: "swift-log")
            ],
            // Agent guidance, not a build input. Declared so SwiftPM stops warning
            // about an unhandled file on every build.
            exclude: ["CLAUDE.md"],
            swiftSettings: swiftSettings
        ),

        .target(
            name: "BBSettings",
            dependencies: [
                "BBCore", "BBDiagnostics", "BBPersistence",
                // GRDB as well as BBPersistence: `SettingsStore` reaches the app database
                // through `AppDatabase`, but it still writes its own SQL — and
                // `LegacyConfigMigration` opens the ELECTRON server's database, a foreign
                // file `AppDatabase` has no business owning.
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: swiftSettings
        ),

        .target(
            name: "BBServiceKit",
            dependencies: [
                "BBCore", "BBSettings",
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: - macOS integration

        .target(
            name: "BBSystem",
            dependencies: [
                // The FindMy friends cache stores the contract's `FindMyFriend`, so the
                // helper's reply and the cached copy are one type rather than two that have
                // to be kept in step. The contract itself depends on nothing but Foundation.
                "BBCore", "BBServiceKit", "BBPrivateAPIContract",
                // The FaceTime recents API reads the macOS call log, a Core Data SQLite store
                // owned by another process — so it goes through the same read-only handle
                // chat.db does. See CallHistoryRepository.
                "BBPersistence",
                .product(name: "GRDB", package: "GRDB.swift"),
                // Self-signed certificates for the HTTPS listener, replacing node-forge
                // plus @peculiar/x509.
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: swiftSettings
        ),

        // The Shortcuts boundary. Group chat creation without the Private API, which
        // AppleScript cannot do on any supported macOS. Separate from BBAppleScript
        // because it shares nothing with it: a different tool, a different failure mode,
        // and a user-installed artefact rather than a compiled script.
        .target(
            name: "BBShortcuts",
            dependencies: [
                "BBCore",
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: swiftSettings
        ),

        .target(
            name: "BBAppleScript",
            dependencies: [
                "BBCore", "BBDiagnostics",
                .product(name: "PhoneNumberKit", package: "PhoneNumberKit"),
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: - iMessage data

        // An Objective-C exception barrier around NSUnarchiver, which is the only reader for
        // the typedstream format `message.attributedBody` uses. Separate target because
        // SwiftPM does not allow Swift and Objective-C in one, and @try/@catch exists only on
        // the Objective-C side — without it, one torn chat.db row terminates the server.
        .target(
            name: "BBTypedStreamShim"
        ),

        .target(
            name: "BBIMessage",
            dependencies: [
                "BBCore", "BBDiagnostics", "BBPersistence",
                "BBTypedStreamShim",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: swiftSettings
        ),

        .target(
            name: "BBContacts",
            dependencies: [
                "BBCore", "BBDiagnostics", "BBPersistence",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            swiftSettings: swiftSettings
        ),

        .target(
            name: "BBSerialization",
            dependencies: ["BBCore", "BBIMessage"],
            swiftSettings: swiftSettings
        ),

        // MARK: - Private API (server side of the boundary)

        // MARK: - Capabilities

        .target(
            name: "BBCapabilities",
            // The contract, for the helper-action enums: a capability names the actions it
            // covers with the real cases rather than strings, so a renamed one is a compile
            // error instead of a silently stale entry. The contract itself links nothing, so
            // this costs nothing.
            //
            // The dependency runs this way ONLY. Nothing here may end up in
            // BBPrivateAPIContract, whose whole constraint is that it is injected into
            // Messages.app and links nothing extra.
            dependencies: ["BBCore", "BBPrivateAPIContract"],
            swiftSettings: swiftSettings
        ),

        .target(
            name: "BBPrivateAPIContract",
            // Nothing but Foundation, deliberately: this type travels into Messages.app's
            // address space, so anything it links, the injected helper links too.
            path: "Helper/BBPrivateAPIContract",
            swiftSettings: swiftSettings
        ),

        .target(
            name: "BBPrivateAPI",
            dependencies: [
                "BBPrivateAPIContract", "BBServiceKit", "BBDiagnostics",
                "BBCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: - Delivery

        .target(
            name: "BBEvents",
            dependencies: [
                "BBCore", "BBSerialization", "BBDiagnostics",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: swiftSettings
        ),

        .target(
            name: "BBPushKit",
            dependencies: [
                "BBEvents", "BBSettings", "BBDiagnostics", "BBCore",
                "BBSerialization",
                .product(name: "Crypto", package: "swift-crypto"),
                // RS256 for the service-account JWT. RSA lives in _CryptoExtras rather than
                // Crypto, and its PEM initialiser reads the PKCS#8 key Google issues without
                // any unwrapping of our own.
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: swiftSettings
        ),

        // Managing external programs a service depends on: download, verify, install,
        // version-check. Depends on BBServiceKit because a tool is DECLARED in a manifest —
        // the machinery is here, the declaration is data, and that split is what lets a
        // third-party plugin have a managed binary too.
        .target(
            name: "BBTooling",
            dependencies: [
                "BBServiceKit", "BBDiagnostics", "BBCore",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "BBProxy",
            dependencies: [
                "BBServiceKit", "BBSystem", "BBCore",
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: - API surface

        .target(
            name: "BBAuth",
            dependencies: [
                "BBCore", "BBSettings", "BBPersistence", "BBDiagnostics",
                .product(name: "Crypto", package: "swift-crypto"),
                // scrypt for client-secret hashing, and Ed25519 lives in Crypto. See
                // EnrolledDevice for why scrypt rather than the Argon2id the plan named.
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                // `AccessControlStore` holds its own `DatabaseQueue`, as `SettingsStore` does.
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: swiftSettings
        ),

        .target(
            name: "BBHTTPAPI",
            dependencies: [
                // For `BBError`, which the mount and multipart failures conform to.
                "BBCore",
                // The route table, the middleware stages and the error envelope, and NOTHING
                // from the domain. This target used to declare BBIMessage, BBContacts,
                // BBPrivateAPI, BBAppleScript, BBEvents and BBServiceKit while importing none
                // of them — dead edges that quietly permitted exactly what the header of
                // HTTPServer.swift says must not happen. Controllers live in
                // BlueBubblesServerCore; that is where the domain is reachable.
                "BBSerialization", "BBAuth", "BBDiagnostics",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdCore", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: swiftSettings
        ),

        .target(
            name: "BBSocketIO",
            dependencies: [
                "BBEvents", "BBAuth", "BBSerialization", "BBCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdCore", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                // The websocket stream types and `HTTPFields`, imported directly by
                // SocketIOTransport. See the package dependency list for why they are
                // declared rather than taken transitively.
                .product(name: "WSCore", package: "swift-websocket"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: swiftSettings
        ),

        // The built-in services as DATA, and the rules for applying any manifest to the
        // settings store: the manifests, the tool descriptors, enablement, scoped settings
        // and the settings bridge. Out of the composition root so the app and the tests can
        // name a manifest without linking the wiring, and so a service's declaration is
        // something the root reads rather than something it owns.
        .target(
            name: "BBBuiltIns",
            dependencies: [
                "BBServiceKit", "BBSettings", "BBDiagnostics",
                // The LAN connection method lists this Mac's interfaces in its own form.
                "BBSystem",
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: swiftSettings
        ),

        // FaceTime as a subsystem: link minting, hand-off tracking and cleanup. Its own
        // target because it needs the Private API runtime (`BBPrivateAPI`), which sits above
        // `BBSystem`, and because it is a coordinator with its own state rather than a
        // domain interface over chat.db — `BBInterfaces` names it and does not own it.
        .target(
            name: "BBFaceTime",
            dependencies: [
                "BBDiagnostics", "BBPrivateAPI", "BBPrivateAPIContract", "BBSettings", "BBSystem",
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: - Composition root

        // The wiring, as a LIBRARY.
        //
        // SwiftPM cannot test an executable target, and the composition root is precisely
        // the thing worth testing — it is where "this route is not registered by default"
        // and "these services start in this order" are decided. The executable below is a
        // thin shell over it.
        // The domain layer — see the dependency list for what it deliberately omits.
        .target(
            name: "BBInterfaces",
            dependencies: [
                // The domain layer: what an operation MEANS, independent of how it was asked
                // for. Deliberately does NOT depend on BBHTTPAPI — it throws `InterfaceError`
                // and the projection onto status codes lives one target up. That absence is
                // the point of this target existing, and the compiler now enforces it.
                "BBCapabilities", "BBIMessage", "BBContacts", "BBSerialization", "BBPersistence",
                "BBPrivateAPI", "BBPrivateAPIContract", "BBAppleScript", "BBShortcuts",
                "BBSystem", "BBSettings", "BBPushKit", "BBEvents", "BBDiagnostics",
                // `Capabilities.swift` names the FaceTime coordinator. The auth, tooling and
                // update modules it used to name for three handler-only protocols are not
                // here any more: those protocols live in `BBHandlers/HandlerCapabilities`.
                "BBFaceTime",
                "BBCore",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            // Agent guidance, not a build input. Declared so SwiftPM stops warning
            // about an unhandled file on every build.
            exclude: ["CLAUDE.md"],
            swiftSettings: swiftSettings
        ),

        // The HTTP controllers, and the capability protocols that say what one may reach.
        //
        // Sits between the domain and the composition root so that "a handler must not touch
        // a repository directly" is a compile error rather than a review comment.
        .target(
            name: "BBHandlers",
            dependencies: [
                "BBInterfaces", "BBFaceTime",
                "BBHTTPAPI", "BBSerialization", "BBAuth", "BBSettings", "BBIMessage",
                "BBContacts", "BBPrivateAPI", "BBPrivateAPIContract", "BBSystem",
                "BBDiagnostics", "BBEvents", "BBPushKit", "BBUpdates",
                "BBPersistence",
                .product(name: "Logging", package: "swift-log")
            ],
            // Agent guidance, not a build input. Declared so SwiftPM stops warning
            // about an unhandled file on every build.
            exclude: ["CLAUDE.md"],
            swiftSettings: swiftSettings
        ),

        // The composition root: builds the graph, owns AppContext, registers the services.
        .target(
            name: "BlueBubblesServerCore",
            dependencies: [
                "BBInterfaces", "BBHandlers", "BBBuiltIns", "BBFaceTime",
                "BBTooling",
                "BBServiceKit", "BBSettings", "BBDiagnostics", "BBHTTPAPI", "BBSocketIO",
                "BBEvents", "BBPushKit", "BBProxy", "BBIMessage", "BBContacts",
                "BBPrivateAPI", "BBPrivateAPIContract", "BBSystem",
                "BBShortcuts",
                "BBAuth", "BBSerialization", "BBPersistence", "BBCore",
                .product(name: "Logging", package: "swift-log"),
                // The router and its channel types. Reached directly here — the composition
                // root is what mounts the router onto a listener — as well as through
                // BBHTTPAPI.
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdCore", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
                // TLS wraps the same channel the websocket upgrade uses, so both surfaces
                // are covered by one configuration rather than two.
                .product(name: "HummingbirdTLS", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            // Agent guidance, not a build input. Declared so SwiftPM stops warning
            // about an unhandled file on every build.
            exclude: ["CLAUDE.md"],
            swiftSettings: swiftSettings
        ),

        .executableTarget(
            name: "BlueBubblesServer",
            dependencies: [
                "BlueBubblesServerCore",
                // The CLI builds a context before handing it to the composition root, so it
                // names these types itself rather than reaching them through the library.
                "BBAuth", "BBDiagnostics", "BBPersistence", "BBServiceKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: - Injected helper
        //
        // Runs inside Messages.app. Depends on BBPrivateAPIContract and nothing else —
        // it must not pull server code into another process's address space.

        // Four lines of C, because Swift cannot declare a dylib constructor and something
        // has to run when Messages.app loads us — it will never call in on its own.
        .target(
            name: "HelperBootstrap",
            path: "Helper/HelperBootstrap"
        ),
        // The FaceTime helper's constructor, with its own symbol so both dylibs can link into
        // one test binary. See Helper/HelperBootstrapFaceTime/bootstrap.c.
        .target(
            name: "HelperBootstrapFaceTime",
            path: "Helper/HelperBootstrapFaceTime"
        ),
        // The Objective-C exception barrier and NSInvocation bridge. Swift can do neither,
        // and an uncaught ObjC exception inside Messages.app terminates the user's Messages.
        .target(
            name: "HelperObjC",
            path: "Helper/HelperObjC"
        ),

        // Host-agnostic plumbing shared by BOTH injected helpers — the Messages one and the
        // FaceTime one. `IMCoreRuntime` (safe dynamic dispatch against private classes) and
        // `HelperSocketClient` (the length-prefixed socket transport + protocol) are identical
        // whichever app they run in, so they live here rather than being duplicated or forcing
        // one helper to link the other.
        .target(
            name: "HelperShared",
            dependencies: ["BBPrivateAPIContract", "HelperObjC"],
            path: "Helper/HelperShared",
            swiftSettings: swiftSettings
        ),

        .target(
            name: "BlueBubblesHelper",
            // HelperObjC arrives through HelperShared, which is what owns the runtime shim.
            dependencies: ["BBPrivateAPIContract", "HelperBootstrap", "HelperShared"],
            path: "Helper/BlueBubblesHelper",
            swiftSettings: swiftSettings
        ),

        // The FaceTime helper. A SEPARATE dylib, injected into FaceTime.app rather than
        // Messages.app, because TelephonyUtilities' call machinery is registered with the call
        // daemons by FaceTime.app and traps in any other host. Same paradigms as the Messages
        // helper — bootstrap constructor, socket client, runtime shim — reached through
        // `HelperShared`. It provides its own `bluebubbles_helper_main`; each dylib resolves
        // the constructor's symbol to its own copy.
        .target(
            name: "BlueBubblesFaceTimeHelper",
            dependencies: ["BBPrivateAPIContract", "HelperBootstrapFaceTime", "HelperObjC", "HelperShared"],
            path: "Helper/BlueBubblesFaceTimeHelper",
            swiftSettings: swiftSettings
        ),

        // MARK: - Tests

        .testTarget(
            name: "BBCapabilitiesTests",
            dependencies: ["BBCapabilities", "BBPrivateAPIContract"],
            swiftSettings: swiftSettings
        ),

        .testTarget(
            name: "BBShortcutsTests",
            dependencies: ["BBShortcuts"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "BBCoreTests",
            dependencies: ["BBCore"],
            swiftSettings: swiftSettings
        ),

        .testTarget(
            name: "BBSettingsTests",
            dependencies: [
                "BBSettings", "BBPersistence", "BBDiagnostics", "BBCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            swiftSettings: swiftSettings
        ),

        .testTarget(
            name: "BBServiceKitTests",
            dependencies: ["BBServiceKit", "BBSettings"],
            swiftSettings: swiftSettings
        ),

        // Rate limiting behind a tunnel is the change most likely to cause an outage rather
        // than prevent one, so its tests gate CI like any other.
        .testTarget(
            name: "BBAuthTests",
            dependencies: [
                "BBAuth", "BBSettings", "BBPersistence", "BBDiagnostics", "BBCore",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            swiftSettings: swiftSettings
        ),

        .testTarget(
            name: "BBContactsTests",
            dependencies: [
                "BBContacts", "BBPersistence",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            swiftSettings: swiftSettings
        ),

        // The wire format IS the compatibility contract, so its invariants are asserted
        // rather than assumed: absent-vs-null, epoch-millisecond dates, the frozen renames,
        // and the attributedBody decoder that stands between a Ventura message and having no
        // text at all.
        .testTarget(
            name: "BBSerializationTests",
            dependencies: [
                "BBSerialization", "BBIMessage", "BBCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            swiftSettings: swiftSettings
        ),

        // The wiring. What the composition root is responsible for is exactly the thing
        // no unit test of a module can check: which routes exist, which services start, and
        // in what order.
        .testTarget(
            name: "CompositionTests",
            dependencies: [
                "BBShortcuts",
                "BlueBubblesApp",
                // The three targets the composition root is now split across. Reaching all of
                // them from one suite is expected: what this suite tests IS the wiring.
                "BlueBubblesServerCore", "BBBuiltIns", "BBFaceTime", "BBInterfaces", "BBHandlers",
                "BBHTTPAPI", "BBSocketIO", "BBAuth", "BBEvents",
                // `RouteRegistrationTests` compares the generated catalog against what the
                // composition root actually mounts, which needs both sides in one suite.
                "BBOpenAPI",
                "BBSettings", "BBServiceKit", "BBTooling", "BBPushKit", "BBPersistence",
                "BBDiagnostics", "BBSerialization", "BBCore",
                // For the one-method `AppleScriptRunning` seam. `SendFailureTests` drives a
                // real send down the AppleScript branch with a runner that fails, which is
                // the only way to prove the backend's error becomes an `IMessageError`
                // without standing up the 64-method Private API protocol.
                "BBAppleScript",
                "BBContacts", "BBIMessage", "BBPrivateAPIContract", "BBSystem",
                // For `SendShapeTests`, which diffs the send response against the recorded
                // reference fixture. The send routes are deny-listed in the parity replay,
                // so this is the only place that comparison can happen.
                "BBParity",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: swiftSettings
        ),

        // System integration: permissions, certificates, and the tunnel supervisor.
        // The read path against a real SQLite chat.db. See ChatDatabaseFixture — the SQL is
        // the thing under test, so a mock repository would prove nothing.
        .target(
            name: "BBParity",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "BBUpdates",
            dependencies: [
                "BBSerialization", "BBCore",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: swiftSettings
        ),
        // The SwiftUI application.
        //
        // A SwiftPM executable rather than an Xcode project target: the repository is
        // SwiftPM-based, `@main struct App` needs no project file, and Packaging/build-app.sh
        // wraps the product in the bundle. An .xcodeproj here would be a second, diverging
        // description of the same build.
        .executableTarget(
            name: "BlueBubblesApp",
            dependencies: [
                "BlueBubblesServerCore", "BBBuiltIns", "BBFaceTime", "BBInterfaces", "BBSettings",
                "BBSystem", "BBAuth", "BBCapabilities",
                "BBServiceKit", "BBDiagnostics", "BBUpdates", "BBSerialization",
                // The Private API status card and the FaceTime maintenance screen name
                // `PrivateAPIRuntime.StartOutcome` and the contract's reply types directly.
                "BBPrivateAPI", "BBPrivateAPIContract",
                // Guided Firebase provisioning runs in-process; see FirebaseSetupModel.
                "BBPushKit",
                // The managed-tool rows drive ToolManager directly.
                "BBTooling",
                // The group chat settings card installs and tests the Shortcut, and names
                // its manager and the shortcut's own name.
                "BBShortcuts",
                // The contacts screen renders `ContactRecord` values rather than the wire
                // JSON, so the record type has to be nameable here.
                "BBContacts",
                // For the webhook event vocabulary: the picker offers what
                // `EventName.webhookSubscribable` declares rather than a second list of
                // strings that can drift from the events actually emitted.
                "BBEvents",
                // The API reference window generates the OpenAPI document in-process, off
                // the same RouteCatalog the router is built from. See APIDocsView — the
                // committed docs/api/openapi.json is a CI artifact and deliberately not
                // what the viewer reads.
                "BBOpenAPI",
                "BBCore",
                .product(name: "Logging", package: "swift-log")
            ],
            resources: [
                // Scalar, vendored. `.copy` and not `.process`: this is a third-party
                // bundle that must reach the app byte-for-byte, and the directory layout
                // is what `loadFileURL(_:allowingReadAccessTo:)` scopes access to.
                .copy("Resources/APIDocs")
            ],
            swiftSettings: swiftSettings
        ),
        // MARK: - API documentation

        // Emits the OpenAPI document from the route table, and measures fixture coverage.
        //
        // Its own target rather than part of BBHTTPAPI: nothing the server does at runtime
        // depends on it, and the server binary should not carry a document generator. It
        // depends on BBHTTPAPI (for the table) and nothing else that BBHTTPAPI does not
        // already pull in.
        .target(
            name: "BBOpenAPI",
            dependencies: ["BBHTTPAPI", "BBAuth", "BBSerialization"],
            // Inferred payload schemas, generated by `bb-openapi infer-schemas` and
            // committed. A RESOURCE rather than a read of Fixtures/ because the app renders
            // this document too, and the corpus is not in the app bundle. See FixtureSchemas.
            resources: [.copy("Resources/schemas.json")],
            swiftSettings: swiftSettings
        ),

        .executableTarget(
            name: "OpenAPITool",
            dependencies: [
                "BBOpenAPI",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            swiftSettings: swiftSettings
        ),

        .executableTarget(
            name: "ParityTool",
            dependencies: [
                "BBParity",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "AppcastTool",
            dependencies: [
                "BBUpdates", "BBCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            swiftSettings: swiftSettings
        ),
        // The helper's dispatch machinery. The IMCore call sites cannot be tested without
        // Messages.app and SIP disabled; the runtime underneath them can be, and that is
        // where a mistake terminates the user's Messages rather than failing a request.
        .testTarget(
            name: "HelperTests",
            dependencies: ["BlueBubblesHelper", "BBPrivateAPIContract", "HelperShared"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "BBParityTests",
            dependencies: ["BBParity"],
            swiftSettings: swiftSettings
        ),
        // The managed-tool machinery. Driven against real files and real archives rather than
        // a mocked filesystem: the things worth testing here are what `tar` produces, what a
        // symlink swap does, and whether a digest mismatch is caught — none of which a double
        // would exercise.
        .testTarget(
            name: "BBToolingTests",
            dependencies: ["BBTooling", "BBServiceKit", "BBDiagnostics", "BBCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "BBUpdatesTests",
            dependencies: [
                "BBUpdates", "BBSerialization", "BBCore",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "BBIMessageTests",
            dependencies: [
                "BBIMessage", "BBPersistence", "BBCore", "BBSerialization",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            // Real Apple schemas, one database per supported macOS release, generated by
            // Tools/chatdb-fixtures/generate.py. Committed rather than generated at test
            // time: the generator is deterministic and needs Python, which the Swift test
            // run should not depend on. `SchemaProfileReadTests` reads them.
            resources: [.copy("ChatDBFixtures")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "BBSystemTests",
            dependencies: [
                "BBSystem", "BBProxy", "BBServiceKit", "BBCore",
                "BBPrivateAPIContract",
                // The call-history tests build a synthetic CallHistoryDB to read back.
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "X509", package: "swift-certificates")
            ],
            swiftSettings: swiftSettings
        ),

        // The alternate payload codecs. `sealed-v2` is verified by decrypting what it
        // produced and by proving a tampered envelope fails closed — a codec checked only
        // against itself proves nothing.
        .testTarget(
            name: "BBCodecTests",
            dependencies: [
                "BBEvents", "BBSerialization",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            swiftSettings: swiftSettings
        ),

        // Push. The JWT and the Firebase security rules are the two things here that fail
        // silently and remotely, so both are pinned hard.
        .testTarget(
            name: "BBPushKitTests",
            dependencies: ["BBPushKit", "BBSettings"],
            swiftSettings: swiftSettings
        ),

        // The helper transports. The legacy wire format is a compatibility contract with a
        // binary we do not build, so its decoding rules are pinned rather than trusted.
        .testTarget(
            name: "BBPrivateAPITests",
            dependencies: [
                "BBPrivateAPI", "BBPrivateAPIContract", "BlueBubblesHelper",
                "BlueBubblesFaceTimeHelper", "HelperShared",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ],
            swiftSettings: swiftSettings
        ),

        // The send path that works with SIP enabled, plus the macOS 26 chat-GUID migration.
        .testTarget(
            name: "BBAppleScriptTests",
            dependencies: ["BBAppleScript", "BBCore"],
            swiftSettings: swiftSettings
        ),

        // Replays recorded fixtures against the Swift server and diffs strictly in both
        // directions. This is what enforces the compatibility contract; see
        // See `.claude/docs/decisions.md`.
        .testTarget(
            name: "CompatibilityTests",
            dependencies: [
                "BBParity", "BBHTTPAPI",
                // The replay mounts the REAL router over the real handler registry, which
                // means it needs the composition root. A hand-rolled router would prove
                // that a hand-rolled router matches the fixtures.
                "BlueBubblesServerCore", "BBHandlers", "BBInterfaces", "BBAuth", "BBEvents",
                "BBSettings", "BBSerialization", "BBPersistence", "BBIMessage", "BBContacts",
                "BBSocketIO", "BBTooling", "BBSystem", "BBServiceKit", "BBDiagnostics",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Logging", package: "swift-log")
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),

        // The property the extension seam rests on — a slow subscriber must not delay
        // message detection — is asserted here rather than assumed.
        .testTarget(
            name: "BBEventsTests",
            dependencies: ["BBEvents", "BBSerialization"],
            swiftSettings: swiftSettings
        ),

        // The generated document and the coverage report. What is asserted here is what
        // silently rots otherwise: that operation IDs stay unique as routes are added, that
        // the output is byte-stable across runs, and that every additive group reaches the
        // catalog rather than being quietly undocumented.
        .testTarget(
            name: "BBOpenAPITests",
            dependencies: ["BBOpenAPI", "BBHTTPAPI", "BBSerialization"],
            swiftSettings: swiftSettings
        ),

        // `ProtocolTests` used to hold both of the following. It was one target covering two
        // modules, which is how "where does this test go" stopped having an answer — see
        // CompositionTests above.
        .testTarget(
            name: "BBHTTPAPITests",
            dependencies: ["BBHTTPAPI"],
            swiftSettings: swiftSettings
        ),

        .testTarget(
            name: "BBSocketIOTests",
            dependencies: [
                "BBSocketIO", "BBSerialization", "BBAuth", "BBEvents", "BBSettings", "BBCore"
            ],
            // Recorded Engine.IO/Socket.IO frames and typedstream payloads, diffed against
            // what this implementation produces.
            resources: [.copy("ProtocolFixtures")],
            swiftSettings: swiftSettings
        ),

        .testTarget(
            name: "BBHandlersTests",
            // Beyond the handlers themselves: `BBIMessage` and `BBSystem` for the
            // sticker-library tests (the row types come from the repository, the MIME
            // derivation from `FileTypes`), and `BBInterfaces` plus
            // `BBPrivateAPIContract` for the app-balloon refusal, which is interface
            // logic checked against the Polls bundle id in the contract.
            dependencies: [
                "BBHandlers", "BBHTTPAPI", "BBSerialization", "BBIMessage", "BBSystem",
                "BBInterfaces", "BBPrivateAPIContract",
            ],
            swiftSettings: swiftSettings
        ),

        // The app layer had NO test target of its own; its tests lived in CompositionTests
        // alongside the wiring assertions, which is why the largest module in the package
        // read as untested.
        .testTarget(
            name: "BlueBubblesAppTests",
            dependencies: [
                "BlueBubblesApp", "BlueBubblesServerCore", "BBBuiltIns", "BBHandlers", "BBInterfaces",
                "BBAuth", "BBCore", "BBDiagnostics", "BBEvents", "BBSerialization",
                "BBServiceKit", "BBSettings", "BBSystem"
            ],
            swiftSettings: swiftSettings
        )
    ]
)
