# Build, run, test

**Targets macOS 14 (Sonoma) and newer.** `Package.swift` declares `.macOS(.v14)`; nothing below
that is supported, and no code should branch for it.

Toolchain is pinned in `.swift-version` (currently **6.1**; CI selects
`/Applications/Xcode_16.3.app`, and CI runs on `macos-15` runners). Rationale in
[`DEPENDENCIES.md`](../../DEPENDENCIES.md).
Human-facing setup — permissions, SIP, signing, releases — is in
[`CONTRIBUTING.md`](../../CONTRIBUTING.md).

---

## Build and test

```bash
swift build
swift test
swift test --filter BBSettingsTests
```

---

## Running it

**Two ways, and they are not interchangeable.**

### CLI — for server work

```bash
swift run bluebubbles-server --headless --set socket_port=1234 --set password=dev-password
swift run bluebubbles-server --headless --set log_level=debug
swift run bluebubbles-server --clear-blocklist          # recover from a lockout
```

`--set key=value` layers over the stored value for that run and is **never persisted**, so your
real configuration is safe to develop against. `--config PATH` reads YAML (default
`~/bluebubbles.yml`) for anything you want to keep.

Everything server-side works here: HTTP, socket, `chat.db` reads, webhooks, tunnels.

### App bundle — for anything permission-shaped

```bash
Tools/dev-bundle.sh --run
```

**macOS grants permissions to a BUNDLE, never to a loose binary.** `swift run` produces a process
with no bundle identifier and no signature, so TCC has nothing to attribute a grant to: it never
prompts, `authorizationStatus` answers `denied`, and no amount of clicking in System Settings
fixes it. Contacts, Full Disk Access, Automation and notifications are **all** untestable that
way.

Two rules:

- **Launch with `open`** (which `--run` does), not by executing the binary from a shell. A
  shell-spawned process is attributed to your *terminal* and sees the terminal's permissions.
- **A rebuild invalidates any grant.** Ad-hoc signatures have no stable identity, so TCC's
  recorded requirement stops matching — and the symptom is confusing, because `TCC.db` still says
  allowed. Fix:
  ```bash
  tccutil reset AddressBook com.BlueBubbles.BlueBubbles-Server
  ```
  Avoid it entirely with a stable self-signed identity:
  `DEV_SIGNING_IDENTITY="My Dev Cert" Tools/dev-bundle.sh`.

---

## What CI will fail you on

Everything below runs on every PR (`../.github/workflows/swift-pr.yml` — the workflows live at the repo root, not here). Run the relevant ones
locally before handing work back.

```bash
swift build --build-tests                            # with strict concurrency
swift test --skip-build

swift run bb-openapi infer-schemas --check           # schemas match the recorded corpus
swift run bb-openapi emit --check                    # openapi.json is current
swift run bb-openapi coverage --check                # fixture ratchet

swift format lint --strict --recursive Sources Tests Helper
python3 Tools/package-graph/check.py                 # Package.swift matches the imports

node   Tools/conformance-recorder/selftest.mjs
python3 Tools/chatdb-fixtures/generate.py --self-test
python3 Tools/package-graph/check.py --self-test
```

Notes that save a confusing failure:

- **The `bb-openapi` checks run in DEBUG**, which is what `swift build` produces and what the
  committed document was generated from. `AdditiveRoutes.security` and the FaceTime diagnostics
  are `#if DEBUG`, so a release build legitimately emits ten fewer routes.
- **Order matters**: schemas are inferred from the corpus, and the document is built from the
  schemas. Infer first.
- **`package-graph/check.py` catches what the compiler cannot** — a declared-but-unused dependency
  silently widens what a target is *allowed* to import; an imported-but-undeclared module compiles
  only while some other target happens to pull it in. It had drifted 41 edges in both directions
  before this check existed. Run it after touching any `import`.
- Some things can only be tested on a real Mac — Private API, permissions, AppleScript. **A green
  PR is meaningful but not sufficient before a release.**

---

## The test suites

| Suite | Covers |
|---|---|
| `CompatibilityTests` | The contract: route table diff, naming conventions, **test-data policy** |
| `BBParityTests` | Response diffing against the recorded Node corpus |
| `CompositionTests` | The graph: manifests, capabilities, alert wiring, naming |
| `BBOpenAPITests` | Document generation, schema inference, fixture coverage |
| `IMessageTests` | `chat.db` repositories, change detection, schema profiles, **memory budget** (see [`performance.md`](performance.md)) |
| `SerializationTests` | Wire format, attributed body, message serializer |
| `ProtocolTests` | Socket codec and transport, multipart |
| `BBPrivateAPITests` | Helper protocol round-trips against `FakeHelper` |
| `HelperTests` | `IMCoreRuntime`, selector existence, socket location |
| Per-module `BB*Tests` | The module |

### The parity harness is the important one

It replays recorded response fixtures and diffs them **strictly in both directions** — an added
key fails exactly like a missing one. That is what mechanically enforces the compatibility
contract instead of relying on everyone remembering it.

The corpus lives in `Fixtures/http/` (179 files) and **is committed**. It was local-only while
the scrubber let real content through — multipart bodies bypassed scrubbing entirely, link-local
IPv6 addresses embed the interface MAC, and stack traces carried absolute `/Users/<name>` paths.
All three are scrubbed now and the corpus was re-audited before being committed.

Recording more requires a real Mac and a running reference server (`../packages/server`), with the
recorder proxying in front of it:

```bash
cd .. && npm start                                             # terminal 1
node Tools/conformance-recorder/record.mjs --out Fixtures/http # terminal 2
```

Then point a client at the recorder's port (1235) instead of the server's (1234) and exercise it.
Every exchange is written as a fixture.

**If you record against a live server, re-audit before pushing.** The scrubber is a filter, not a
guarantee, and it has been wrong before.

---

## Test data: never real addresses

`Tests/CompatibilityTests/TestDataPolicyTests.swift` fails the build on real-looking phone
numbers, emails and message content in tests and fixtures. This is enforced, not requested.

Use the fixture generators:

```bash
python3 Tools/chatdb-fixtures/generate.py --out Tests/ChatDBFixtures
```

Deterministic and byte-identical on regeneration, so they never appear as diff noise. Gitignored —
rebuild, do not commit.

---

## Private API work

The helper must match the slice Messages runs, which on Apple Silicon is **arm64e** — and a plain
`swift build` produces arm64:

```bash
swift build --arch arm64e --product BlueBubblesHelper
vmmap "$(pgrep -x Messages)" | grep BlueBubblesHelper    # verify; dyld will not tell you
```

**dyld does not report declining a mismatched library.** Messages simply starts without it. The
other confirmation is `server/info` reporting `helper_connected: true`, which also proves the
socket handshake and peer code-signature check passed.

`os_log` from the injected helper **does not reliably reach `log show`** (measured on macOS
26.5.2: queries by subsystem, `senderImagePath` and process all return nothing while the helper is
demonstrably running). Debug through what it sends over the socket — the channel known to work.

### The observation probe

```bash
cd Tools/observation-probe && ./run-probe.sh
```

A read-only dylib injected into Messages that works out how each inbound event should be observed
(see [`docs/OBSERVATION_LADDER.md`](../../docs/OBSERVATION_LADDER.md)). It observes only — no
swizzles, no mutation, nothing sent. Needs SIP disabled.

**Worth running on every macOS beta.** Its rung-3/4 section tells you whether the selectors the
shipping helper swizzles still exist. When one vanishes the helper silently stops delivering that
event, and the only symptom is a user saying typing indicators stopped working.

---

## Other tools

| Tool | Purpose |
|---|---|
| `Tools/route-table/extract.py` | Regenerates the reference route-table fixture |
| `Tools/package-graph/check.py` | `Package.swift` vs. actual imports |
| `Tools/chatdb-fixtures/generate.py` | Deterministic `chat.db` fixtures |
| `Tools/conformance-recorder/` | Records Node responses as parity fixtures |
| `Tools/observation-probe/` | Read-only Messages observation (separate package) |
| `Tools/send-probe/` | Send-path experimentation |
| `Tools/protocol-vectors/` | Reference implementations for protocol test vectors |
| `Tools/private-api/` | Private API investigation helpers |
| `Tools/dev-bundle.sh` | Assembles and launches `.build/dev/BlueBubbles.app` |
| `swift run bb-appcast` | Appcast generation for releases |
| `swift run bb-parity` | Parity diffing outside the test suite |
