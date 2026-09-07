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
3. **Only two things may cap a version:** the macOS 13 deployment floor and the pinned Swift
   toolchain. Any other blocker — an API rename, a deprecation, a migration guide — is work
   to schedule, not a reason to pin back.
4. **Swift language mode 6** with strict concurrency from the first commit. Retrofitting
   `Sendable` is far more expensive than starting with it.
5. `swift-deps.yml` runs weekly and opens a PR when anything moves, so drift is visible in
   days rather than discovered in years.

## The toolchain pin

**Swift 6.1 / Xcode 16.3 minimum.** This is set by GRDB 7 and propagates to everything else,
including what contributors must install and which CI runner image works.

It is recorded in `.swift-version` and enforced in `swift-pr.yml`. Consequences:

- CI must run on **`macos-15` or newer**. The current Node workflow's `macOS-13` image cannot
  supply Xcode 16.3, so the Swift workflows use their own runner. The Node workflow is left
  alone.
- Contributors on an older Xcode will see confusing failures rather than a clear message,
  which is why the prerequisites section of `CONTRIBUTING.md` states the version and how to
  verify it before anything else.

If a future dependency conflicts with this pin, **GRDB is the thing to re-evaluate** — not
the macOS floor, and not the language mode.

## Current set

| Package | Version | Why | Notes |
|---|---|---|---|
| [swift-log](https://github.com/apple/swift-log) | 1.6+ | Structured logging backend-agnostic front end | Apple-maintained. Backed by an OSLog handler and a rotating file handler writing to the same path the Electron server uses, so `GET /api/v1/server/logs` keeps working |
| [swift-crypto](https://github.com/apple/swift-crypto) | 3.8+ | Ed25519 for token signing; X25519 + ChaCha20-Poly1305 + HKDF for the `sealed-v2` payload codec | Apple-maintained. Both consumers ship default-off |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.5+ | CLI flags for the server executable | Replaces `minimist` |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.0+ | SQLite for the app store and read-only `chat.db` | **Sets the toolchain floor.** Chosen over an ORM because Apple owns the `chat.db` schema and it changes per release — raw SQL behind typed request structs models that honestly. Task-cancellation-aware async access |
| [hummingbird](https://github.com/hummingbird-project/hummingbird) | 2.11+ | HTTP server for `/api/v1`, shared with the Socket.IO transport | Declares `.macOS(.v11)`, so **no conflict** with our floor. Chosen over Vapor: leaner binary, faster, modular. We need routing and middleware, not an ORM/auth/templating stack |
| HummingbirdTLS (in the hummingbird package) | 2.11+ | Terminating TLS on this server, for installs with no tunnel in front | Wraps the same child channel the websocket upgrade is built on, so one configuration covers `https://` and `wss://` — there is no way to end up with an encrypted API and a plaintext socket on one port. Brings `swift-nio-ssl`, which was already in the graph transitively |
| [hummingbird-websocket](https://github.com/hummingbird-project/hummingbird-websocket) | 2.7+ | Engine.IO's second transport, on the same port and the same channel as the REST API | Not optional in practice. Socket.IO clients open on polling and **upgrade**; a server that advertises the upgrade and cannot serve it makes every client wait out `upgradeTimeout` (30s) on every connect, and one that does not advertise it leaves every client on long-polling forever. Same project as the HTTP server, so no second NIO stack |
| [swift-websocket](https://github.com/hummingbird-project/swift-websocket) | 1.6+ | `WebSocketInboundStream` and `WebSocketOutboundWriter`, the stream types `SocketIOTransport` reads and writes the Engine.IO upgrade through | **Already in the graph** underneath hummingbird-websocket — this is a transitive dependency promoted to a declared one, so `Package.resolved` did not move when it was added. Declared because BBSocketIO imports it DIRECTLY: relying on the transitive path means a Hummingbird release that reorganises its own dependencies breaks this package for a reason nothing in the manifest hints at. Same project as the websocket server |
| [swift-http-types](https://github.com/apple/swift-http-types) | 1.6+ | `HTTPFields`, for the Socket.IO CORS headers | Apple-maintained. Also already in the graph underneath Hummingbird, and declared for the same reason as swift-websocket above |

## Deliberately not used

| Instead of | We use | Why |
|---|---|---|
| Vapor | Hummingbird | Vapor bundles an ORM, auth, templating and more that we do not need; it bulks the binary and slows compiles |
| `firebase-admin` equivalent | Direct REST + `swift-crypto` | No Swift Firebase Admin SDK exists. FCM HTTP v1 is a JWT exchange and a POST; Firestore config writes are one REST call |
| An ORM over `chat.db` | GRDB raw SQL + `SchemaProfile` | The schema is Apple's and version-dependent. TypeORM entities are why version branching is scattered through the current data layer |
| XPC for the helper transport | Unix domain socket | The injected dylib cannot own a Mach service name, and the Codable-based Swift XPC API is macOS 14+. See `.claude/docs/private-api.md` |
| `node-typedstream` equivalent | Hand-written decoder + `NSKeyedUnarchiver` | Both paths are pure Foundation — no native module, no rebuild step |
| `node-mac-contacts`, `node-mac-permissions` | `Contacts.framework`, `AXIsProcessTrusted…` | First-party frameworks. Also removes the `electron-rebuild` postinstall entirely |

## Vendored assets

Not everything in the graph is a `Package.swift` line. This one is a file in the repository,
which means `swift-deps.yml` **cannot see it** and will never open a PR when it moves — the
exact silent-drift failure the policy above exists to prevent. So it is recorded here by
hand, and going stale is a thing someone has to notice.

| Asset | Version | Where | Why |
|---|---|---|---|
| [`@scalar/api-reference`](https://github.com/scalar/scalar) `standalone.js` (MIT, 3.7 MB) | 1.67.0 | `Sources/BlueBubblesApp/Resources/APIDocs/` | Renders the OpenAPI document in the API Reference window. The alternative is hand-writing a JSON Schema renderer — `$ref` resolution, `allOf`/`oneOf` composition, nested object trees — and 3.7 MB of someone else's JavaScript is the smaller thing to own |

Fetched from `https://cdn.jsdelivr.net/npm/@scalar/api-reference@1.67.0/dist/browser/standalone.js`,
sha256 `d150e6d9ec333062cb15870704bb9eb6ec6fa99ce3fe5b164a53bc0470e838ee`.

**On upgrading it.** Scalar's embed configuration churns between versions, and several of its
defaults reach scalar.com. Measured on 1.67.0: `telemetry` defaults to `true`,
`withDefaultFonts` pulls 14 files from `fonts.scalar.com`, the search box posts what you type
to `api.scalar.com/vector/registry/search`, and `showDeveloperTools` defaults to `"localhost"`
— which is every install. `Resources/APIDocs/index.html` turns each of those off AND blocks
them again with a Content-Security-Policy, because the config keys are the half that can be
renamed. Two of them already have: `hideDownloadButton` is deprecated in favour of
`documentDownloadType`, and the top-level `agentEnabled` does nothing — "Ask AI" is switched
off by `agent: { disabled: true }` on the document config instead.

After bumping the version, reload the page and check the console: **a config key that stopped
working shows up as a CSP violation, not as a broken build.** That is the intended failure
mode — it fails closed and noisily — but nobody sees it unless they look.

## Deferred to later phases

Not yet declared in `Package.swift`, to keep the Phase 0 resolution surface small. Each is
added by the phase that needs it.

| Package | Phase | For |
|---|---|---|
| [swift-certificates](https://github.com/apple/swift-certificates) | 9 | Self-signed TLS certificates, replacing `node-forge` + `@peculiar/x509` |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 11 | App updates. Minimum deployment target is moving toward macOS 12 — still below our floor |
| [PhoneNumberKit](https://github.com/marmelroy/PhoneNumberKit) | 3 | E.164 normalisation for the contact address index. Verify its own deployment target on adoption |

`blurhash` has no dependency: the encoder is ~200 lines and gets ported directly rather than
pulling in a package for it.
