# BlueBubbles Server: Swift

A native Swift macOS server and app that reads the local iMessage database, serves an HTTP and
Socket.IO API to BlueBubbles clients, and drives Messages.app for sending.

Requires **macOS 14 (Sonoma)** or newer.

- **Working on it:** [`CLAUDE.md`](CLAUDE.md) routes to the architecture, database, API and
  decision documents.
- **Getting set up:** [`CONTRIBUTING.md`](CONTRIBUTING.md)
- **Dependencies and the toolchain pin:** [`DEPENDENCIES.md`](DEPENDENCIES.md)

## The one rule

Client compatibility outranks everything else, including security hardening. A
default-configured Swift server must present the same route table, the same response
envelopes, and the same event payloads as the Node server it replaces. Anything that would
require a client to behave differently ships behind a setting or is deferred.

`Tests/CompatibilityTests` enforces this mechanically by diffing recorded fixtures **strictly in
both directions**: an added key fails the same as a missing one.

## Layout

| Path | What it is |
|---|---|
| `Sources/BBCore` | Domain primitives, error protocol, retry/debounce helpers |
| `Sources/BBDiagnostics` | Structured logging and the alert centre, kept deliberately separate |
| `Sources/BBSettings` | Typed setting descriptors, Keychain-backed secrets, layered providers |
| `Sources/BBServiceKit` | Service protocol, registry, dependency graph, supervision |
| `Sources/BBPersistence` | GRDB access to the app store and read-only `chat.db` |
| `Sources/BBIMessage` | chat.db repositories, typedstream decoding, change detection |
| `Sources/BBContacts` | Streaming contact ingest and the persistent address index |
| `Sources/BBSerialization` | Client wire types and serializers |
| `Sources/BBAuth` | Authentication schemes (password by default; token when enabled) |
| `Sources/BBHTTPAPI` | Hummingbird routers and middleware for `/api/v1` |
| `Sources/BBSocketIO` | Native Engine.IO / Socket.IO server |
| `Sources/BBEvents` | Event bus, delivery sinks, extension seam, payload codecs |
| `Sources/BBPushKit` | FCM and Firebase provisioning, entirely optional |
| `Sources/BBProxy` | ngrok / Cloudflare / zrok / Tailscale / dynamic-DNS / LAN |
| `Sources/BBAppleScript` | OSAKit send and start-chat, for installs without the Private API |
| `Sources/BBSystem` | NSWorkspace, permissions, Keychain, SMAppService, media |
| `Helper/BBPrivateAPIContract` | Typed contract shared by the server and the injected helper |
| `Helper/BlueBubblesHelper` | Swift dylib injected into Messages.app, stubbed for porting |
| `Tools/` | Conformance recorder, chat.db fixture generator, Private API header tooling |
| `Tests/` | The suites, including the compatibility harness described above |
| `Fixtures/` | The recorded request/response corpus the parity tests diff against |
| `Packaging/` | Build, sign, notarize and disk-image scripts, and `VERSION` |
| `Artwork/` | Brand artwork. `Artwork/Icons/` holds every icon size and its editable sources |
| `docs/` | Subsystem references, the API spec, and the macOS schema dumps |
| `electron/` | The Electron/TypeScript server this one replaces, still maintained |

`electron/` is the original server, and it is not an archive. It still ships bug fixes,
because this server requires macOS 14 and it reaches further back; and it is the reference the
compatibility harness is written against, so two generators and one test read it on every CI
run. It is Apache 2.0 and stays Apache 2.0; everything outside it is licensed under
[`LICENSE.md`](LICENSE.md). See [`CONTRIBUTING.md`](CONTRIBUTING.md) for what that means for a
pull request.

## Build

```sh
swift build
swift test
```

Requires the toolchain pinned in `.swift-version`. See `DEPENDENCIES.md` for why.
