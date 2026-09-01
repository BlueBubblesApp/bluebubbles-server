# Contributing to the Swift server

This guide takes you from a fresh Mac to a running server. It is written to be followed
top to bottom without needing to ask anyone a question — if you hit something it does not
cover, that is a bug in this document, and fixing it is a welcome contribution.

> **Phase 0.** The scaffold, the conformance tooling, and CI exist. The server does not run
> yet. Sections marked *(Phase N)* are written by the phase that implements them, so the
> setup notes get recorded while the sharp edges are still fresh rather than reconstructed
> at the end.

**Contents**

1. [Prerequisites](#1-prerequisites)
2. [Clone and bootstrap](#2-clone-and-bootstrap)
3. [macOS permissions](#3-macos-permissions-phase-9)
4. [SIP and the Private API](#4-sip-and-the-private-api-phase-5)
5. [Choosing a delivery setup](#5-choosing-a-delivery-setup-phase-6)
6. [Running in development](#6-running-in-development-phase-1)
7. [Testing](#7-testing)
8. [Architecture orientation](#8-architecture-orientation)
9. [Building for distribution](#9-building-for-distribution-phase-11)
10. [CI and releases](#10-ci-and-releases)
11. [Troubleshooting](#11-troubleshooting)

---


## Licensing: this directory is not Apache 2.0

The Swift server is licensed differently from the rest of the repository, and the difference
matters before you write any code.

| | License | Commercial use |
|---|---|---|
| `swift/` | [PolyForm Small Business 1.0.0](LICENSE.md) + a personal-use grant | Free under the size threshold; otherwise by agreement |
| everything else | Apache 2.0 (root `LICENSE`) | Unrestricted |

Nothing about the Electron server changed. Its Apache 2.0 grant is irrevocable and we have
not touched it. See [`COMMERCIAL.md`](COMMERCIAL.md) for what the Swift server's terms mean
in practice.

**Pull requests touching `swift/` require a signed Contributor License Agreement.** Read
[`CLA.md`](CLA.md) before you start. The short version:

- You keep the copyright in your work — the CLA is a license grant, not an assignment.
- You grant us the right to sublicense your contribution, which is what lets us offer paid
  commercial licenses. Without it we could not lawfully include your code in one.
- In exchange we are **bound** to keep your contribution available under the project's
  public license. We cannot take your work proprietary-only.

A bot will ask you to sign on your first pull request; it takes one comment and covers
everything you contribute afterwards. If your employer owns your work, they sign
[`CLA-ENTITY.md`](CLA-ENTITY.md) instead.

Two things this does *not* apply to: pull requests outside `swift/`, which need no CLA at
all, and code you did not write. If you are upstreaming someone else's patch or vendoring a
third-party library, say so in the pull request and identify the license — do not sign for
work that is not yours.


## Test data: never real addresses

No phone number, email address, chat GUID, or message body from anyone's real `chat.db` goes
into this repository — not in a test, not in a fixture, not in a comment. The database is the
user's message history, and a committed sample is permanent.

Use the ranges reserved for exactly this:

| Kind | Use | Why |
|---|---|---|
| Email | `someone@example.com` | RFC 2606 reserves `example.com`; it can never be a real mailbox |
| Phone | `+12025550143` | `NPA-555-0100` through `NPA-555-0199` are reserved for fiction |
| Group GUID | `chat000000000000000001` | Obviously synthetic, and short enough to read |

A test that genuinely needs a live conversation takes it from the environment and skips when
it is absent, rather than hardcoding one:

```swift
@Suite("Live send", .enabled(if: liveGUID != nil))
```

```bash
BB_LIVE_SEND_GUID='iMessage;-;someone@example.com' swift test --filter LiveSend
```

That keeps the repository clean while leaving the end-to-end check reproducible for whoever
has a real account to point it at.

### This is enforced, not requested

`Tests/CompatibilityTests/TestDataPolicyTests.swift` reads every `.swift`, `.mjs`, `.py`,
`.json` and `.md` under `Sources`, `Tests`, `Helper` and `Tools`, and fails if it finds an
address that could reach anybody. It exists because the rule above had drifted anyway — a
real Gmail address was serving as a worked example in two source files and two tests, another
was in the FaceTime helper, and a phone number with a live area code was in a wire-shape
test. None of that is catchable at review time: an address in a comment looks like
documentation, and a reviewer cannot tell whose it is.

The check asks whether a value **can route**, which is slightly broader than the table above:

| Safe | Why |
|---|---|
| `+12025550143` | `NPA-555-0100`–`0199`, reserved for fiction. **Use this for anything new** |
| `+15555550100` | Area code 555 is unassignable, so nothing behind it routes. This is what the conformance recorder substitutes, which is why the recorded corpus passes unrewritten |
| `+447700900123`, `+442079460958` | Ofcom's reserved drama ranges, for non-NANP cases |
| `someone@example.com` | RFC 2606 |

Exemptions live in that file, each with its reason, and are only for identifiers of a
**service** rather than a person — `gmail.com` where `ContactAccount.infer` keys on it to
recognise a Google account, Google's `iam.gserviceaccount.com`, and this project's own
published contact address in the licence files. If you need a new one, add it there with the
reason rather than loosening the rule.


## 1. Prerequisites

| Requirement | Version | Why |
|---|---|---|
| macOS | 14 (Sonoma) or later | The deployment floor. Building on an older release will not work |
| Xcode | **16.3 or later** | Supplies Swift 6.1 |
| Swift | **6.1** | Pinned in [`.swift-version`](.swift-version) |
| Command Line Tools | Matching Xcode | `xcode-select --install` |
| Node | 20+ | Only for the conformance recorder and the existing Electron server |
| Python | 3.10+ | Only for the chat.db fixture generator |

**The Swift version is not arbitrary.** GRDB 7 requires Swift 6.1 / Xcode 16.3, and that
requirement propagates to every contributor and to the CI runner image. If you build with an
older toolchain you will get errors that do not obviously point at the cause. See
[`DEPENDENCIES.md`](DEPENDENCIES.md) for the full reasoning.

Verify before going further:

```sh
sw_vers -productVersion            # expect 13.0 or higher
xcodebuild -version                # expect Xcode 16.3 or higher
swift --version                    # expect "Swift version 6.1"
cat swift/.swift-version           # the pin the above must match
```

If `swift --version` disagrees with `.swift-version`, point `xcode-select` at the right
Xcode and re-check:

```sh
sudo xcode-select --switch /Applications/Xcode.app
```

## 2. Clone and bootstrap

```sh
git clone https://github.com/BlueBubblesApp/bluebubbles-server.git
cd bluebubbles-server/swift
swift build
```

The first build resolves five packages (swift-log, swift-crypto, swift-argument-parser,
GRDB, Hummingbird) and takes a few minutes. Subsequent builds are incremental.

```sh
swift test        # runs the unit suites and the parity harness
```

To work in Xcode, open the package directly — there is no `.xcodeproj` to generate:

```sh
xed .
```

`Package.resolved` is committed. If you need to move a dependency, change the constraint in
`Package.swift`, run `swift package update`, and record the reason in `DEPENDENCIES.md` in
the same commit — not afterwards.

## 3. macOS permissions *(Phase 9)*

The server needs several permissions, and the two required ones fail **silently** when
absent — no error, just nothing happening. That is why Phase 9 builds a permissions screen
that checks them up front rather than letting you discover the problem later.

| Permission | Needed for | Symptom when missing |
|---|---|---|
| **Full Disk Access** | Reading `~/Library/Messages/chat.db` | No messages ever arrive. The server starts fine and looks healthy |
| **Automation → Messages** | The AppleScript send path, used when SIP is on | Sends fail or hang with no useful error |
| **Contacts** | Showing names instead of phone numbers | Contacts appear as raw addresses |
| **Notifications** | Native alerts for server problems | No banners; in-app notifications still work |

**Accessibility is not required**, unlike the Electron server. It existed only for the
UI-automation scripts, which this rewrite drops.

Full Disk Access has two steps people commonly get half-right:

1. Add the binary in System Settings → Privacy & Security → Full Disk Access.
2. **Relaunch.** macOS does not apply the grant to a running process.

## 4. SIP and the Private API *(Phase 5)*

The Private API enables reactions, edit/unsend, typing indicators, and group management. It
works by injecting a library into Messages.app, which requires **System Integrity Protection
to be disabled**.

**The server runs fine without it.** This is a supported configuration, not a degraded one:

| Capability | With Private API | Without (SIP on) |
|---|---|---|
| Send text, send attachments, start chats | Private API | **AppleScript** |
| Read messages, chats, handles, attachments | Direct DB | **Identical** |
| Socket / webhook / ntfy / FCM events | Full | **Full** |
| Reactions, edit, unsend, typing, mark read, group management | Private API | Unavailable |

Disabling SIP weakens a real security boundary on your machine. For development you usually
do not need it — only work on Phase 5 does.

**Why injection rather than talking to IMCore directly?** Because it is the *cheaper* ask.
A standalone process can reach IMCore — Beeper's [Barcelona](https://github.com/beeper/barcelona)
does — but only with **AMFI disabled on top of SIP**, plus a machine-wide XPC policy
downgrade. AMFI-off turns off code-signing enforcement for every process on the machine.
Injecting into Messages.app needs SIP alone, because the injected code inherits
Messages.app's entitlements.

To disable: reboot into Recovery (hold ⌘R at startup, or the power button on Apple
silicon), open Terminal, run `csrutil disable`, reboot. Re-enable later with
`csrutil enable` from the same place.

### Building the helper: it MUST be arm64e

**This is the thing that wastes an afternoon.** On Apple Silicon, Messages.app and
FaceTime.app run their **arm64e** slice. `swift build` produces **arm64**. dyld will not map
a mismatched slice, so the helper never loads:

```
The Messages Private API helper cannot be injected
architectureMismatch(dylib: ["arm64"], parent: ["x86_64", "arm64e"])
```

Build the helpers for that slice explicitly:

```bash
swift build --arch arm64e --product BlueBubblesHelper
swift build --arch arm64e --product BlueBubblesFaceTimeHelper
```

Then point the server at them. Both settings are hidden from the UI — a shipped install has
exactly one correct answer, the copy in its own bundle — but they are still settable, and
this is what they are for:

```bash
swift run BlueBubblesApp \
  --set enable_private_api=true \
  --set private_api_helper_path="$PWD/.build/arm64e-apple-macosx/debug/libBlueBubblesHelper.dylib" \
  --set private_api_facetime_helper_path="$PWD/.build/arm64e-apple-macosx/debug/libBlueBubblesFaceTimeHelper.dylib"
```

**`--arch arm64e` repoints `.build/debug`.** It is a symlink, and an arch-specific build
moves it to `.build/arm64e-apple-macosx/debug` — so `.build/debug/BlueBubblesApp` silently
becomes the arm64e app, or disappears. Once you have built a helper this way, refer to the
server by its full path rather than through the symlink:

```bash
.build/arm64-apple-macosx/debug/BlueBubblesApp
```

Confirm what you actually built before debugging anything else:

```bash
lipo -archs .build/arm64e-apple-macosx/debug/libBlueBubblesHelper.dylib   # arm64e
```

A packaged build does not have this problem: `Packaging/build-app.sh` produces the universal
dylib that ships in `Contents/Frameworks`. It is only the development loop that has to ask.

## 5. Choosing a delivery setup *(Phase 6)*

There is no single expected configuration, and **Google FCM is optional**. Pick whichever
matches what you are working on:

| Setup | Needs | Good for |
|---|---|---|
| **Socket only** | Nothing | Most development. Desktop clients use this anyway |
| **Webhooks / ntfy** | A URL to POST to | Event fan-out work without Firebase |
| **Full FCM** | A Firebase project | Push notification work specifically |

A socket-only server is a first-class configuration — it starts clean, completes setup with
no Firebase step, and does not warn about the absent ones.

### Setting up FCM *(Phase 13)*

Only needed if you are working on push. **Firebase → Notifications** in the app, where there
are three ways in:

- **Create a project for me.** Signs in through your browser (Google refuses sign-in from an
  embedded web view, so it opens your real browser) and creates a project with locked-down
  rules from the moment it exists. Takes a few minutes; the progress list is the provisioning
  step it is on.
- **Import an existing project.** Pick the service account key and the `google-services.json`.
  Order does not matter — each file is identified by parsing it, not by its name — and both
  land in the Keychain, with the originals deleted.
- **Upgrading from the Electron server.** Its plaintext `FCM/server.json` and `FCM/client.json`
  are migrated into the Keychain on first start and the plaintext copies removed. You get an
  alert saying so.

**"Send Test Notification" is the only thing that proves it worked.** Credentials that parse,
a project that exists and a token that mints all look identical to a broken setup until a
message reaches a device — which needs at least one client registered, so connect the app to
your server first.

The **local callback port 8641 is not adjustable**: `http://localhost:8641/oauth/callback` is
the redirect URI registered against the OAuth client in Google's console, and Google rejects
any redirect that does not match exactly. If something else on your machine holds that port,
sign-in fails with "port unavailable" and the fix is to free the port, not to change it here.

### Do not add a Google contacts sync

The current server has one, and it is a workaround rather than a feature.
`node-mac-contacts` enumerates address-book **containers** —
`containersMatchingPredicate:nil`, then one query per container — and CardDAV accounts do not
reliably appear in that list on macOS, so Google contacts were invisible to it. Fetching them
from Google's People API was how that got worked around.

`ContactsIngestor` does not have the problem. It runs an unfiltered `CNContactFetchRequest`
with `unifyResults = true`, which enumerates the whole store: every account configured in
Contacts.app, CardDAV included. **If a contact is visible in Contacts.app, it is visible to
this server** — so a Google account synced into Contacts needs no special handling, and
`ContactSource` has no Google case. `OAuthFlowTests` asserts no contacts scope is ever
requested, which is the guard against this coming back.

If Google contacts appear to be missing, the cause is upstream of us: the account is not added
to Contacts.app, or its "Contacts" toggle is off in System Settings → Internet Accounts.

## 6. Running in development

Two ways to run it, and **they are not interchangeable** — which one you need depends on what
you are working on.

### The CLI, for server work

```bash
swift run bluebubbles-server --headless --set socket_port=1234 --set password=dev-password
```

Fastest loop, no windows, and everything server-side works: the HTTP API, the socket, chat.db
reads, webhooks, tunnels. `--set key=value` overrides any setting for that run and is
**never persisted** — it layers over the stored value, so your real configuration is safe to
develop against. `--config PATH` reads a YAML file (default `~/bluebubbles.yml`) for anything
you want to keep between runs.

```bash
swift run bluebubbles-server --headless --set log_level=debug   # more output
swift run bluebubbles-server --clear-blocklist                  # recover from a lockout
```

### The app bundle, for anything permission-shaped

**macOS grants permissions to a BUNDLE, never to a loose binary.** `swift run` gets a process
with no bundle identifier and no code signature, so TCC has nothing to attribute a grant to: it
never prompts, `authorizationStatus` answers `denied`, and no amount of clicking in System
Settings fixes it. Contacts, Full Disk Access, Automation and notifications are **all**
untestable this way.

```bash
Tools/dev-bundle.sh --run
```

That assembles `.build/dev/BlueBubbles.app` from the current debug build, ad-hoc signs it, and
launches it. Two rules:

- **Launch with `open` (which `--run` does), not by executing the binary from a shell.** A
  shell-spawned process is attributed to your TERMINAL, so it sees the terminal's permissions
  rather than the bundle's.
- **A rebuild invalidates any grant you gave it.** Ad-hoc signatures have no stable identity,
  so TCC's recorded requirement stops matching. The symptom is confusing — `TCC.db` still says
  allowed while the app resolves to denied. Fix:

  ```bash
  tccutil reset AddressBook com.BlueBubbles.BlueBubbles-Server
  ```

  To avoid it entirely, sign with a stable self-signed identity:
  `DEV_SIGNING_IDENTITY="My Dev Cert" Tools/dev-bundle.sh`. Releases never have this problem —
  Developer ID is stable, so a real user's grant survives updates.

### Testing the Private API

The helper must match the slice Messages runs, which on Apple Silicon is **arm64e**, not
arm64 — and a plain `swift build` produces arm64:

```bash
swift build --arch arm64e --product BlueBubblesHelper
```

dyld does not report declining a mismatched library. Messages simply starts without it, so
verify the injection rather than assuming it:

```bash
vmmap "$(pgrep -x Messages)" | grep BlueBubblesHelper
```

`server/info` reporting `helper_connected: true` is the other confirmation, and the one that
proves the socket handshake and peer code-signature check also passed.

**`os_log` from the injected helper does not reliably reach `log show`** — measured on macOS
26.5.2, where queries by subsystem, `senderImagePath` and process all return nothing while the
helper is demonstrably running. Debug the helper through what it sends over the socket, which
is the channel known to work.

**Develop against a fixture database, not your own messages:**

```sh
python3 Tools/chatdb-fixtures/generate.py --out Tests/ChatDBFixtures
```

That writes `chat-ventura.db`, `chat-sonoma.db`, and `chat-sequoia.db` — deterministic
databases carrying direct and group chats, an attachment, a reaction, a threaded reply, and
an edited message. Regenerating produces byte-identical output, so they never show up as
noise in a diff.

## 7. Testing

```sh
swift test                                   # everything
swift test --filter BBSettingsTests          # one suite
```

**The parity harness is the important one.** It replays fixtures recorded from the Electron
server and diffs them **strictly in both directions** — an added key fails exactly like a
missing one. That is what mechanically enforces the compatibility contract instead of
relying on everyone remembering it.

Recording fixtures requires a running Electron server on a real Mac:

```sh
# Terminal 1 — the existing server on its usual port
cd .. && npm start

# Terminal 2 — the recorder in front of it
cd swift
node Tools/conformance-recorder/record.mjs --out Tests/CompatibilityTests/Fixtures
```

Then point a client — the Flutter app, `curl`, anything — at the recorder's port (1235) in
place of the server's (1234) and exercise it. Every exchange is written as a fixture.
Credentials are redacted; the recorded corpus is gitignored because it contains real message
content.

Both Phase 0 tools self-test without a server or a network, and CI runs both:

```sh
node Tools/conformance-recorder/selftest.mjs
python3 Tools/chatdb-fixtures/generate.py --self-test
```

### `Package.swift` must match the imports

`python3 Tools/package-graph/check.py` fails the build if a target declares a dependency it
never imports, or imports a module it never declares. Both are invisible to the compiler: a
dead edge silently widens what a target is *allowed* to import, and an undeclared import
compiles only while some other target happens to pull the module in.

Run it after touching any `import`. `--self-test` exercises the scanner itself.

### The route table fixture

`Tests/CompatibilityTests/RouteTableTests.swift` diffs our route table against the Electron
server's — in both directions, so an **added** route fails exactly like a missing one. That
is what keeps "additive and default-off" honest: the token endpoints have to 404 rather than
401, and a test is the only thing that reliably enforces it.

The fixture is generated from `httpRoutes.ts` rather than hand-written, because a
hand-maintained list of ~100 routes drifts within a week:

```sh
python3 Tools/route-table/extract.py
```

Run it whenever the Electron route table changes. If you add a route to
`RouteTable.groups` that does not exist on the Electron server, the test fails and the fix
is to move it to `AdditiveRoutes` — which the composition root mounts explicitly.

Some things can only be tested on a real Mac — Private API, permissions, AppleScript. CI
covers everything else, so a green PR is meaningful but not sufficient before a release.

### The observation probe *(Phase 5 investigation)*

`Tools/observation-probe` is a read-only dylib you inject into Messages.app to work out how
each inbound event should be observed — see [`docs/OBSERVATION_LADDER.md`](docs/OBSERVATION_LADDER.md).
It observes only: no swizzles, no mutation, nothing sent. Needs SIP disabled, like the
Private API itself.

```sh
cd Tools/observation-probe && ./run-probe.sh
```

Worth running on every macOS beta even outside the investigation: its rung-3/4 section tells
you whether the selectors the shipping helper swizzles still exist. When one vanishes, the
helper silently stops delivering that event and the only symptom is a user saying typing
indicators stopped working.

## 8. Architecture orientation

Read [`CLAUDE.md`](CLAUDE.md) first — particularly **the compatibility
contract**, which governs every decision here.

### Where do I add…?

| To add | Go to | Notes |
|---|---|---|
| A setting | `Sources/BBSettings` | Declare a `Setting<T>` with its presentation metadata. The UI row is generated — do not write one |
| An API route | `Sources/BBHTTPAPI` | Add to the route table with its scope and validator, then a controller in `BBHandlers` |
| Business logic behind a route | `BBInterfaces` | **Not the controller.** See below |
| A settings row in the app | `Sources/BBSettings` | Declare a `presentation:` and add it to `Settings.renderable`. Do **not** write a view |
| A page in the app | `Sources/BlueBubblesApp/Views` | Add a `Destination` case; the view calls the interfaces layer, never HTTP. Reach it through a narrow accessor on `AppModel` — `model.serverAdmin`, `model.scheduling`, `model.interfaces()` — never `AppContext`, which is private for that reason |
| A service | `Sources/BBServiceKit` conformance | Declare `dependencies`; the registry derives start order |
| An event | `Sources/BBEvents` | Add a `ServerEvent` case and its per-sink projection |
| A user-visible alert | `Sources/BBDiagnostics` | Raise explicitly. **Never** make logging produce one |
| A Private API call | `Helper/BBPrivateAPIContract` then `Helper/BlueBubblesHelper` | Contract first, then the implementation. Never call IMCore directly — go through `IMCoreRuntime`, see below |
| A delivery sink | `Sources/BBEvents` | Implement `CustomEventSink`, like the webhook and ntfy sinks |
| An external program a service runs | `tools:` on its manifest | Declare a `ManagedToolDescriptor` — the host downloads, verifies, installs and version-checks it. Do **not** write a downloader. Declare `spawnProcess` and every download host in `network`, or the validator refuses it. Name a `recommended:` version: that is what installs |

### Never construct `Process` — use `Subprocess`

`BBCore/Subprocess.swift` is the only place that runs a child process to completion. Nine
modules used to build their own `Process()`, and each one independently re-decided the same
four things: whether to drain the pipe before waiting (getting it wrong deadlocks past
64 KB), whether to detach stdin (`unzip` prompts when an archive contains a name that
already exists), whether to have a timeout at all (three of them did not), and whether the
blocking wait happens on a cooperative-pool thread.

`Subprocess.run` is async and takes a **required** timeout — no default, deliberately, so
the decision is made once per call site rather than forgotten. `runSynchronously` exists for
the one shape that cannot be async, a default argument. `launch` starts something and does
not wait.

`BBProxy/DaemonProcess` is the exception and stays one: supervising a long-running tunnel
needs streaming output, readiness signals, its own process group and a termination handler,
none of which belong in a run-to-completion helper.

### External programs are declared, never fetched by hand

Three connection methods run someone else's binary — ngrok, cloudflared, zrok — and none of
them contains any downloading code. Each declares a `ManagedToolDescriptor` in its manifest
(`BuiltInTools`) and asks `AppContext.tools` for a path; `BBTooling` does the rest.

That split is not tidiness either. A downloader compiled into a service is a capability plugins
could never have, and the whole point of the manifest model is that a built-in service and a
third-party one are the same kind of thing. If you find yourself adding a `URLSession` call to
fetch a binary, the declaration is missing something — add it there.

Four rules the code enforces and you should not work around:

- **The default install is the recommended version, not the newest.** Each plugin declares the
  version it was tested against (`RecommendedBuild`), and that is what installs. A newer vendor
  build is shown, never pushed, and never notified about — the only notification is the
  recommendation itself moving, because that one means somebody tested it. Bumping a pin is a
  release step; a stale one falls back to the current release and says so on the page.
- **Never update a tool automatically.** The tool is usually the tunnel; the tunnel is the only
  route to the machine; the user is not at the machine. Check, report, offer.
- **Verify before adopting.** Checksum where published, Developer ID signature where the vendor
  signs, and pin the signing team after the first install. The `current` symlink moves last, so
  a failed install leaves the working one alone.
- **Keep the offline path.** A user configuring a tunnel may have no working connection —
  frequently that is why — so a binary they already have must remain usable.

### Controllers are thin; the interfaces layer is where logic lives

`BBInterfaces` holds `MessageInterface`, `ChatInterface`,
`HandleInterface`, `AttachmentInterface`, `ContactInterface`, `ServerInterface` and
`ScheduleInterface`, reached through `AppContext.interfaces()`. A controller parses its
request, calls one of them, and returns — anything resembling a decision belongs one level
down.

That is not tidiness. The same methods serve the HTTP routes, the legacy socket commands and
the SwiftUI app, and sharing them is what makes the Electron server's 68 `ipcMain.handle`
channels unnecessary: those exist because the UI has no other way to reach the business
logic, so every operation needs a hand-written channel on both sides. Logic written into a
controller is logic the app cannot call, and it comes back as a 69th channel.

A concrete test of whether you have it right: could the SwiftUI settings window call this
without going through HTTP? If not, it is in the wrong place.

**The read methods return rows, not JSON.** `message.query` hands back
`[MessageProjection]` — a row plus whatever relations the query asked for — and the
controller calls `interfaces.message.serialize(_:query:)` to get the wire form. Chats,
handles and attachments work the same way.

Put serialization in the controller, never in the interface. The layer used to return
pre-serialized `JSONValue`, which meant the app could not use it: it would either parse the
server's own JSON back by string key — `metadata?["mimeType"]?.stringValue`, which is
unchecked and silently becomes nil if a key is renamed — or someone would add a typed twin
next to the real method, and the layer would end up speaking two vocabularies.

Absent-vs-null is not your problem when you do this. Whether a field appears at all is
decided by `SchemaProfile` inside the serializer, not by whether a value is nil, so moving
the serializer call does not change the bytes. The parity fixtures prove it either way.

### Two ways to run the server, and they are not interchangeable

`BlueBubblesApp` is the SwiftUI app that ships in the bundle. `bluebubbles-server` is a CLI
that links no AppKit. Both are built, and the CLI ships **inside** `BlueBubbles.app` so it is
covered by the same signature and notarization ticket.

`--headless` on the app sets `NSApplication.setActivationPolicy(.prohibited)`, which means
"no Dock icon, no app switcher entry" — a login item. It does **not** mean "no GUI session".
`App` goes through `NSApplicationMain`, which needs a WindowServer connection: launched
detached from a login session the app binary exits before it logs anything, while
`BlueBubbles.app/Contents/MacOS/bluebubbles-server` serves requests normally from the same
bundle.

So: a launch **agent** in a user session can run either. A launch **daemon**, a headless Mac,
or CI must use the CLI.

### The settings screen is generated — do not write a view for a setting

Declaring a `Setting` with a `presentation:` and adding it to `Settings.renderable` is the
whole job. `SettingRow` renders every control type from the descriptor, including validation
errors and the "set on the command line, not editable here" state.

`Settings.renderable` is hand-written because Swift cannot enumerate a type's static members.
`RenderableSettingsTests` is what keeps it honest — it fails when a setting declares a
presentation and is missing from the list, which is the omission the generated screen exists
to prevent. It has already caught two settings whose keys were never added to
`Settings.allKeys` either.

### Porting an IMCore method

Every unported method in `IMCoreBridge` throws `notImplemented` and names its counterpart in
`Messages/MacOS-11+/BlueBubblesHelper/BlueBubblesHelper.m`. Fill in bodies one at a time; the
server already compiles against the contract, so a partial port is shippable.

**Always go through `IMCoreRuntime`.** IMCore ships no headers, and the shipping ObjC helper
gets around that with a hand-maintained header dump per macOS release — where a moved selector
is a link error, and a link error is a helper that never loads. dyld reports *nothing* when it
declines an insert, so that failure is invisible: Messages just starts without the Private API.
Looking selectors up at runtime instead degrades one feature loudly rather than all of them
silently.

`IMCoreRuntime` refuses three calls that would otherwise crash **Messages itself**, not just
the helper. All three were found by its own tests, and all three look fine at the call site:

| Mistake | What happens |
|---|---|
| Sending a selector the object does not have | ObjC exception → the user's Messages terminates |
| Right selector, wrong argument count — `responds(to:)` says yes for `sortedArrayUsingSelector:`, and calling it with none passes garbage as a `SEL` | abort |
| Right selector and arity, non-object return — `perform` reads `count`'s `NSUInteger` as a pointer, so an array of 2 becomes address `0x2` | segfault |
| Calling IMCore off the main queue | `dispatch_assert_queue()` traps — **uncatchable**, Messages dies |

So: object returns via `send`, `BOOL` via `bool`, integers via `integer`, doubles via
`double`, `BOOL` arguments via `callBool`, three or four arguments via `callVoid`, and
anything else — five arguments, a completion block, a mixed signature — via `invoke`, which
goes through `NSInvocation` inside the exception barrier. A `BOOL` passed through `perform`
arrives as the boxed `NSNumber`'s pointer, and every non-null pointer is truthy — a typing
indicator that can only ever turn *on*. A `double` read through `perform` is worse: a
latitude of 37.33 becomes an address in the low four billion.

**Completion blocks are handled for you.** `BBInvoke` copies any block argument before the
invocation retains it, so a call site just passes
`unsafeBitCast(block, to: AnyObject.self)` like any other object. The reason is the ordinary
Objective-C rule — a block stored beyond the caller's scope must be copied, and IMCore's
completions are stored and fired later — but note the measured caveat: **Swift does not
produce stack blocks**, so this was never a live crash in this codebase. It is discipline at
an `unsafeBitCast` boundary. `BlockArgumentTests` labels which of its cases are
characterization rather than regression guards, and says why.

None of the IMCore call sites can be tested without Messages.app and SIP disabled.
`IMCoreRuntimeTests` covers everything underneath them, which is where the crashes live.

### Find the selectors first, and commit what you found

`Tools/header-dump/dump.sh` reads the Objective-C **runtime** on the machine you run it on
and writes `docs/headers/macos-<version>/`. Run it before porting anything new, add the class
names you need to its list, and commit the output — the diff between two versions' directories
is the answer to "what did Apple move this time".

Do **not** work from the Objective-C helper's `FM*.h` / `IM*.h` files. They are `ktool` dumps
of an iOS 16 SDK and they have drifted: they describe `FMFSessionDataManager`, which does not
exist on macOS 26, and omit `IMFindMyHandle`, which does. A probe written against them
concluded FindMy was unreachable from inside Messages, which was wrong and cost a release.

Two lessons from that, both cheap to apply:

- **A missing class means the capability MOVED, not that it is gone.** Look for the wrapper
  Apple introduced — `IMFMFSession` had been sitting in IMCore the whole time.
- **Do not probe for a notification name with `dlsym`.** IMCore builds these from `@"…"`
  literals rather than exporting symbols, so a symbol lookup reports absent for a
  notification that fires constantly. Search `__TEXT,__cstring` instead.

### Testing the FaceTime helper against a real FaceTime.app

The FaceTime helper is a SEPARATE dylib (`BlueBubblesFaceTimeHelper`) injected into
FaceTime.app, because TelephonyUtilities' call machinery is registered by FaceTime.app and
traps in any other host. It connects to the SAME server socket as the Messages helper and
registers as `com.apple.FaceTime`; the server routes FaceTime actions to it by that bundle id.

Because both helpers share one socket, you do **not** need the server to inject FaceTime to
test end to end — inject it manually and the running server will route FaceTime REST calls to
it:

```bash
# arm64e, like Messages — a plain arm64 dylib maps nowhere and FaceTime starts without it.
swift build --arch arm64e --product BlueBubblesFaceTimeHelper

# 1. Run the server with the Private API on and the FaceTime feature flag enabled.
swift run bluebubbles-server --headless \
    --set enable_private_api=true \
    --set feature_facetime_enhanced=true \
    --set private_api_helper_path="$PWD/.build/arm64e-apple-macosx/debug/libBlueBubblesHelper.dylib"

# 2. In another shell, inject the FaceTime helper into FaceTime.app by relaunching it with
#    the dylib inserted. (SIP off + library validation disabled, same as Messages.)
osascript -e 'quit app "FaceTime"'; sleep 1
DYLD_INSERT_LIBRARIES="$PWD/.build/arm64e-apple-macosx/debug/libBlueBubblesFaceTimeHelper.dylib" \
    /System/Applications/FaceTime.app/Contents/MacOS/FaceTime &
```

Confirm it loaded and reached the private APIs:

```bash
vmmap "$(pgrep -x FaceTime)" | grep FaceTimeHelper                 # dylib mapped?
log stream --predicate 'subsystem == "com.bluebubbles.facetimehelper"'  # what it says
curl -s "http://localhost:1234/api/v1/server/info?password=…" | jq .data.detected_helpers
# ^ com.apple.FaceTime should be in the connected processes

# The proof that the TU private APIs are reachable via the dyld: mint a link.
curl -s -X POST "http://localhost:1234/api/v1/facetime/link?password=…" | jq .
```

A successful `link` response means the injected helper stood up a registered
`TUConversationManagerXPCClient` inside FaceTime.app and called
`generateLinkWithInvitedMemberHandles:…` — i.e. the private APIs work through the dyld. If the
helper is not injected, the same call reports "the com.apple.FaceTime helper is not connected"
rather than misrouting to Messages.

Server-managed injection + FaceTime.app supervision (keeping it alive against
`NSSupportsAutomaticTermination`) is a separate piece — until it lands, inject manually as
above.

### Testing the Private API against a real Messages

Needs SIP disabled. Everything else in the server works without it.

```bash
# Messages runs its arm64e slice on Apple Silicon. A plain arm64 dylib maps nowhere and
# dyld reports NOTHING — Messages just starts without the helper.
swift build --arch arm64e --product BlueBubblesHelper

swift run bluebubbles-server --headless \
    --set enable_private_api=true \
    --set private_api_helper_path="$PWD/.build/arm64e-apple-macosx/debug/libBlueBubblesHelper.dylib"
```

The server quits and relaunches Messages to inject. Confirm it worked:

```bash
vmmap $(pgrep -x Messages) | grep BlueBubblesHelper          # mapped?
log stream --predicate 'subsystem == "com.bluebubbles.helper"'  # what the helper says
lsof -p $(pgrep -x Messages) -a -i TCP | grep 4567           # which transport connected
curl -s "http://localhost:1234/api/v1/server/info?password=…" # helper_connected
```

**Messages is sandboxed, and that decides the transport.** It has
`com.apple.security.app-sandbox` with a container at `~/Library/Containers/com.apple.MobileSMS`,
so a Unix socket outside that container is subject to the sandbox's file rules. It also has
`com.apple.security.network.client`, so loopback TCP is permitted. On a real machine the
helper connects over **TCP**, which is why the Objective-C helper always did. Do not "simplify"
the helper down to the Unix socket.

**IMCore calls must be on the main thread, and this is enforced by the type system rather
than by remembering.** `IMCoreBridge` and `HelperDispatch.perform` are `@MainActor`, so the
compiler puts every IMCore call on the main actor. Do not remove those annotations to make a
call site simpler — IMCore asserts its queue with `dispatch_assert_queue()`, and the failure
is `EXC_BREAKPOINT`, not an exception: `@try/@catch` cannot catch it and Messages dies. A send
from a task thread delivered the message and *then* crashed Messages.

The Objective-C helper never hit this because its socket library was built with
`delegateQueue:dispatch_get_main_queue()` — it got main-thread execution for free and never
had to state it. Swift concurrency runs tasks wherever the pool puts them, so we state it.

Do **not** reach for `DispatchQueue.main.sync` instead. That was the first attempt: it blocks
a helper thread on every call, and it deadlocks under `swift test`, because a test host runs
the test executor on the main thread and nothing drains the main queue. `await` on a
`@MainActor` type suspends rather than blocking, which is why it works in both places.

Two more consequences worth keeping in mind when working on the helper:

- **Foundation's directory APIs lie inside the sandbox.** `NSHomeDirectory()` and
  `FileManager.urls(for: .applicationSupportDirectory)` return container-relative paths.
  Anything the server and helper both need to agree on goes through `SocketLocation`, which
  uses `getpwuid`.
- **`NSLog` is useless here.** From an injected dylib it reaches stderr and nothing else, and
  a GUI app launched by `open` has no readable stderr — so a broken helper is
  indistinguishable from an absent one. Use `os_log` with the `com.bluebubbles.helper`
  subsystem.

**Use a test conversation.** Typing indicators and read receipts are visible to the other
party, and the corpus that drives them is addressed by chat GUID — it is very easy to point
one at a real conversation by accident.

### Two rules that are easy to get wrong

**Logging never notifies.** `logger.error(...)` writes a log and nothing else. A
user-visible notification is an explicit `alerts.raise(...)`. The Electron server conflates
these, which is why every internal error becomes a notification carrying only a string.

**Adding a field to a response is a breaking change.** Not a harmless enhancement — the
parity harness will fail it. New fields go behind an opt-in parameter.

**Route order is behavior, not style.** Routes register in declaration order and the first
match wins, so `:guid` catch-alls come last within a group and `PUT /contact/:id` precedes
`GET /contact/external/:externalId`. Reordering the table for tidiness silently routes
requests to the wrong handler — a 200 with the wrong body, not a 404, which is why it can go
unnoticed for a long time. `RouteOrderingTests` pins the cases that have actually bitten.

**Path parameters come from the router, not from the path.** `pathParameters` is populated
from Hummingbird's own match in `HTTPAPIBuilder.buildRouter`. Do not re-derive it by splitting
`request.path` against the template — that is a second implementation of matching the router
already did, and the one case where the two disagree is a route that reads the wrong segment
and returns a 200. This was broken for real: the dictionary was declared, threaded through,
and never filled, so every `:guid` and `:id` route answered `400 missing path parameter`. It
compiled, the server reported every route mounted, and no test caught it. `PathParameterTests`
now runs a real listener against it.

**Percent-decode once.** `requirePathParameter` decodes; the dispatcher does not. A chat GUID
is `iMessage;-;+15555550101` — semicolons, a plus, usually an `@` — so a handler reading
`pathParameters` raw looks up the encoded form and finds nothing. Decoding in both places
turns a literal `%2F` in an address into a path separator.

**A view never calls HTTP.** Views call `AppContext.interfaces()` — the same objects the
HTTP controllers call, in the same process. Routing a view through `URLSession` to the
server's own port would reintroduce exactly what the 68 `ipcMain.handle` channels were: a
serialization boundary inside one program. It would also fail whenever the listener is down,
which is when the UI is most needed.

**A sink must never be able to delay message detection.** `EventBus.emit` returns only once
every sink has finished or timed out, and nothing buffers on the caller's behalf — so anything
that must not stall, the message poller above all, emits from a detached task. A slow webhook is
then a slow webhook rather than a stalled detector. If you find yourself wanting the poller to
await delivery, you are about to make a badly-behaved endpoint able to stop the server noticing
messages.

**Socket frames are compared byte-for-byte against reference vectors.** A malformed frame
does not fail loudly: the client ignores it and messages just stop arriving, which surfaces
weeks later as "the server broke". `Tests/ProtocolTests` pins the encoder against
socket.io-parser and engine.io-parser output. Regenerate with:

```sh
cd Tools/protocol-vectors && npm install && node generate.mjs
```

**Rate limiting must never blame the tunnel.** Nearly every install sits behind Cloudflare,
ngrok, or zrok, so the socket peer address is the tunnel's egress and identical for every
client. Counting a failure against it locks out the entire user base at once — a far worse
outcome than the brute-forcing it defends against. `X-Forwarded-For` is honored only from a
configured trusted proxy, the active tunnel address is permanently unblockable, and an
unattributable request falls back to global throttling instead of a block.
`AccessControlTests` covers each of these; treat a failure there as an outage, not a nit.

## 9. Building for distribution

Four scripts in `Packaging/`, each runnable on its own so a failed release can be resumed
rather than restarted. `swift-release.yml` runs them in this order.

```bash
Packaging/build-app.sh                      # universal BlueBubbles.app
Packaging/sign-app.sh    --app .build/package/BlueBubbles.app --identity "Developer ID Application: … (TEAMID)"
Packaging/notarize-app.sh --app .build/package/BlueBubbles.app
Packaging/make-dmg.sh    --app .build/package/BlueBubbles.app
```

`build-app.sh` alone needs no credentials, so anyone can produce a local bundle:

```bash
Packaging/build-app.sh && open .build/package/BlueBubbles.app
```

### What is in the bundle, and why

| Item | Why |
|---|---|
| `MacOS/BlueBubbles` | The SwiftUI app |
| `MacOS/bluebubbles-server` | The CLI, for launch daemons and headless Macs. Inside the bundle so it is covered by the same signature and notarization ticket |
| `Frameworks/libBlueBubblesHelper.dylib` | Injected into Messages. Inside the bundle so its path is stable and a user cannot substitute it |
| `Resources/*.bundle` | **SwiftPM resource bundles.** Easy to forget and fatal to omit — the app starts, serves requests, then aborts on the first address it formats, because PhoneNumberKit calls `fatalError` when it cannot find its bundle. `build-app.sh` fails if it copies none, and skips `*Tests.bundle` so fixtures do not ship |

### Version

`Packaging/VERSION` is the single source of truth. `build-app.sh` stamps it into
`CFBundleShortVersionString`, `ServerVersion.current` reads it back out of the bundle, and the
release workflow refuses a tag that disagrees with it. Bump it in the same PR as the change
it describes.

`CFBundleVersion` is the commit count — monotonic, which Sparkle requires. A date would go
backwards when an older tag is rebuilt.

### Entitlements

`Packaging/BlueBubbles.entitlements`, hardened runtime, **not sandboxed** — the App Sandbox
cannot read `~/Library/Messages/chat.db`, which is the point of the application. Full Disk
Access is what actually gates that.

| Entitlement | Why |
|---|---|
| `cs.disable-library-validation` | **Required for the Private API.** Without it dyld declines the inserted library and reports nothing — Messages starts normally, and the only symptom is a helper that never connects. `sign-app.sh` fails the build if it is missing from the signed bundle |
| `automation.apple-events` | The AppleScript send path. Without it, sends fail with -1743 |
| `personal-information.addressbook` | Contact names and avatars |
| `files.user-selected.read-write` | Attachments and imports chosen in an open panel |

**Two entitlements the Electron build carried are deliberately gone:**
`cs.allow-unsigned-executable-memory` and `cs.allow-jit`. Both exist for V8, which JITs
JavaScript. Swift is compiled ahead of time and needs neither, and together they permit
writable-executable memory — the main thing the hardened runtime exists to prevent. If
something appears to need them back, that is worth investigating rather than restoring.

### Signing order

Nested code first, then the bundle. `sign-app.sh` uses `find -depth`, which visits children
before parents. Signing outside-in produces a bundle whose signature is invalidated by the
next inner signature, and the failure appears at notarization — or on a user's machine, as a
damaged app.

### Notarization

Uses an App Store Connect API key rather than an Apple ID and app-specific password: no 2FA
coupling, scoped, revocable on its own. On rejection the script fetches and prints the
submission log, which is the only place Apple says *why* — a status word alone is not
diagnosable.

Stapling matters as much as notarizing: it attaches the ticket to the bundle so Gatekeeper
verifies **offline**. Without it, a user installing without a network is told the app is
damaged.

### Appcast

`bb-appcast` signs artifacts and maintains the feed. The private key is read from
`SPARKLE_EDDSA_PRIVATE_KEY` in the environment, never an argument, so it stays out of the
process table and CI logs.

```bash
export SPARKLE_EDDSA_PRIVATE_KEY="…"
swift run bb-appcast public-key                    # for SUPublicEDKey
swift run bb-appcast add --short-version 1.2.3 \
    --artifact BlueBubbles-1.2.3.dmg \
    --url https://github.com/…/BlueBubbles-1.2.3.dmg
swift run bb-appcast verify --artifact BlueBubbles-1.2.3.dmg --public-key "$(swift run bb-appcast public-key)"
```

`verify` runs in CI before anything is published, because a bad signature is invisible: the
release looks correct and every shipped install silently refuses it. The symptom — "nobody is
getting updates" — surfaces weeks later with nothing in any log.

## 10. CI and releases

| Workflow | Trigger | Does |
|---|---|---|
| [`swift-pr.yml`](../.github/workflows/swift-pr.yml) | PRs into `master` or `development` | Build, test, lint, tooling self-tests |
| [`swift-deps.yml`](../.github/workflows/swift-deps.yml) | Weekly | `swift package update`, opens a PR if anything moved |
| `swift-release.yml` *(Phase 11)* | `vX.Y.Z` tags | Sign, notarize, DMG, appcast, draft release |

The existing Electron workflow (`main.yml`) is untouched and runs independently.

**PR builds need no secrets**, so pull requests from forks run the full suite. The Xcode app
target is built unsigned for exactly this reason.

CI runs on **`macos-15`**, not the `macOS-13` image the Electron workflow uses — that older
image cannot supply Xcode 16.3.

### Secrets, and how to generate each

| Secret | What it is |
|---|---|
| `BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`, `KEYCHAIN_PASSWORD` | Developer ID cert. Already configured for the Electron workflow |
| `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY_P8` | `notarytool` API key |
| `SPARKLE_EDDSA_PRIVATE_KEY` | Signs appcast entries |

`BUILD_PROVISION_PROFILE_BASE64` is **not** needed. A provisioning profile is an App Store
and development artifact; Developer ID direct distribution does not use one.

**Developer ID certificate.** In Xcode, Settings → Accounts → Manage Certificates → + →
Developer ID Application. Then in Keychain Access, right-click the certificate → Export, save
as `.p12` with a password. That password is `P12_PASSWORD`; `KEYCHAIN_PASSWORD` is any
throwaway string, used only for the temporary keychain the runner creates and deletes.

```bash
base64 -i DeveloperID.p12 | pbcopy   # -> BUILD_CERTIFICATE_BASE64
```

**App Store Connect API key.** appstoreconnect.apple.com → Users and Access → Integrations →
App Store Connect API → + . Give it the **Developer** role; Admin is not required and this
key only submits builds. Download the `.p8` — Apple allows this **once**, and there is no way
to retrieve it later.

- `APP_STORE_CONNECT_KEY_ID` — the Key ID column
- `APP_STORE_CONNECT_ISSUER_ID` — the Issuer ID above the table, shared by all keys
- `APP_STORE_CONNECT_KEY_P8` — the whole file, `-----BEGIN PRIVATE KEY-----` line included

**Sparkle EdDSA keypair.** Ed25519, so any 32 random bytes are a valid private key:

```bash
python3 -c "import os,base64;print(base64.b64encode(os.urandom(32)).decode())"
```

Set that as `SPARKLE_EDDSA_PRIVATE_KEY`. The public half is derived, never stored separately
— `bb-appcast public-key` prints it, and the release workflow bakes it into `SUPublicEDKey`
from the same source so the two cannot drift. Sparkle's own `generate_keys` also works; its
64-byte export is accepted as-is.

> **Back this up somewhere durable before the first release, outside GitHub.** Installed
> copies verify updates against the public key baked into them. Lose the private key and
> every existing install loses auto-update permanently — the only remedy is asking every user
> to download a new build by hand. There is no recovery path. It is the single most valuable
> secret in this list, and unlike the certificate it cannot be reissued.

### Cutting a release

1. Bump `swift/Packaging/VERSION` and merge it to the default branch.
2. Tag that commit `vX.Y.Z` and push the tag.
3. The workflow tests, builds, signs, notarizes, staples, packages, signs the appcast entry,
   commits the feed, and opens a **draft** release.
4. Check the draft, then publish.

Two guards reject a bad tag before any secret is touched or Apple sees anything:

- **Ancestry.** The tag must be an ancestor of the default branch. Without this, anyone able
  to push a tag could ship code that never passed review.
- **Version agreement.** The tag must match `Packaging/VERSION`. A disagreement would ship a
  DMG named for one version containing another, and Sparkle would then offer an update that
  installs a version the user already has.

**Reproducing a CI failure locally.** Every step is a script, so run the same one:

```bash
Packaging/build-app.sh                                       # build failures
Packaging/sign-app.sh --app … --identity "$(security find-identity -v -p codesigning | grep 'Developer ID' | head -1 | sed 's/.*"\(.*\)"/\1/')"
SPARKLE_EDDSA_PRIVATE_KEY=… swift run bb-appcast verify --artifact … --public-key …
```

The guards are plain git and shell, so they can be checked by hand too:

```bash
git merge-base --is-ancestor v1.2.3 origin/master && echo ok
```

## 11. Troubleshooting

| Symptom | Likely cause |
|---|---|
| Build fails with odd Swift errors | Toolchain mismatch. Compare `swift --version` against `.swift-version` |
| No messages arrive; server looks healthy | Full Disk Access missing, or granted without relaunching |
| Sends fail or hang, no useful error | Automation → Messages not granted |
| Private API never connects | SIP still enabled, or a stale injected library. Check the helper connection status |
| Port already in use | Another server instance, or the Electron one on the same port |
| Tunnel rate limited | Cloudflare and ngrok both throttle. Wait, or switch providers |
| No notifications with no push provider | Expected. Socket-only installs deliver over the socket |
| Clients suddenly cannot authenticate | Rate limiter blocked them. Check the Security page; recover with `--clear-blocklist` |
| Parity test fails on a field you added | Working as intended. Put it behind an opt-in parameter |
| App starts, serves a few requests, then dies with "unable to find bundle" | A SwiftPM resource bundle was not copied into `Contents/Resources`. `build-app.sh` handles this; a hand-assembled bundle will not |
| `--headless` on the app does nothing when run from a launch daemon | Expected. `App` needs a WindowServer session — use `BlueBubbles.app/Contents/MacOS/bluebubbles-server` instead |
| Gatekeeper says the app is damaged | Not notarized, or notarized but not stapled. Stapling is what lets Gatekeeper verify offline |
| Notarization rejected with only a status | Read the submission log — `notarize-app.sh` fetches it automatically. A missing entitlement or an unsigned nested binary is named there |
| Release workflow refuses the tag | Either the tag is not an ancestor of the default branch, or it disagrees with `Packaging/VERSION` |
| Clients stop receiving updates after a release | The appcast signature does not verify against the shipped `SUPublicEDKey`. Run `bb-appcast verify`; this is silent by design on the client |
| A new setting does not appear in the app | It is not in `Settings.renderable`. `RenderableSettingsTests` catches this |
