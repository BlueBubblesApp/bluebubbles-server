# BlueBubbles Server (Swift) — agent guide

The BlueBubbles server: a native Swift macOS application and CLI that reads the local iMessage
database, serves an HTTP and Socket.IO API to BlueBubbles clients, and drives Messages.app for
sending. Feature-complete; current work is stability, performance and polish.

**This file is a router.** It carries only what every task needs. Everything else is a link —
follow the one that matches the task before you start editing.

---

## Read this first

Seven rules override anything you would otherwise infer from the code.

1. **Client compatibility outranks everything, including security fixes.** Shipped clients are
   not under our control and cannot be updated in step with the server. The route table, the
   response envelopes and the event payloads a default-configured server presents are a fixed
   contract, enforced mechanically by the parity harness. A fix that would require a client to
   change ships behind a setting, or is deferred.
   → [`.claude/docs/decisions.md`](.claude/docs/decisions.md)

2. **`chat.db` is Apple's, and it is opened read-only by construction.** Never add a write path.
   Never `SELECT *` against it. → [`.claude/docs/database.md`](.claude/docs/database.md)

3. **Chat GUIDs are not stable and not comparable.** They differ **between servers on the same
   iCloud account**, and macOS 26 rewrote every prefix to the literal `any`. Never compare with
   `==`, never derive a service from the prefix, never write `c.guid = ?`, never hard-code one.
   Use `ChatGUID.sameChat(_:_:)` and `ChatGUID.lookupCandidates()`.
   → [`.claude/docs/imessage.md`](.claude/docs/imessage.md)

4. **The injected helper runs inside a sandboxed app and cannot reach outside its container.**
   That is why the Private API socket lives inside Messages'/FaceTime's own container, why there
   is **one socket per app**, and why `NSHomeDirectory()` must never be used for a path both sides
   compute. → [`.claude/docs/private-api.md`](.claude/docs/private-api.md)

5. **The deployment floor is macOS 14 (Sonoma), and version guards belong at the *top* of the
   range.** `Package.swift` declares `.macOS(.v14)`. Nothing below Sonoma needs a branch, a
   fallback or an `@available`; anything that only serves an older release is dead code. Guard
   **newer** surface instead — `if #available(macOS 26, *)` plus a runtime `NSClassFromString` /
   `respondsToSelector` check, since Apple removes API as well as adding it.

6. **Never put real phone numbers, emails or message content in tests or fixtures.**
   `Tests/CompatibilityTests/TestDataPolicyTests.swift` fails the build if you do.

7. **Odd-looking code is usually load-bearing.** Duplicate routes, a route order that looks
   arbitrary, timeouts that differ by orders of magnitude, a `Double` where an `Int` would
   do — these are transcriptions of client-observable behaviour. The file header almost always
   says why. Read it before "cleaning up".

---

## Where to go

| If the task is about | Read |
|---|---|
| Module graph, services, composition root, event bus, layering | [`.claude/docs/architecture.md`](.claude/docs/architecture.md) |
| `app.db`, `chat.db`, migrations, schema profiles, settings storage | [`.claude/docs/database.md`](.claude/docs/database.md) |
| Routes, envelopes, auth, v1 vs v2, OpenAPI, sockets | [`.claude/docs/api.md`](.claude/docs/api.md) |
| Chat GUIDs, attributedBody/typedstream, the send backends, AppleScript | [`.claude/docs/imessage.md`](.claude/docs/imessage.md) |
| Group chat creation without the Private API; the Shortcuts boundary | [`docs/SHORTCUTS.md`](docs/SHORTCUTS.md) |
| Injection, the sandbox/container, helper transport, selectors, swizzling | [`.claude/docs/private-api.md`](.claude/docs/private-api.md) |
| Memory budgets, child processes, async traps | [`.claude/docs/performance.md`](.claude/docs/performance.md) |
| Event routing, sinks, payload codecs, socket delivery | [`docs/EVENTS.md`](docs/EVENTS.md) |
| Auth modes, enrollment, access control, permissions | [`docs/AUTH.md`](docs/AUTH.md) |
| What the test suites assert and why | [`docs/TESTING.md`](docs/TESTING.md) |
| Why something is the way it is; what is deliberately deferred | [`.claude/docs/decisions.md`](.claude/docs/decisions.md) |
| Building, running, testing, and what CI will fail you on | [`.claude/docs/workflow.md`](.claude/docs/workflow.md) |
| Naming — DB columns, settings keys, wire keys, spelling | [`docs/NAMING.md`](docs/NAMING.md) |
| Selector-level IMCore reference, per-macOS differences | [`docs/PRIVATE_API_SURFACE.md`](docs/PRIVATE_API_SURFACE.md), [`docs/SEQUOIA_COMPATIBILITY.md`](docs/SEQUOIA_COMPATIBILITY.md) |

Nested `CLAUDE.md` files load automatically when you touch files under them:
`Sources/BBInterfaces/`, `Sources/BBHandlers/`, `Sources/BlueBubblesServerCore/`,
`Sources/BBPersistence/`, `Helper/`.

**Two skills cover the multi-step jobs that are easy to get wrong. Invoke them rather than
improvising the order:**

| Skill | For |
|---|---|
| `add-api-route` | Adding, changing or removing an endpoint; a failing route-table, parity or OpenAPI check |
| `implement-imcore-method` | Implementing a `notImplemented` helper stub, adding an IMCore call or inbound event, chasing a vanished selector |

---

## Where do I add…?

| To add | Go to |
|---|---|
| A setting | `Sources/BBSettings/SettingsRegistry.swift` — declare a `Setting<T>` with `presentation:` and add it to `Settings.renderable` (or `Settings.hidden` if it has no UI). `allKeys` is derived. Mark it `application: .composition` if only a restart applies it. Never write a key as a string literal elsewhere: use `Settings.x.key` |
| An API route | `Sources/BBHTTPAPI/RouteTable.swift` (or `AdditiveRoutes` if Node does not have it), then a handler in `Sources/BBHandlers/` |
| Logic behind a route | `Sources/BBInterfaces/` — **not** the handler. Interfaces return typed values; one `serialize` step projects them. Anything reaching Messages goes inside `throughMessages { … }` |
| A capability a handler, service or view may reach | `Sources/BBInterfaces/Capabilities.swift`, then conform `AppContext` in `AppContextCapabilities.swift`. Never take the whole `AppContext` |
| A setup (onboarding) step | `Sources/BlueBubblesApp/Onboarding/OnboardingFlow.swift` — a case in `OnboardingStep.ID`, an entry in `OnboardingCatalog.steps` with its `isIncluded` rule and `gate`, and a view case in `Views/Onboarding/OnboardingSteps.swift` (the switch is exhaustive). Build the view from the settings screens that already exist; never a second copy of a control |
| A page in the app | `Sources/BlueBubblesApp/Views/` — reach state through `AppModel`, never `AppContext`. State with its own lifetime goes on a child model in `Sources/BlueBubblesApp/Models/` (`PermissionsModel`, `AlertsModel`, `UpdatesModel`, `IntegrationsModel`) that attaches in `start` and detaches in `stop`; `AppModel` is the root that owns phase, navigation and lifetime |
| A service | One file per service under `Sources/BlueBubblesServerCore/Composition/Services/`, conforming to `ContextualService`; declare its manifest in `BuiltInManifests.swift` and register it in `ServerComposition`. Start order is derived from `dependencies` |
| A table in `app.db` | A `SchemaContributor` in the module that owns it, then append it to `AppSchema.contributors`. **Not** `AppDatabase` — see [`Sources/BBPersistence/CLAUDE.md`](Sources/BBPersistence/CLAUDE.md) |
| An event | `Sources/BBEvents/ServerEvent.swift` plus its per-sink projection |
| A user-visible alert | Raise it explicitly through `BBDiagnostics`. Logging must never produce one |
| A Private API call | `Helper/BBPrivateAPIContract` first, then `Helper/BlueBubblesHelper`. Go through `IMCoreRuntime`, never IMCore directly |
| An external binary a service runs | A `ManagedToolDescriptor` on its manifest (`BuiltInTools.swift`). Do not write a downloader |

---

## Non-negotiables that a compiler will not catch

- **Never construct `Process`.** Use `BBCore/Subprocess.swift`. Its timeout argument is
  required on purpose. The one exception is `BBProxy/DaemonProcess`, and it stays the exception.
- **Never log a secret.** Anything from a setting marked `isSecret` is wrapped as
  `DiagnosticValue.secret` and renders as `••••`. Keep it that way.
- **Migrations are append-only.** Never edit a released one. Rename via a new migration.
- **The plugin manifest surface is frozen.** Third-party plugins are wanted but are not being
  built now, so `BBServiceKit` is closed to new capability: no new entitlement kinds, no new
  manifest fields for hypothetical plugin needs, no widening of the tool or migration
  descriptors. A field a *built-in* service needs today is fine; a field a future plugin might
  want is not. See the header of `Sources/BBServiceKit/ServiceManifest.swift`.
- **`Package.swift` must match the imports.** `python3 Tools/package-graph/check.py` fails CI
  when a target declares an unused dependency or imports an undeclared module — neither is
  visible to the compiler.
- **British spelling** in prose and in identifiers we own (`colour`, `behaviour`, `offence`).
  Apple's API names keep theirs.
- **Only two things may cap a dependency version:** the macOS 14 (Sonoma) floor and the pinned
  Swift toolchain. An API rename or a deprecation is work to do, not a reason to pin back. Check a
  dependency's **availability macros**, not just its `platforms:` — Hummingbird declares
  `.macOS(.v11)` and then gates its entire public API behind `@available(macOS 14)`, which is what
  set the floor.
- **Without the Private API the server is limited to what AppleScript can do** — send text, send
  an attachment, start a **one-to-one** chat. Group creation needs the Private API or the
  user-installed Shortcut (`BBShortcuts`); AppleScript has had no group path since Big Sur, three
  releases below our floor. 60 of 148 routes are gated on `requires: .privateAPI`. Both
  configurations are supported; only one is capable. Gate the route, and make the capability
  discoverable before a client tries. → [`.claude/docs/imessage.md`](.claude/docs/imessage.md)
- **Every call that reaches Messages goes through `throughMessages { … }`.** An unwrapped one
  compiles, passes, and reports each Messages refusal as a generic 500 `Server Error` instead of
  the `iMessage Error` clients branch on. The interface conforms to `MessagesBackedInterface`,
  which also supplies `requirePrivateAPI(for:)` — do not hand-roll either; they were duplicated
  three times before it existed. → [`Sources/BBInterfaces/CLAUDE.md`](Sources/BBInterfaces/CLAUDE.md)
- **A module is not done until the composition root calls it and a test asserts that call
  exists.** `Tests/CompositionTests/EventDeliveryWiringTests.swift` is the pattern.
- **A route added to `RouteTable.groups` that Node does not have fails the parity test.**
  It belongs in `AdditiveRoutes`.

---

## Fast commands

```bash
swift build && swift test
swift test --filter BBSettingsTests
swift run bluebubbles-server --headless --set socket_port=1234 --set password=dev-password
Tools/dev-bundle.sh --run          # required for anything permission-shaped
swift format lint --strict --recursive Sources Tests Helper
python3 Tools/package-graph/check.py
```

Full loop, including the generated-artifact checks CI runs → [`.claude/docs/workflow.md`](.claude/docs/workflow.md).

---

## Reference documents (long; read a section, not the file)

| Document | Size | What it is good for |
|---|---|---|
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | ~56 KB | Human setup, permissions, SIP, signing, releases |
| [`TODO.md`](TODO.md) | ~52 KB | Outstanding work |
| [`docs/api/README.md`](docs/api/README.md) | ~25 KB | The REST API explained in prose |
| [`docs/PRIVATE_API_SURFACE.md`](docs/PRIVATE_API_SURFACE.md) | ~47 KB | Every IMCore call and its selectors |
| [`docs/SEQUOIA_COMPATIBILITY.md`](docs/SEQUOIA_COMPATIBILITY.md) | ~37 KB | Per-macOS-version differences |
| [`docs/OBSERVATION_LADDER.md`](docs/OBSERVATION_LADDER.md) | ~21 KB | How each inbound event is observed, and the fallbacks |
| [`docs/TESTING.md`](docs/TESTING.md) | ~10 KB | **What** the suites assert and why |
| [`docs/EVENTS.md`](docs/EVENTS.md) | ~9 KB | Event routing, sinks, payload codecs, socket delivery |
| [`docs/AUTH.md`](docs/AUTH.md) | ~10 KB | Auth modes, enrollment, access control, permissions |
| [`docs/SHORTCUTS.md`](docs/SHORTCUTS.md) | ~13 KB | Why AppleScript cannot create group chats, and what Shortcuts can and cannot do |

**Source file headers are the primary documentation.** Most files open with 10–25 lines
explaining the design and the failure it prevents. Read the header before changing the file.
