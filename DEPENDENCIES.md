# Dependencies

## Policy

**Take the newest stable version of everything, and compromise only where something concrete
forces it.**

The Electron server is the cautionary tale: it is pinned to Electron 25, Koa 2, TypeORM 0.3
and Firebase Admin 12, and several of those pins are now load-bearing enough that upgrading
any one of them is its own project. GitHub currently reports 309 Dependabot advisories on
the default branch. That is what deferred upgrades cost.

Rules:

1. **Newest stable major** at the time a phase is built. No pre-releases on the default
   branch unless a required feature exists only there, and then only with a tracking issue
   to move to the stable tag.
2. **Resolve when the phase is actually built**, not from a list written months earlier.
   This file records what was chosen and why; `Package.resolved` records the exact graph and
   is committed.
3. **Only two things may cap a version:** the macOS 14 (Sonoma) deployment floor and the pinned Swift
   toolchain. Any other blocker (an API rename, a deprecation, a migration guide) is work
   to schedule, not a reason to pin back.
4. **Swift language mode 6** with strict concurrency from the first commit. Retrofitting
   `Sendable` is far more expensive than starting with it.
5. `swift-deps.yml` runs weekly and opens a PR when anything moves, so drift is visible in
   days rather than discovered in years.

## The toolchain pin

**Swift 6.2 / Xcode 26 minimum.** Two floors meet here and the higher one wins. GRDB 7 needs
Swift 6.1 (Xcode 16.3). The app calls `glassEffect` and `GlassEffectContainer`, which only the
macOS 26 SDK declares, and `#available` does not help at compile time: the symbol has to exist
in the SDK. So the floor is the first Xcode carrying that SDK, and it propagates to what
contributors must install and which CI runner image works.

**A build's SDK stamp decides how the app LOOKS.** macOS applies the current design only to a
binary whose `LC_BUILD_VERSION` says it was linked against SDK 26 or later. Xcode 27's SwiftPM
writes the deployment target there instead (`sdk 14.0`), which draws the app with the macOS 14
sidebar and controls on every OS. `Tools/sdk-stamp.sh` passes the linker the right numbers
(`-platform_version`, with the deployment target read from `Package.swift`) and the packaging
scripts verify every bundled binary; see that file.

It is recorded in `.swift-version` and enforced in `swift-pr.yml`. Consequences:

- CI runs on **`macos-26`** and selects `Xcode_26.6.app` explicitly. The Node workflow's
  `macOS-13` image cannot supply any Xcode 26, so the Swift workflows use their own runner;
  the Node workflow is left alone. The Xcode is pinned rather than taken from the image's
  default so a runner update cannot silently change the SDK a release is stamped with.
- Contributors on an older Xcode will see confusing failures rather than a clear message,
  which is why the prerequisites section of `CONTRIBUTING.md` states the version and how to
  verify it before anything else.

If a future dependency conflicts with this pin, **GRDB is the thing to re-evaluate**, not
the macOS floor, and not the language mode.

## Current set

| Package | Version | Why | Notes |
|---|---|---|---|
| [swift-log](https://github.com/apple/swift-log) | 1.6+ | Structured logging backend-agnostic front end | Apple-maintained. Backed by an OSLog handler and a rotating file handler writing to the same path the Electron server uses, so `GET /api/v1/server/logs` keeps working |
| [swift-crypto](https://github.com/apple/swift-crypto) | 3.8+ | Ed25519 for token signing; X25519 + ChaCha20-Poly1305 + HKDF for the `sealed-v2` payload codec | Apple-maintained. Both consumers ship default-off |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.5+ | CLI flags for the server executable | Replaces `minimist` |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.0+ | SQLite for the app store and read-only `chat.db` | **Sets the toolchain floor.** Chosen over an ORM because Apple owns the `chat.db` schema and it changes per release; raw SQL behind typed request structs models that honestly. Task-cancellation-aware async access |
| [hummingbird](https://github.com/hummingbird-project/hummingbird) | 2.11+ | HTTP server for `/api/v1`, shared with the Socket.IO transport | Declares `.macOS(.v11)`, so **no conflict** with our floor. Chosen over Vapor: leaner binary, faster, modular. We need routing and middleware, not an ORM/auth/templating stack |
| HummingbirdTLS (in the hummingbird package) | 2.11+ | Terminating TLS on this server, for installs with no tunnel in front | Wraps the same child channel the websocket upgrade is built on, so one configuration covers `https://` and `wss://`: there is no way to end up with an encrypted API and a plaintext socket on one port. Brings `swift-nio-ssl`, which was already in the graph transitively |
| [hummingbird-websocket](https://github.com/hummingbird-project/hummingbird-websocket) | 2.7+ | Engine.IO's second transport, on the same port and the same channel as the REST API | Not optional in practice. Socket.IO clients open on polling and **upgrade**; a server that advertises the upgrade and cannot serve it makes every client wait out `upgradeTimeout` (30s) on every connect, and one that does not advertise it leaves every client on long-polling forever. Same project as the HTTP server, so no second NIO stack |
| [swift-websocket](https://github.com/hummingbird-project/swift-websocket) | 1.6+ | `WebSocketInboundStream` and `WebSocketOutboundWriter`, the stream types `SocketIOTransport` reads and writes the Engine.IO upgrade through | **Already in the graph** underneath hummingbird-websocket: this is a transitive dependency promoted to a declared one, so `Package.resolved` did not move when it was added. Declared because BBSocketIO imports it DIRECTLY: relying on the transitive path means a Hummingbird release that reorganises its own dependencies breaks this package for a reason nothing in the manifest hints at. Same project as the websocket server |
| [swift-http-types](https://github.com/apple/swift-http-types) | 1.6+ | `HTTPFields`, for the Socket.IO CORS headers | Apple-maintained. Also already in the graph underneath Hummingbird, and declared for the same reason as swift-websocket above |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.9+ | The app's updater: EdDSA-verified downloads, background installs, delta updates | A prebuilt xcframework, macOS 10.13+, no availability macros above our floor. Linked by the **BlueBubblesApp target only**: the CLI has nothing to relaunch and the appcast tool writes the feed without the framework. SwiftPM places the framework beside the binary and stops there, so `build-app.sh` and `dev-bundle.sh` copy it into `Contents/Frameworks` and the app target carries an `@executable_path/../Frameworks` rpath. Replaces electron-updater (Squirrel.Mac), which left quarantine on the bundle it installed and so needed notarization to relaunch; Sparkle strips it |
| [swift-nio](https://github.com/apple/swift-nio) | 2.65+ | `EventLoopGroup`, `ByteBuffer` and the channel types the socket transport and the TLS listener are built on | **Already in the graph** underneath Hummingbird; declared because several targets import it directly. Apple-maintained |
| [swift-certificates](https://github.com/apple/swift-certificates) | 1.0+ | Self-signed TLS certificates for the HTTPS listener, replacing `node-forge` + `@peculiar/x509` | Apple-maintained. Generates the certificate this server presents when no tunnel terminates TLS in front of it |
| [swift-asn1](https://github.com/apple/swift-asn1) | 1.0+ | The raw-bytes IP address in a certificate's SAN extension | Apple-maintained, and already underneath swift-certificates; declared because the certificate builder reaches for it directly |
| [async-http-client](https://github.com/swift-server/async-http-client) | 1.21+ | FCM and the Google APIs, spoken over REST | There is no Swift Firebase Admin SDK, so the push sink talks HTTP itself. Same NIO stack as the server, so no second event-loop implementation enters the graph |
| [PhoneNumberKit](https://github.com/PhoneNumberKit/PhoneNumberKit) | 5.0+ | E.164 normalisation for the contact address index and for every chat GUID this server constructs | **`PhoneNumberKit/PhoneNumberKit`, not `marmelroy/PhoneNumberKit`**: the project moved organisation and the old repository says so from inside the compiler, deprecating `PhoneNumberUtility()` with "no longer maintained here". Declares `.macOS(.v10_15)` with no availability macros, so its declared floor is its real one. Replaces google-libphonenumber; a national trunk prefix is why this is a library and not a string concatenation |

## Deliberately not used

| Instead of | We use | Why |
|---|---|---|
| Vapor | Hummingbird | Vapor bundles an ORM, auth, templating and more that we do not need; it bulks the binary and slows compiles |
| `firebase-admin` equivalent | Direct REST + `swift-crypto` | No Swift Firebase Admin SDK exists. FCM HTTP v1 is a JWT exchange and a POST; Firestore config writes are one REST call |
| An ORM over `chat.db` | GRDB raw SQL + `SchemaProfile` | The schema is Apple's and version-dependent. TypeORM entities are why version branching is scattered through the current data layer |
| XPC for the helper transport | Unix domain socket | The injected dylib cannot own a Mach service name, and the Codable-based Swift XPC API is macOS 14+. See `.claude/docs/private-api.md` |
| `node-typedstream` equivalent | Hand-written decoder + `NSKeyedUnarchiver` | Both paths are pure Foundation: no native module, no rebuild step |
| `node-mac-contacts`, `node-mac-permissions` | `Contacts.framework`, `AXIsProcessTrusted…` | First-party frameworks. Also removes the `electron-rebuild` postinstall entirely |

## Vendored assets

Not everything in the graph is a `Package.swift` line. This one is a file in the repository,
which means `swift-deps.yml` **cannot see it** and will never open a PR when it moves: the
exact silent-drift failure the policy above exists to prevent. So it is recorded here by
hand, and going stale is a thing someone has to notice.

| Asset | Version | Where | Why |
|---|---|---|---|
| [`@scalar/api-reference`](https://github.com/scalar/scalar) `standalone.js` (MIT, 3.7 MB) | 1.67.0 | `Sources/BlueBubblesApp/Resources/APIDocs/` | Renders the OpenAPI document in the API Reference window. The alternative is hand-writing a JSON Schema renderer (`$ref` resolution, `allOf`/`oneOf` composition, nested object trees), and 3.7 MB of someone else's JavaScript is the smaller thing to own |

Fetched from `https://cdn.jsdelivr.net/npm/@scalar/api-reference@1.67.0/dist/browser/standalone.js`,
sha256 `d150e6d9ec333062cb15870704bb9eb6ec6fa99ce3fe5b164a53bc0470e838ee`.

**On upgrading it.** Scalar's embed configuration churns between versions, and several of its
defaults reach scalar.com. Measured on 1.67.0: `telemetry` defaults to `true`,
`withDefaultFonts` pulls 14 files from `fonts.scalar.com`, the search box posts what you type
to `api.scalar.com/vector/registry/search`, and `showDeveloperTools` defaults to `"localhost"`,
which is every install. `Resources/APIDocs/index.html` turns each of those off AND blocks
them again with a Content-Security-Policy, because the config keys are the half that can be
renamed. Two of them already have: `hideDownloadButton` is deprecated in favour of
`documentDownloadType`, and the top-level `agentEnabled` does nothing; "Ask AI" is switched
off by `agent: { disabled: true }` on the document config instead.

After bumping the version, reload the page and check the console: **a config key that stopped
working shows up as a CSP violation, not as a broken build.** That is the intended failure
mode (it fails closed and noisily), but nobody sees it unless they look.

**Two things the page styles have no config key at all, and they fail silently rather than
closed.** `index.html` hides the "Generate MCP" affordance with `display: none`, and it lifts
the request-example picker out of the card footer with `order`, because Scalar renders it
below the code sample and `POST /api/v1/message/query` carries five samples that nothing else
announces. Both select on class names Scalar chose — `scalar-mcp-layer`,
`request-card-footer-addon`, `request-card-footer`, `scalar-card-header`,
`request-editor-section` — and a rename breaks them with no error anywhere: the page loads,
the MCP link comes back, the picker sinks. `APIDocsStylesheetTests` fails the build when a
class the stylesheet selects on is no longer in the bundle beside it, and when the footer
stops being gated on an operation having more than one example, which is what scopes the
reorder. It cannot tell you the rule still has the effect it was written for, so after a bump
open `POST /api/v1/message/query` and check the picker is above the curl rather than below it.

One specificity note, since it is the sort of thing a bump can flip back: the reorder's radius
reset carries `!important` because Scalar's own `.scalar-app .last\:rounded-b-\[inherit\]:last-child`
ties it on specificity and is injected later. Without it the card draws square corners at the
bottom and rounded ones through the middle of its body.

**The API client ("Try it") depends on two undocumented details of 1.67.0, and both are
version-sensitive.** `customFetch` is how every request is routed through the app instead of
being sent by the page (see `Views/APIDocsRelay.swift` for why that matters), and outside
Electron Scalar calls it with a `Request` object rather than `(url, init)` — `index.html`
normalizes both shapes, so a change there is survivable. The second is not: Scalar labels a
response by reading `new URL(response.url)`, and a `Response` built in JavaScript has an empty
`url`, so the shim defines the property onto it. Without that, every send fails with "Failed
to construct 'URL': Invalid URL" and the console shows nothing — so after a bump, press Send
once and check a response body appears: `APIDocsStylesheetTests` covers the class names the
page's own stylesheet depends on and nothing covers the bundle's request path.

## Deferred

Nothing. This section listed swift-certificates and PhoneNumberKit as "not yet declared, to
keep the Phase 0 resolution surface small" long after both had landed, which made the table
above read as the complete set when it was missing five of the fourteen packages. Both are in
**Current set** now, where anything that gets declared goes.

`blurhash` has no dependency: the encoder is ~200 lines and gets ported directly rather than
pulling in a package for it.
