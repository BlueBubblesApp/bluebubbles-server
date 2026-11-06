# BlueBubbles Server (Swift): agent guide

The BlueBubbles server: a native Swift macOS application and CLI that reads the local iMessage
database, serves an HTTP and Socket.IO API to BlueBubbles clients, and drives Messages.app for
sending.

**This file is a router.** It carries only what every task needs. Everything else is a link:
follow the one that matches the task before you start editing.

---

## Read this first

Ten rules override anything you would otherwise infer from the code.

1. **Client compatibility outranks everything, including security fixes.** Shipped clients are
   not under our control and cannot be updated in step with the server. The route table, the
   response envelopes and the event payloads a default-configured server presents are a fixed
   contract, enforced mechanically by the parity harness. A fix that would require a client to
   change ships behind a setting, or is deferred. Three statements of what frozen means:

   - **Every field the reference's v1 response carries must be present in ours**, at the same
     path, with the same type. A MISSING field is the break. An extra field is tolerable, but
     the parity diff reports it as drift, so an addition you meant goes in
     `acceptedDifferences` (`Sources/BBParity/ResponseDiff.swift`) with a line saying what it
     is, knowing it becomes a contract the moment a client reads it.
   - **Frozen means the fields, not the wording.** The envelope's `message` and the error's
     `error.message` may be reworded or made specific to the request. The key they sit under,
     the status code and `error.type` may not: those are what a client branches on.
   - **Values are not wording.** Every content value must match what the reference would send
     for the same data, type and encoding included. The one exception is `id` on the contact
     routes, and a second needs the same two things: the client checked, and the divergence
     written down.

   → [`.claude/docs/decisions.md`](.claude/docs/decisions.md#messages-are-ours-to-word), and
   "Additions to a v1 response are drift until accepted" in the same file.

2. **`chat.db` is Apple's, and it is opened read-only by construction.** Never add a write path.
   Never `SELECT *` against it. → [`.claude/docs/database.md`](.claude/docs/database.md)

3. **Chat GUIDs are not stable and not comparable.** They differ **between servers on the same
   iCloud account**, and macOS 26 rewrote every prefix to the literal `any`. Never compare with
   `==`, never derive a service from the prefix, never write `c.guid = ?`, never hard-code one.
   Use `ChatGUID.sameChat(_:_:)` and `ChatGUID.lookupCandidates()`; in SQL, the one clause
   producer is `MessageQueryPlan.chatCondition`, and `ChatGUIDClausePolicyTests` enforces it.
   → [`.claude/docs/imessage.md`](.claude/docs/imessage.md)

4. **A helper is built for the slice of the app it is injected INTO, never the slice this
   server runs.** On Apple Silicon, Messages.app and FaceTime.app run **`arm64e`**
   (`lipo -archs` reports `x86_64 arm64e` for both), and dyld **will not** load an `arm64`
   dylib into an `arm64e` process. It reports nothing when it declines: the insert is skipped,
   the app launches normally, and the Private API is simply absent: no crash, no log line, no
   failed request. So the two dylibs are built `arm64e + x86_64` while the app and the CLI stay
   `arm64 + x86_64`, which is why there is a SECOND `swift build` for them that asserts the
   slices with `lipo` before anything is copied. It has one implementation,
   `bb_build_injected` in `Tools/helper-build.sh`, which `Packaging/build-app.sh`,
   `Tools/dev-bundle.sh` and the observation probe (`Tools/observation-probe/run-probe.sh`)
   all call; `ToolScriptTests` fails the build on a helper build or a dylib slice check
   anywhere else. Never take a helper from a plain `swift build`; never "simplify" the second
   build away. `private_api_helper_path` exists to name an arm64e build when running from
   `.build`.

5. **The injected helper runs inside a sandboxed app and cannot reach outside its container.**
   That is why the Private API socket lives inside Messages'/FaceTime's own container, why there
   is **one socket per app**, and why `NSHomeDirectory()` must never be used for a path both sides
   compute. → [`.claude/docs/private-api.md`](.claude/docs/private-api.md)

6. **The deployment floor is macOS 14 (Sonoma), and version guards belong at the *top* of the
   range.** `Package.swift` declares `.macOS(.v14)`. Nothing below Sonoma needs a branch, a
   fallback or an `@available`; anything that only serves an older release is dead code. Guard
   **newer** surface instead: `if #available(macOS 26, *)` plus a runtime `NSClassFromString` /
   `respondsToSelector` check, since Apple removes API as well as adding it.

7. **Never put real phone numbers, emails or message content in tests or fixtures.**
   `Tests/SourcePolicyTests/TestDataPolicyTests.swift` fails the build if you do.

8. **Say what the reference does only when you have looked, and say it as a fact.** Every
   statement about v1 behaviour is a claim about the wire, held by a recorded fixture or a
   parity test, and written in the present tense. Never point into another repository's
   source: no TypeScript, Dart or Objective-C helper file name, no line number. This
   repository is the source of truth, and `ReferenceCitationPolicyTests` fails the build on a
   pointer. Confident prose with nothing
   behind it is the single most expensive failure mode this project has:
   `CompatibilityContractTests` opened with "Replays fixtures recorded from the running Node
   server" and replayed nothing for months. **Check it or find out**: the procedure is the
   `verify-a-claim` skill.

   **And before citing it, ask whether it is even relevant.** The reference constrains the v1
   WIRE: status codes, `error.type`, envelope keys, payload shapes, the route table. It does
   not constrain how this server is built. We are MODELLED on the Electron server, not a
   transcription of it, and "the reference does it this way" is not an argument for anything
   a client cannot see. Every reference claim found FALSE here was an appeal about an
   internal, never about the wire, because the wire is diffed and prose is not. **If a client
   cannot observe it, justify it on the merits and leave the reference out of it.**
   → [`.claude/docs/decisions.md`](.claude/docs/decisions.md#what-the-contract-does-not-constrain)

9. **A service declares every setting it touches, and the declaration is enforced.** Reads and
   writes go through `ScopedSettings`; an undeclared one THROWS, and a service is handed only
   the scope (`ScopedSettingsProviding`), never the store. There is no trusted tier: a
   built-in is checked exactly like a plugin, because built-ins are the worked examples a
   plugin author copies. The permissions list names a setting by its STORAGE KEY, never its
   label, and a secret is never declarable: a service needing a credential checked asks the
   host to check it.
   → [`.claude/docs/architecture.md`](.claude/docs/architecture.md#a-permissions-list-names-a-setting-by-its-storage-key)

10. **Odd-looking code is usually load-bearing.** Duplicate routes, a route order that looks
   arbitrary, timeouts that differ by orders of magnitude, a `Double` where an `Int` would
   do: these are transcriptions of client-observable behaviour. The file header almost always
   says why. Read it before "cleaning up".

---

## Where to go

| If the task is about | Read |
|---|---|
| Module graph, services, composition root, event bus, layering | [`.claude/docs/architecture.md`](.claude/docs/architecture.md) |
| `app.db`, `chat.db`, migrations, schema profiles, settings storage | [`.claude/docs/database.md`](.claude/docs/database.md) |
| Routes, envelopes, auth, v1 vs v2, OpenAPI, sockets | [`.claude/docs/api.md`](.claude/docs/api.md) |
| Chat GUIDs, attributedBody/typedstream, the send backends, AppleScript | [`.claude/docs/imessage.md`](.claude/docs/imessage.md) |
| The SwiftUI app: facades, follows, Home, the view rules and why | [`.claude/docs/app.md`](.claude/docs/app.md) |
| Group chat creation without the Private API; the Shortcuts boundary | [`docs/SHORTCUTS.md`](docs/SHORTCUTS.md) |
| Injection, the sandbox/container, helper transport, selectors, swizzling | [`.claude/docs/private-api.md`](.claude/docs/private-api.md) |
| Memory budgets, child processes, async traps | [`.claude/docs/performance.md`](.claude/docs/performance.md) |
| Event routing, sinks, payload codecs, socket delivery | [`docs/EVENTS.md`](docs/EVENTS.md) |
| Message search: why `LIKE` finds nothing on macOS 26, and the indexed fix | [`docs/SEARCH.md`](docs/SEARCH.md) |
| Auth modes, enrollment, access control, permissions | [`docs/AUTH.md`](docs/AUTH.md) |
| The audit log: what is recorded, the record's shape, every event kind, CSV, syslog | [`docs/AUDIT_LOG.md`](docs/AUDIT_LOG.md) |
| What the test suites assert and why | [`docs/TESTING.md`](docs/TESTING.md) |
| Why something is the way it is; what is deliberately deferred | [`.claude/docs/decisions.md`](.claude/docs/decisions.md) |
| Whether a redesign you are about to propose was already tried and turned down | [`.claude/docs/rejected.md`](.claude/docs/rejected.md) |
| Building, running, testing, and what CI will fail you on | [`.claude/docs/workflow.md`](.claude/docs/workflow.md) |
| Naming: DB columns, settings keys, wire keys, spelling | [`docs/NAMING.md`](docs/NAMING.md) |
| Writing any documentation: voice, structure, formatting, and what a document may claim | [`docs/WRITING.md`](docs/WRITING.md) |
| What works on which macOS, and what needs a guard vs a ladder | [`docs/MACOS_COMPATIBILITY.md`](docs/MACOS_COMPATIBILITY.md) (start here) |
| Selector-level IMCore reference | [`docs/PRIVATE_API_SURFACE.md`](docs/PRIVATE_API_SURFACE.md) |

Nested `CLAUDE.md` files load automatically when you touch files under them:
`Sources/BBInterfaces/`, `Sources/BBHandlers/`, `Sources/BlueBubblesServerCore/`,
`Sources/BBPersistence/`, `Sources/BlueBubblesApp/`, `Helper/`.

**Six skills cover the multi-step jobs that are easy to get wrong. Invoke them rather than
improvising the order:**

| Skill | For |
|---|---|
| `add-api-route` | Adding, changing or removing an endpoint; a failing route-table, request-parameter, parity or OpenAPI check |
| `implement-imcore-method` | Implementing a `notImplemented` helper stub, adding an IMCore call or inbound event, chasing a vanished selector |
| `add-a-service` | A new subsystem with a lifecycle: its manifest, entitlements, permissions, managed tools, watched keys and wiring |
| `add-a-setting` | Declaring a setting, giving it a row, marking it secret, making it depend on a switch, letting a service read it |
| `macos-release-sweep` | A new macOS or beta; dumping headers; deciding guard against ladder; the capability catalog and the compatibility matrix |
| `verify-a-claim` | Auditing or reviewing; checking whether a comment, header or doc line is true **and** enforced; citing the reference |

---

## Where do I add…?

| To add | Go to |
|---|---|
| A setting | `Sources/BBSettings/`: declare a `Setting<T>` with `presentation:` in the `SettingsRegistry+<Section>.swift` file for its section, and add it to `Settings.renderable` (or `Settings.hidden` if it has no UI) in `SettingsRegistry.swift`. `allKeys` is derived. A `.number(range:)` control's range is ENFORCED, on writes and on `--set`/config-file overrides alike (`Setting.rangeViolation`); do not repeat it in `validate`, which is for anything else and binds writes only. Mark it `application: .composition` if only a restart applies it. Never write a key as a string literal elsewhere: use `Settings.x.key`. **If a service reads it, add it to that service's `readSettings` entitlement too**: an undeclared read throws. **If it does nothing while another switch is off, say so**: `presentation: .init(…, requires: Settings.parent.key)` greys the generated row out and names the switch to turn on, so no screen has to know the group by name. Presentation only, never a gate on reads or writes; chains are walked whole (`Settings.requirementChain`) and the row names the OUTERMOST switch that is off, because the ones under it are greyed out too. `SettingDependencyTests` enforces the shape, and pins the two settings that look like dependencies and are not |
| An API route | `Sources/BBHTTPAPI/RouteTable.swift` (or `AdditiveRoutes` if Node does not have it), then a handler in `Sources/BBHandlers/` |
| A validation rule on a v1 route | `Sources/BBHTTPAPI/ValidationRules.swift`, keyed by `HandlerID`. **Only to match the reference**: this layer exists to refuse what `validators/*.ts` refuses and nothing more, because the one way it can break a client is by being STRICTER than the reference. Regenerate `Tools/validation-rules/extract.py` and let `ValidationRuleParityTests` diff it; a divergence needs an entry in `knowinglyDivergent` with a reason. Never add a rule the reference does not have |
| A `where` filter on `/message/query` | A case on `MessageFilter` (`Sources/BBIMessage/`), its statement shape in `parse`, its SQL in `MessageQueryPlan.predicate(for:)`, and a test in `MessageFilterSQLTests` asserting the ROWS **and** the `total`. It is a typed allowlist, not the reference's SQL passthrough: anything unrecognised is a 400 naming the statement. Never accept a filter you do not apply |
| Logic behind a route | `Sources/BBInterfaces/`: **not** the handler. Interfaces return typed values; one `serialize` step projects them. Anything reaching Messages goes inside `throughMessages { … }` |
| A capability a handler, service or view may reach | `Sources/BBInterfaces/Capabilities.swift` if the app or the root composes it too, `Sources/BBHandlers/HandlerCapabilities.swift` if only a handler does, `Sources/BlueBubblesServerCore/Composition/Services/ServiceCapabilities.swift` if only a service does; then conform `AppContext` in `AppContextCapabilities.swift`. Never take the whole `AppContext` |
| A setup (onboarding) step | `Sources/BlueBubblesApp/Onboarding/OnboardingFlow.swift`: a case in `OnboardingStep.ID`, an entry in `OnboardingCatalog.steps` with its `isIncluded` rule and `gate`, and a view case in `Views/Onboarding/OnboardingSteps.swift` (the switch is exhaustive). Build the view from the settings screens that already exist; never a second copy of a control |
| A migration step (adopting an Electron install) | `Sources/BlueBubblesServerCore/Migration/MigrationState.swift`: a case on `MigrationStep`, its `isBlocking` and `prerequisite`, then the work in `MigrationRunner`. **`isBlocking` is the decision that matters**: a blocking step stops the server until the user acts, so only claim it for something whose absence means coming up on defaults with no password. This is NOT onboarding: nothing here runs without a click, and the state is per step in `app.db` so the CLI and the app agree |
| A page in the app | `Sources/BlueBubblesApp/Views/`: reach state through `AppModel` and its three facades, never `AppContext`; live state is followed from the server's streams, never polled; a read that can fail goes through `ScreenModel`; manifests come from `IntegrationCatalog`. The rules and their tests: [`Sources/BlueBubblesApp/CLAUDE.md`](Sources/BlueBubblesApp/CLAUDE.md) |
| A page in the app that is built around a `Table` | `TablePage` (`Views/Components/SettingsLayout.swift`), never `SettingsPage`. `SettingsPage` is a `ScrollView`, and a `Table` inside one has no height of its own: it loses its own scrolling and the row recycling that makes a long list cheap. Both wrap the same `PageFrame`, so the centred column is identical either way. `TablePage` also paints the window background, which the scroll view was silently providing everywhere else — without it the detail column is a transparent hole and the glass card, and the SIDEBAR beside it, sample the desktop through it |
| A validation rule on a SERVICE field (a manifest form) | `FieldValidation` on the `FieldDescriptor` (`Sources/BBServiceKit/ServiceManifest.swift`): a pattern and the message to show, as DATA so a third-party manifest can express one. `ServiceFormLayout.validationFailure` puts it under the field and `ServiceFormView.save` refuses the write. Check only what can be checked — zrok's reserved name is `[a-z0-9]{4,32}`, and its profanity screen is deliberately not modelled because the list is not published and a guess would refuse names zrok accepts. Not to be confused with `ValidationRules.swift`, which is the v1 REQUEST layer |
| What a page shows when the server is not running | `ServerStoppedNotice` (`Sources/BlueBubblesApp/Views/`) with a `placement:` (`.page`, `.section` or `.card`) and the `purpose:` as the tail of "Start the server to …". It carries the Start button; a hand-written "Server not running" fails `ServerStoppedNoticeTests` |
| An address or identifier a user will copy | `CopyableValue` (`Sources/BlueBubblesApp/Views/`), never a `Text` beside a hand-written `NSPasteboard` button. Pass the empty string for "no value yet" and say which kind of nothing it is in `placeholder:` |
| A macOS permission a service needs | A `ServicePermission` on its manifest: id, `.required`/`.recommended`/`.feature`, and a purpose sentence. `Service.requiredPermissions` derives from it; there is no protocol to conform to. **`.required` IS a start gate**: `ServiceRegistry.performStart` refuses to start a service whose required permission is missing and records why. `.recommended` and `.feature` are not gates. A grant comes back by itself: `ServiceRegistry.permissionsGranted` starts a refused service from this declaration, and a running one that has something to do conforms to `PermissionRespondingService`. What a refusal must not stop (deleting a file when a switch goes off) goes in the static `Service.beforeGates`, which runs ahead of every gate with no instance. None of them is a boundary between services — macOS grants TCC to the app, not to code inside it — and all of them are what the user is SHOWN, so they have to be accurate |
| A service | One file per service under `Sources/BlueBubblesServerCore/Composition/Services/`, declaring `typealias Host` as the capabilities it actually uses (**never `AppContext`**); declare its manifest in the `BuiltInManifests+<Family>.swift` file for its family (`+Tunnels`, `+Publishing`, `+Sinks` or `+Core`), then add it to `BuiltInManifests.all` (`Sources/BBBuiltIns/`), and register it in `ServerComposition` as `registry.register(MyService.self) { $0 }`. Start order is derived from `dependencies`. Its registry key is its manifest identifier; there is no separate service-identifier type |
| A table in `app.db` | A `SchemaContributor` in the module that owns it, then append it to `AppSchema.contributors`. **Not** `AppDatabase`; see [`Sources/BBPersistence/CLAUDE.md`](Sources/BBPersistence/CLAUDE.md) |
| An event | `Sources/BBEvents/ServerEvent.swift` plus its per-sink projection |
| A user-visible alert | Raise it explicitly through `BBDiagnostics`. Logging must never produce one |
| A Private API call | `Helper/BBPrivateAPIContract` first: a case on `MessagesHelperAction` or `FaceTimeHelperAction`, any new payload field as a case on `WireKey` (never a string literal on either side; a test fails the build on one), then the contract method **on the ROLE protocol it belongs to** (`MessageSending`, `ChatMuting`, `FaceTimeControl`, …; `PrivateAPI` composes the sixteen roles and declares nothing itself) then `Helper/BlueBubblesHelper`. Each dispatch is exhaustive over its enum, so the helper side will not compile until you handle it. Go through `IMCoreRuntime`, never IMCore directly |
| An audit event kind | A case on `AuditEventKind` (`Sources/BBAudit/AuditEventKind.swift`) spelled `<category>.<name>`, its `metadataFields` (every key the emitter writes, with a type and a sentence), and its entry in `docs/AUDIT_LOG.md`, which `AuditDocumentationTests` fails the build without. Emit it where the fact is KNOWN: an interface records what it changed, a service what it did, never a handler. Build the `AuditEvent` with no `actor:`, so the task-local `AuditContext` names who (a client inside a request, a service inside its start, the operator otherwise), unless the record is the server's own decision taken inside somebody else's request, as an automatic block is. A record carries no message content, no address other than a client's, and a secret only as `JSONValue.redacted`; a route is always the template. If nothing in the server has to import `BBAudit` to know the fact (the auth layer, the settings store), declare a protocol beside the fact and translate in `AuditWiring.swift` |
| An external binary a service runs | A `ManagedToolDescriptor` on its manifest (`Sources/BBBuiltIns/BuiltInTools.swift`). Do not write a downloader. **Declare `compatible:`**, the range of versions your code actually drives, or a copy the user already has is never used and a duplicate is downloaded beside it. It is not `recommended` (the one build we fetch) and is strictly wider; its ceiling is EXCLUSIVE, which is what keeps a published major that dropped a subcommand — zrok 2 — from being adopted off disk. Measure both bounds by running a build; a floor fails closed, refusing a copy that works |

---

## Non-negotiables that a compiler will not catch

- **Never construct `Process`.** Use `BBCore/Subprocess.swift`. Its timeout argument is
  required on purpose. The one exception is `BBProxy/DaemonProcess`, and it stays the exception.
  **Run only what a stock macOS has.** `/usr/bin/sdef`, `lipo`, `git` and the like are
  `xcode-select` stubs: on a Mac with no developer tools they do not run, and the person is
  offered an install. `sdef` refuses with Command Line Tools alone, because it needs a full
  Xcode. A developer's machine cannot show this. Read the file or the header in-process instead.
- **Never hand-roll a timeout, a wait, a retry loop or a long-running task.** `BBCore` has one
  door for each: `withTimeout(_:operation:)`;
  `awaitContinuation(timeout:timeoutError:register:abandon:)` for a wait somebody else resumes,
  storing the `OnceContinuation` it hands back and never a raw `CheckedContinuation`;
  `retrying` / `poll` with a `RetrySchedule`; and `OwnedTask`, whose `stop()` a service's
  `stop()` and an app model's `detach()` must `await`. A deadline that passes throws
  `TimedOut`; a BACKEND's timeout keeps its own case, because inside a request `TimedOut` is
  the route's 504. `OwnedTaskPolicyTests` and `ContinuationDeadlinePolicyTests`.
  → [`.claude/docs/performance.md`](.claude/docs/performance.md#timeouts-waits-retries-and-long-running-tasks-each-have-one-door)
- **Error text a person will read goes through `DiagnosticText.sentence(for:)`**, and never a
  cast chain of your own beside it: `String(describing:)` in an alert prints a Swift enum at
  the user. An error declared under `Sources/` conforms to `BBError`, or to `LocalizedError`
  where it cannot link BBCore, so there is a sentence to find; `ErrorTypePolicyTests` fails the
  build on a plain one.
  → [`.claude/docs/architecture.md`](.claude/docs/architecture.md#error-text-a-person-reads-has-one-door)
- **A control a person can press has a name.** A label containing text (`Button("Remove")`,
  `Label("Refresh", systemImage:)`) is accessible by construction. A label that is only an
  image is not: it renders correctly, it has a tooltip, and to VoiceOver it is an unnamed
  button, which a tooltip cannot fix because it needs a pointer. Add `.accessibilityLabel`
  naming the ACTION. `AccessibilityPolicyTests` fails the build otherwise. Two related habits
  that no test can check: a row of `Text`s that describes one thing takes
  `.accessibilityElement(children: .combine)` so it is one stop rather than five, and a
  decorative symbol beside text that already says the same thing takes
  `.accessibilityHidden(true)`.
- **Never log a secret, and never log a person.** A value from an `isSecret` setting is
  `DiagnosticValue.secret`; an address, a handle or a chat GUID in log metadata goes through
  `Redaction` (`BBCore/Redaction.swift`); message text, subjects, display names, file names,
  push tokens, request payloads and the server's own public URL are never logged at all.
  Message GUIDs, room names, event names, counts and durations go in freely.
  `LogRedactionPolicyTests` scans every `logger.<level>(…)` call. Levels: `info` is a state
  transition a support log wants by default, `debug` one line per unit of work, `trace`
  per-iteration chatter.
  → [`.claude/docs/architecture.md`](.claude/docs/architecture.md#what-a-log-line-carries-and-at-which-level)
- **A service that watches a key another service PUBLISHES must decide per key whether to
  restart.** `ServiceManifest.watchedSettingKeys` already subtracts what a service writes, but
  that only breaks a one-hop loop. `HTTPService` reads `server_address`, the five proxies write
  it and depend on the HTTP service, and an unconditional `.restart` respawned cloudflared
  twenty times a second forever. `HTTPService.liveKeys` is the pattern; `SettingsStore.write`
  announcing only the keys that actually moved is the backstop.
- **Migrations are append-only.** Never edit a released one. Rename via a new migration.
- **A header states the decision and the failure it prevents. It does not narrate history.**
  What the code *used to* do, what a previous pass replaced and why it was measured belong in
  git and [`.claude/docs/decisions.md`](.claude/docs/decisions.md), and an approach that was
  abandoned or turned down gets a dated row in
  [`.claude/docs/rejected.md`](.claude/docs/rejected.md) in the same change. Narrative above a
  declaration rots the moment the declaration changes: the audit found a delegate doc that
  said "NOT `.terminateLater`" above a `return .terminateLater`. When you change code under a
  comment, the comment is part of the change. **A name in code font is a pointer, and it has
  to resolve**: `CommentReferencePolicyTests` fails the build when a comment or document names
  a type, member, test or file that does not exist under that name. A former name is written
  in plain prose. → [`docs/WRITING.md`](docs/WRITING.md)
- **What Messages writes, and WHEN, can only be learned from Messages.** A fixture database has
  its rows already complete; a live one does not, and the gap is where the bugs are. Measured,
  each after passing a full green suite: an AppleScript send lands with `text` **NULL** and the
  words only in `attributedBody` (so match `universalText()`, never the column); the
  `chat_message_join` row arrives **after** the message row (so a wait for "the row exists"
  answers `chats: []`); `date_edited` moves on an unsend while `date_retracted` stays null.
  Anything that depends on the timing or completeness of what Messages writes is unverified
  until it has been run against a real send. → [`docs/TESTING.md`](docs/TESTING.md)
- **A request parameter the server accepts and ignores is worse than one it refuses.** `where`
  on `/message/query` was parsed by nobody: a client's "give me messages after ROWID n" was
  answered with the newest thousand messages and a `total` counting the whole database, with a
  200 on it. The client cannot tell. Three separate user-visible failures came out of that one
  omission (incremental sync timing out, search returning arbitrary results, notification
  hydration reading the wrong messages). Auditing the rest of the v1 surface for the same
  shape found **eleven more on nine routes**, including a full sync that imported no edits and
  an edit route that discarded the user's own fallback text because it read the reference's
  INTERNAL name for a field rather than the wire name. When a route takes an option, apply it
  or refuse it; `RequestParameterParityTests` now fails the build on a v1 parameter this
  server names nowhere, and a deliberate exception goes in its `knowinglyInert` list with the
  reason. → [`.claude/docs/api.md`](.claude/docs/api.md)
- **Read the VALIDATORS as well as the routers when citing the reference.** A Node router that
  destructures a parameter without checking it may still sit behind a validator that requires
  it: `/message/count/updated` looked like a route where we were wrongly strict, until the
  reference's message validator turned up `after: "required|numeric|min:0"` and a recorded
  400 confirmed it. The routers are half the contract.
- **A literal in a serializer is invisible to the parity diff.** The diff compares keys and
  types, so `object.set("metadata", .object([:]))` and `height: 0` passed every check for as
  long as they existed: the shape was right and the values were placeholders. When you write a
  constant into a response, either it IS the contract (and says so, with a citation) or it is a
  stub that needs a test asserting the real value. A parameter no call site passes:
  `AttachmentSerializer`'s `dimensions` is the same bug wearing a signature.
- **The plugin manifest surface is frozen.** Third-party plugins are wanted but are not being
  built now, so `BBServiceKit` is closed to new capability: no new entitlement kinds, no new
  manifest fields for hypothetical plugin needs, no widening of the tool or migration
  descriptors. A field a *built-in* service needs today is fine; a field a future plugin might
  want is not. See the header of `Sources/BBServiceKit/ServiceManifest.swift`.
- **`Package.swift` must match the imports.** `python3 Tools/package-graph/check.py` fails CI
  when a target declares an unused dependency or imports an undeclared module: neither is
  visible to the compiler.
- **British spelling** in prose and in identifiers we own (`colour`, `behaviour`, `offence`).
  Apple's API names keep theirs. The rest of how documentation is written here — voice, tense,
  headings, code font, what a document may claim — is
  [`docs/WRITING.md`](docs/WRITING.md), which follows the Google developer documentation style
  guide except where it says otherwise.
- **Only two things may cap a dependency version:** the macOS 14 (Sonoma) floor and the pinned
  Swift toolchain. An API rename or a deprecation is work to do, not a reason to pin back. Check a
  dependency's **availability macros**, not just its `platforms:`: Hummingbird declares
  `.macOS(.v11)` and then gates its entire public API behind `@available(macOS 14)`, which is what
  set the floor.
- **Without the Private API the server is limited to what AppleScript can do**: send text, send
  an attachment, start a **one-to-one** chat. Group creation needs the Private API or the
  user-installed Shortcut (`BBShortcuts`); AppleScript has had no group path since Big Sur, three
  releases below our floor. 70 of the 174 route definitions in `RouteTable.swift` are gated
  on `requires: .privateAPI`. Both
  configurations are supported; only one is capable. Gate the route, and make the capability
  discoverable before a client tries. → [`.claude/docs/imessage.md`](.claude/docs/imessage.md)
- **Every call that reaches Messages goes through `throughMessages { … }`.** An unwrapped one
  compiles, passes, and reports each Messages refusal as a generic 500 `Server Error` instead of
  the `iMessage Error` clients branch on. The interface conforms to `MessagesBackedInterface`,
  which also supplies `requirePrivateAPI(for:)`: do not hand-roll either; they were duplicated
  three times before it existed. → [`Sources/BBInterfaces/CLAUDE.md`](Sources/BBInterfaces/CLAUDE.md)
- **A module is not done until the composition root calls it and a test asserts that call
  exists.** `Tests/CompositionTests/EventDeliveryWiringTests.swift` is the pattern.
- **A route added to `RouteTable.groups` that Node does not have fails the parity test.**
  It belongs in `AdditiveRoutes`.
- **A rule the compiler cannot check ships with a test that scans the source for it.** A
  comment saying "never X" is read once; a test that greps for X runs on every build.
  **Fifty-seven** exist and are the pattern. The table in
  [`docs/TESTING.md`](docs/TESTING.md#source-scanning-policy-tests-read-through-one-scanner)
  names each with what it fails the build on, and `DocumentationDriftTests` holds that table to
  the files on disk and to this count. Each reads the tree through `SourceScanner`
  (`Tests/BBTestCore`), which decides what a comment is with a lexer rather than a `//`
  prefix, skips hidden directories, `node_modules` and agent worktrees, and throws when a scan
  finds fewer files than its floor; each prints every offender as `path:line: text`. Each frames that list with a `PolicyRule`
  (`Tests/BBTestCore/PolicyRule.swift`) saying what the rule is, how to fix an offender and
  where the rule is written, so the failure can be acted on without opening the test;
  `ScannerMessagePolicyTests` fails the build on a scanner that does not. When you
  add a "never" to this file, add the test that enforces it in the same change, and its row to
  the table; it goes in `Tests/SourcePolicyTests` unless it needs a module's types to compile.
- **A `try?` says where the failure goes.** `(try? await x) ?? []` makes "refused" and "none"
  the same value, which is how the devices page showed an empty list for a server that was
  answering 500. A `try?` is allowed when the failure is reported on another path (name it in
  the comment), when the value is a glance rather than the content (Home's count tiles), or
  on `Task.sleep`, whose only error is cancellation. Anything else propagates, and a screen
  whose content is the read goes through `ScreenModel`. A settings write is never `try?`.
- **Identity is never a display string.** An enum whose raw value is what a person reads
  (`case devices = "Devices"`) cannot be renamed without changing every comparison, every
  stored selection and, where it is one, the wire. The case is the identity, `title` is a
  computed property, and a value that goes on the wire lives on its own property with a
  comment naming the contract it serves. `Destination`, `SettingsTab` and `Repeats` are the
  shape.
- **What is built on first use is one type, not a `private var` and a flag.** On the server it
  is `LazyCollaborators`; a new on-demand subsystem goes there. A `loaded` flag beside an
  optional on a container is the shape that was replaced.

---

## Fast commands

```bash
swift build && swift test
swift test --filter BBSettingsTests
python3 Tools/package-graph/affected-tests.py --run   # only what this change can reach
swift run bluebubbles-server --headless --set socket_port=1234 --set password=dev-password
Tools/dev-bundle.sh --run          # required for anything permission-shaped
swift format lint --strict --recursive Sources Tests Helper
python3 Tools/package-graph/check.py
```

Full loop, including the generated-artifact checks CI runs → [`.claude/docs/workflow.md`](.claude/docs/workflow.md).

**A change is done when all five pass: `swift build`, the strict build
(`-Xswiftc -warnings-as-errors -Xswiftc -Wwarning -Xswiftc DeprecatedDeclaration`), the lint,
the package-graph check, and `swift test`.** Report which ran and what they said; "the tests
pass" with the strict build unrun is how a warning-as-error reaches CI. **None of the five
takes minutes**: the whole loop is under two minutes from a clean build directory, and
`swift test` past about 90 seconds is a hang rather than a slow build. The durations, and how
to tell one from the other in a single `ps`, are in
[`.claude/docs/workflow.md`](.claude/docs/workflow.md). Comments under changed
code, and the `CLAUDE.md` for the module, are part of the change; see the non-negotiables.

---

## Reference documents (long; read a section, not the file)

| Document | Size | What it is good for |
|---|---|---|
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | ~77 KB | Human setup, permissions, SIP, signing, releases |
| [`TODO.md`](TODO.md) | ~76 KB | Outstanding work, ordered by priority; finished work is deleted, not struck through |
| [`docs/api/README.md`](docs/api/README.md) | ~29 KB | The REST API explained in prose |
| [`docs/PRIVATE_API_SURFACE.md`](docs/PRIVATE_API_SURFACE.md) | ~60 KB | Every IMCore call and its selectors |
| [`docs/MACOS_COMPATIBILITY.md`](docs/MACOS_COMPATIBILITY.md) | ~39 KB | Capability and selector matrix across 14 / 15 / 26 |
| [`docs/OBSERVATION_LADDER.md`](docs/OBSERVATION_LADDER.md) | ~20 KB | How each inbound event is observed, and the fallbacks |
| [`docs/TESTING.md`](docs/TESTING.md) | ~55 KB | **What** the suites assert and why |
| [`docs/EVENTS.md`](docs/EVENTS.md) | ~22 KB | Event routing, sinks, payload codecs, socket delivery |
| [`docs/SEARCH.md`](docs/SEARCH.md) | ~39 KB | The search plan: what it costs, what it stores, what the user is told |
| [`docs/AUTH.md`](docs/AUTH.md) | ~21 KB | Auth modes, enrollment, access control, permissions |
| [`docs/SHORTCUTS.md`](docs/SHORTCUTS.md) | ~13 KB | Why AppleScript cannot create group chats, and what Shortcuts can and cannot do |
| [`docs/AUDIT_LOG.md`](docs/AUDIT_LOG.md) | ~34 KB | The audit log: every event kind and its metadata, the envelope, CSV columns, the syslog layout, SIEM and Postgres notes |

**Source file headers are the primary documentation.** Most files open with 10–25 lines
explaining the design and the failure it prevents. Read the header before changing the file.
