# Running list

Things to do or think about later. Not a backlog of everything — the docs hold the
design. This is for what we deliberately deferred, what we could not verify from here, and
what we learned late enough that it did not get folded in.

Each entry says what it is, why it is not done, and what "done" would look like, so it can be
picked up cold.

**Ordered by priority.** Section 1 is what is wrong for a user right now. Section 2 is
verification the plan claims exists and does not, plus shipping surface that no test touches
at all. Section 3 is designed-but-unbuilt surface. Sections 4 and 5 are polish and cleanup.
Within a section, roughly worst first.

---

# 1. Wrong for users now

## ~~Record the parity corpus~~ — DONE, and it found eleven bugs

53 fixtures across five status codes, recorded by `Tools/conformance-recorder` against a live
Electron server on a real Mac. Personal data is scrubbed by default — values replaced, keys
and types and the contract's own literal strings kept — so the corpus is committable.
`FixtureCorpusTests` fails if an unscrubbed one ever lands.

What it found is pinned by the parity fixtures and `Tests/BBParityTests`. All eleven are
fixed. What remains from that exercise:

- [ ] **Capture the socket transcript.** The HTTP half is recorded; the handshake and frame
      sequence are not. § Verification asks for frame-level equality against captured Node
      output across both transports and both EIO versions, and `BBSocketIOTests` covers the codec
      in isolation, which is a different claim. The recorder already has the capture path
      (`socket/polling-transcript.jsonl`, `websocket-transcript.jsonl`) — it needs a client
      driven through it.
- [ ] **Record the write paths, carefully.** The corpus is read-only on purpose: it runs
      against a real Mac, and a corpus that sent anything would send it twice, to a real
      person. Sends, reactions, edits and group management are therefore unpinned — which is
      exactly where the helper work lives. Doing this needs a dedicated throwaway conversation
      and a driver that is explicit about what it will send.
- [ ] **Make `ResponseDiff` compare elements even when array lengths differ.** This is the
      harness flaw that nearly cost six real bugs: `contact` reported one line, "length at
      data: 552 vs 587", and stopped — so an added key, two dropped keys, a missing nested `id`
      and a null `displayName` all sat behind a number that looked like an environment
      difference. The two servers will almost never hold identical data, so a length mismatch
      is the COMMON case, and today it suppresses everything inside it. Diffing the first
      element's shape regardless of length would have caught all six.
- [ ] ~~**Verify the alert wire shape against a live response.**~~ DONE `GET /server/alert` was fixed by
      reading the TypeORM entity, not by comparing — the reference's `alert` table has zero
      rows on the development Mac, so the parity run compared an empty array. Two encodings are
      still inferred rather than measured: `created`/`updated` as ISO strings, and `id` as an
      integer there against a UUID string here. Inserting one row into the reference's
      `config.db` `alert` table settles both in seconds.
- [ ] **Re-record after any Node-side change.** The fixture is a snapshot of a server that is
      still being maintained. Worth a note in the release process rather than discovering drift
      later.

## The notification payload still drops chat participants

Unchanged by the parity pass, because the parity corpus covers the HTTP surface and this is the
FCM/webhook projection. `MessageSerializerConfig.notification` sets
`loadChatParticipants: false`; the reference inherits `true` from `DEFAULT_MESSAGE_CONFIG` and
only strips participants when the payload exceeds 4000 bytes. So every push notification for a
group chat carries less than it does today — and the size cap, which exists precisely to drop
participants, can never fire because there is nothing there to drop.

`Services.event(for:serializer:)` compounds it: both projections are built from an empty
`MessageSerializer.Context()`, so no participants are loaded for either.

- [ ] Load participants for the notification projection, with a per-chat cache for the fan-out
      (the reference keeps a `chatCache` in `serializeList` for the same reason). Done = a group
      message's FCM payload carries `chats[0].participants`, and `NotificationSizeCapTests`
      proves the cap trims them when it must.

## ngrok's auth token is passed on the command line

`Tunnels.ngrok` appends `--authtoken <secret>` to the process arguments. A process's arguments
are world-readable on macOS — any local account can run `ps` and read it — which is the exact
thing `CloudflareOptions.environment` exists to avoid, documented there at length, and pinned
by `CloudflareArgumentTests`' "The tunnel token never appears on the command line". The rule
was applied to one tunnel and not the other, and no ngrok argument test exists to have caught
it.

- [ ] Move it to `NGROK_AUTHTOKEN` in the daemon's environment, which is ngrok's own name for
      the flag, and extend the cloudflared assertion to cover every tunnel rather than one.
      Pair it with the missing ngrok/zrok argument tests in § 2.

## Keychain items are readable by any same-user process

§ Security #1 asks for Keychain items whose ACL is "bound to the app's code signature rather
than being readable by any same-user process". `SecretStore` sets
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and no `SecAccessControl` at all, so the second
half was never built — the password, the FCM service account and the tunnel tokens are
readable by anything running as the user. The accessibility attribute is the right floor and
is not the claim.

- [ ] Add a `SecAccessControl` bound to the signing identity, decide what happens to items
      written before it (they cannot be re-ACLed in place — read, delete, rewrite), and assert
      it. This has to land before the § Security regression suite can honestly claim #1.

## `new-findmy-location` has a rung-1 path and is still unwired

Established and not acted on. Observe `__kIMFMFSessionLocationReceivedNotification` (object: an
`IMFindMyHandle`, userInfo: nil), read the position with `findMyLocationForFindMyHandle:`, and
push it through `FindMyFriendsCache`, whose merge rules already decide what counts as a change
worth emitting. `EventObservation` is where the observer goes — it reaches rung 2 for typing
and swizzles nothing, so this would be its second rung-1 tenant.

- [ ] Wire it. The open decision is emission policy, not discovery: a position can update every
      few seconds, `CoalescingRateLimiter` exists for exactly this, and nobody has picked an
      interval.
- [ ] **`aliases-removed` deserves the same second look.**
      `__kIMAccountAliasesChangedNotification` IS in IMCore as a string literal. The earlier
      "not exported" finding was the wrong test — the identical false negative that stalled
      FindMy for a release. If it fires on removal as well as addition, the rung-3 swizzle of
      `IMAccount._registrationStatusChanged:` can go.

## The zrok enable step was never ported

`zrok_token` is read by nothing. The setting and its name are correct — it is the ACCOUNT
token, which the Node server passes to `zrok enable <token>` (`ZrokManager.setToken`) as a
UI-invoked setup action, separately from `zrok_reserved_token`/`zrok_reserved_name`. This port
only ever runs `zrok share`, so a user who enters their account token gets a tunnel that fails
on an unenabled environment with nothing explaining why.

- [ ] Port `enable`, including both known outcomes — "you already have an enabled environment"
      is success, `enableUnauthorized` means a bad token — plus the `disable` counterpart the
      Electron UI exposes.

## `disabled_services` is written by the UI and read by nobody

The Enabled toggle on every additive integration writes this key. `ServiceRegistry` gates only
on `GatedService.canRun()` and declared permissions, so switching off Webhooks, Push, Contacts,
the Message Watcher or Scheduled Messages appears to work and the service keeps running.
Private API is the confusing case: it has a real gate in `enable_private_api`, so it has two
switches and only one of them does anything.

- [ ] A `GatedService` check reading the deny-list finishes it.

## `private_api_mode` restarts a service and changes nothing

It is in `PrivateAPIGatedService.watchedSettings`, so changing it restarts the Private API
service — and nothing reads it to choose a mode. A setting that visibly does something and has
no effect is harder to diagnose than one that does nothing at all.

- [ ] Either implement the second mode or delete the setting and its watch.

## The server injects the wrong architecture in debug builds

`swift build` produces an arm64 dylib; Messages runs arm64e, so the server's own injection
fails with a correct and clear error while a manually built `--arch arm64e` helper works fine.
Release builds are universal, so users are unaffected — but it makes the Private API
untestable from a plain debug build, which is the configuration a contributor has.

- [ ] Either `DylibInjector` prefers an arm64e slice built alongside, or `Tools/dev-bundle.sh`
      builds one.

---

# 2. Verification the plan claims and CI does not do, and code nothing tests

## v1 send routes answer `{guid, backend}`; the Node fixture answers the Message

`POST /api/v1/message/text` (and the attachment, reaction and multipart sends) return
`MessageInterface.serialize(SendOutcome)` — a GUID and the backend that sent it — with
`message: "Message sent!"`. The recorded Node fixture
(`Fixtures/http/post_api_v1_message_text-5baa61-200.json`) carries the serialised Message
row. Clients that read the returned message (text, date, handle) get less than they used to.
The compatibility suite does not diff send routes, which is why this survived the corpus.
Done looks like: after a Private API send, poll `chat.db` for the row by GUID (bounded, as the
AppleScript path already does) and serialise it; keep `backend` as an additive field; add the
send routes to the parity diff with the GUID and dates masked.

## Two tests are timing-sensitive under a loaded machine

`HelperRoundTripTests` ("unknown action is reported differently") once hit its 5 s socket
timeout during a full parallel run and passed in isolation and on two reruns.
`SignalOwnershipTests` ("Stopping is driven by cancellation") once found its port in use.
Neither reproduced. Done looks like: the round trip uses a longer timeout under `swift test`,
and the signal test binds port 0 and reads the bound port back rather than choosing one.


## The parity corpus is recorded, committed, and never replayed

The worst one in this section, because the claim it invalidates is the project's central one.
`CompatibilityContractTests` opens with "Replays fixtures recorded from the running Node server
against the Swift server" and does not: `FixtureCorpusTests` checks the directory exists, has
at least 40 files and carries no personal data, and `StrictDiffTests` unit-tests `ResponseDiff`
against hand-built dictionaries. **No test in the suite feeds a recorded request into this
server.** The 53 fixtures were diffed once, by hand, through `bb-parity`, and have been inert
in CI ever since — so "the compatibility contract is mechanically enforced" is, today, "it was
enforced on one afternoon on one Mac".

- [ ] **Replay them.** Mount the router in-process the way `PathParameterTests` does, issue each
      fixture's method/path/body against it, and diff both ways. This is the highest
      return in the file: 53 fixtures already recorded, an already-shared diff engine, and the
      only missing piece is the driver.
- [ ] **Nothing compares response HEADERS.** `Sources/BBParity` contains no occurrence of
      `header` — the recorder captures them, the diff ignores them. So all four "Misc" contract
      rows in § 11 are asserted by nothing: wide-open CORS, `?pretty`, the 504 timeout body, and
      `Content-Disposition` on file streams. **It has already diverged:** the recorded Node
      responses carry `access-control-allow-methods` on ordinary 200s, and `CORSMiddleware`
      sends that header only on `OPTIONS` while adding an `allow-headers` Node does not send.
      Two servers, different headers, every response, and every harness in the repo blind to it.
- [ ] **55 of the 98 v1 routes have no fixture at all** — 43 are covered. The "record the write
      paths, carefully" item above covers the sends; it does not cover the EIGHTEEN uncovered
      routes that write only to the SERVER's own database and send nothing to a person:
      `POST`/`DELETE` `/backup/theme` and `/backup/settings`, `POST /webhook` and
      `DELETE /webhook/:id`, `POST /server/alert/read`, `POST /fcm/device`, the four
      `/message/schedule` routes, and the six `/contact` writes including `import/vcf`. Those
      can be recorded today, against a throwaway server, with no risk to anyone.

## `Query.parse` is in the path of every read and has no test

`MessageInterface.Query.parse` and `ChatInterface.Query.parse` turn a client's request body
into a repository query: `with=` relation expansion, `limit`, `offset`, `sort`. The layer below
is covered hard (`MessageRepositoryTests`) and the layer above is too (`MessageSerializerTests`,
`WireFormatTests`); the translation between them is covered by nothing. A regression here
changes what every client receives while every unit test stays green.

The `with: [handle, chat, attachment]` behaviour IS pinned — in `post_api_v1_message_query`
and `post_api_v1_chat_query`, two of the fixtures nothing replays. Fixing the item above fixes
much of this one, which is an argument for doing them together.

- [ ] Table-test both `parse` implementations directly: each relation name, unknown names,
      missing keys, `sort` casing, and the limit/offset defaults.

## The helper's 40-command vocabulary is tested seven commands deep

`HelperDispatch` has 40 `case` arms. `HelperRoundTripTests` proves the pattern works — "Every
FindMy action is recognised by the helper" drives the real dispatch and asserts none of them
answer "unknown action" — and it was never extended past FindMy. `send-multipart`,
`send-reaction`, `edit-message`, `create-chat`, `update-group-photo`, `modify-active-alias`,
`download-purged-attachment` and about twenty-five others appear in no test at all.

Nothing asserts the two vocabularies AGREE, either. `PrivateAPIClient` writes command strings
and `HelperDispatch` reads them; a rename on one side compiles cleanly on both and fails at
runtime, on a user's Mac, as a silently dead feature. That is the same shape as the
parameterised-route bug `PathParameterTests` was written for.

- [ ] Extend the FindMy round-trip to every action in the contract, and add the set-equality
      test: every command `PrivateAPIClient` can send is a command the helper recognises.
      Highest blast-radius-to-effort ratio in this section — one test over two tables.

## Scope enforcement is asserted by nothing, and there are two of it

§ Verification: "Assert scope enforcement rejects a write on a read-only credential." No test
in the suite produces a 403. Only meaningful with `auth_mode` flipped on, which is why it has
survived — but it is the mechanism the whole dormant token design is judged by.

`ScopeEnforcement.authorize` in `BBAuth` has **no caller**. The live path is
`AuthenticationStage.authorize`, called from `HTTPServer`, and it throws a different error
type. Two implementations, one dead, neither tested.

- [ ] Delete the dead one, then assert a narrow-scope device is refused on a write route and
      allowed on a read route.

## `chat.db` is never written — asserted structurally, never at runtime

The read-only handle exposes no write API, so a write does not compile. That is the strongest
half and it is in place. Neither runtime check § Verification asks for exists:

- [ ] **The byte-identical assertion.** Open a fixture database, snapshot the bytes and mtime
      of it, its `-wal` and its `-shm`, run the full read surface (every repository method,
      every poller pass, a complete serialization cycle), and assert all three are unchanged.
      Also assert the connection reports `SQLITE_OPEN_READONLY` and that `immutable` is NOT set.
- [ ] **The compile-failure test** proving a write does not build.

## `explainQueryPlan` is public, written, and called by nothing

§ Verification asks CI to run `EXPLAIN QUERY PLAN` over every `chat.db` query and fail any that
full-scans `message`. `ReadOnlyDatabase.explainQueryPlan` exists for this and has no caller;
the only query-plan assertion in the suite is over the contacts index, which is our own table.
We cannot add indexes to `chat.db`, so a query that misses the ones Apple ships is a defect —
and it is the kind that only hurts on the old hardware § 10 is written for.

- [ ] Enumerate the repository's SQL and assert each plan against a fixture database.

## The schema-profile matrix is not exercised

Exactly one `SchemaProfile` is constructed anywhere in the tests. § 6 and § Verification ask
for the full read surface across all three profiles, asserting that columns absent from a
profile produce ABSENT fields rather than nulls — including the case that bites hardest, a
table present in Sonoma and gone in Sequoia (`message_processing_task`).

- [ ] Parameterise the serializer and repository tests over the three profiles.

## The four-configuration deployment matrix is not a test dimension

§ Verification: every phase's integration tests run against socket-only, webhook/ntfy-only,
full FCM, and each of those with and without the Private API. Sink independence is unit-tested
(`EventBusTests`) and that is a narrower claim. Specifically missing: the assertion that a
socket-only install starts with **zero warnings**.

- [ ] Make it a real matrix, or write down that the unit-level coverage is what we accept and
      why.

## Idle memory and the soak are unasserted

`MemoryBudgetTests` covers the +40 MB query budget and the no-accumulation property, both
measurable from a test runner. § 10's "< 60 MB idle, headless, socket-only" and "< 150 MB with
UI open" are not — a test host carries the whole test bundle — so they need the shipped binary
and a soak harness that does not exist. The 24-hour flat-curve soak is in the same position.

- [ ] Build the harness. This is the number the whole § 10 tactic list is justified by, on a
      project whose stated target is an old Mac mini.

## macOS versions other than the host

The floor is **macOS 14 (Sonoma)** through **Tahoe (26)**. Every private-API finding in this
project was measured on Tahoe, because that is the host, and at least one conclusion drawn that
way has already turned out to be backwards. **These need headers or a real machine per version,
not more reasoning.**

- [ ] **Run `IMCoreSelectorTests` on Sonoma, Sequoia and Ventura.** It pins ~30 IMCore
      selectors, and a red test names the selector that moved, which is the whole diagnosis. On
      the host it passes; nothing says it does anywhere else.
- [ ] **Re-check every `unavailableOnThisOS` branch per version.** Each was derived from
      Tahoe-only probing, so a branch may be exactly inverted on an older OS — reporting "your
      macOS cannot do this" on a macOS that can. Current sites: `shareNickname`
      (`IMNicknameController`), `setPinned` (falls back to
      `setPinnedConversationIdentifiers:withUpdateReason:`, which is what the reference targets
      and which Tahoe has REMOVED), and FindMy's two modern-session-only calls,
      `refreshFindMyLocation` and `requestFindMyLocationShare`, which report unavailable when
      `fmlSession` is nil — the branch most likely to be hit on an older OS, where the legacy
      `FMFSession` is live, and it has never run there.
- [ ] **Check ChatKit's availability at all.** It is Mac Catalyst and ships inside
      `/System/iOSSupport`. Present on Tahoe; the further back we go the less certain that is,
      and the whole send path now depends on it.
- [ ] **Confirm the ChatKit attachment path exists pre-Tahoe.** Attachment sending goes through
      `CKMediaObjectManager`, and the IMCore path it replaced is dead on Tahoe for sandbox
      reasons. Whether the older path is the one that works on Sonoma/Ventura is unmeasured —
      this may have to stay a runtime fork rather than a straight replacement.
- [ ] **Check `IMChat.deleteChatItems:` on older versions.** We moved off the reference's
      `CKChatController.deleteChatItem:` because a headless controller silently deletes nothing
      on Tahoe. `deleteChatItems:` is the model-layer call and is likely older and more stable,
      but that is an assumption.

## Confirm the rung-2 handler is CALLED, not just registered

Registration is proven on macOS 26.5.2 — the helper reports `events: "daemon-listener"` and the
server logs it. Delivery is not: an outgoing send does not fire `messageReceived:`, so
confirming it needs an inbound message from another device while the helper is injected.
Done = a `started-typing` event reaching the server when someone types in a chat. If the
handler turns out NOT to be called alongside Messages' own, rung 3 (swizzling
`IMChat._handleIncomingItem:`) is the fallback and `EventObservation` is where it goes.

## Run the guided Firebase setup against real Google, once, start to finish

Everything below the HTTP boundary is exercised by `ProvisioningTests` against a scripted
Google, and that harness is what found three defects in a flow that had never executed. A
scripted Google only ever answers the way the script was written. Three things it cannot tell
us: whether the ordering waits are long enough on a real account (the service-account key takes
minutes to appear), whether `FirebaseProvisioner.requiredServices` is complete on a brand-new
project, and whether Firestore creation now hits the billing wall on every new project rather
than some. Done = a project created end to end and a notification received on a device.

- [ ] **Confirm the `addFirebase` 403 path** while doing it. The reference falls back to walking
      the user through creating the project by hand in the console, which it apparently does
      often enough to be worth 30 lines. This port throws instead. If the fallback is still
      needed it belongs in `FirebaseView` as a guided step, not as an error.

## Signing, notarization and stapling remain unverified

Unchanged since Phase 11, and the last thing standing between the build and a user installing
it. The scripts are written and exercised locally, but a Developer ID certificate and an App
Store Connect key are needed to prove them, and the first real tag is what does that. A
notarization failure is visible only to end users.

## Shipping surface with no test at all

Not plan-claimed, just never written. Each is code a user reaches today.

- [ ] **`NtfySink`.** Zero test references, while § Verification names it explicitly ("assert
      `WebhookSink` and `NtfySink` work purely through the public `CustomEventSink` surface")
      and the deployment matrix above makes webhook/ntfy-only one of the four configurations.
      `WebhookSink` has `WebhookDeliveryTests`; the ntfy title/tags/priority mapping, the
      `matches` event filter, the endpoint join and the bearer header have nothing.
- [ ] **`HelperEventDecoder`, everything except FaceTime.** Three FaceTime cases are tested.
      The typing branch — which tolerates BOTH `started-typing` and `typing` for the same
      thing — and `aliases-removed` — which tolerates a list or a bare string — are exactly the
      tolerant branches worth pinning, and are the ones with nothing on them. The event names
      are a compatibility contract with a binary we do not build.
- [ ] **`UploadStore`'s three deliberate properties.** The transfer-id sanitiser that stops
      `../../` escaping the directory, the `0o700` mode, and the chunk-0-truncates rule that
      keeps a retried transfer from appending to the previous attempt's bytes. All three are
      reasoned out in comments; none is asserted.
- [ ] **Log rotation.** `FileSink`'s `.2→.3, .1→.2, current→.1` shift, the 10 MB cap, and
      `tail()` — which reads the entire file into a `String` on every `GET /server/logs`, worth
      a look against § 10's budget while writing the test. `LogLevelWiringTests` covers the
      level and nothing covers the file.
- [ ] **Backups.** `/backup/theme` and `/backup/settings`, four routes storing client blobs:
      no tests, and no fixtures either.
- [ ] **ngrok and zrok argument construction.** `CloudflareArgumentTests` is thorough across
      nine tests; the other two tunnels have one line between them, asserting only
      `requiresRefresh`. That is how the argv credential in § 1 got in, and zrok's reserved
      versus public share selection is unasserted on the same footing.
- [ ] **`FileBodySequence`.** Its stated contract is "peak memory is the chunk size and not the
      file size" and no test says so. Neither does anything cover the mid-stream vanish path,
      which is reachable whenever an attachment is purged to iCloud between the route's
      existence check and the read.
- [ ] **`AppDatabase` migrations only ever run on an empty database.** Every test goes through
      `inMemory()`, which runs the whole migrator at once, so the append-only rule the file
      insists on is never actually exercised: nothing builds a database at migration N with
      rows in it and migrates it forward. The Electron `config.db` migration is well covered;
      our own upgrade path is not.

## A suite that skips itself still reports success

`IMCoreSelectorTests` returns early when `frameworksLoaded` is false. That is deliberate and
explained in the file — the suite is meaningless without the frameworks — but nothing asserts
it ever RAN. On a machine or runner where `dlopen` fails, thirty selector pins go green having
checked nothing, and the output is indistinguishable from success. It is also the suite the
macOS-version item above is built on, so a silent skip there would make that whole exercise
report a pass.

- [ ] A floor: one test that fails if the frameworks did not load, skipped only where we have
      decided they legitimately cannot be.

---

# 3. Designed but unbuilt

## An MCP server beside the HTTP API, and its setup step

Setup already offers "AI agent" as a use; today it routes to the HTTP API. The plan is a
service (manifest-described, in the `.integration` category, dependent on `http`) that speaks
the Model Context Protocol against the same interfaces layer the routes use, so an assistant
gets typed tools rather than raw endpoints. Done looks like: the service with its own
`ServiceFormView` fields (bind address, token), a `.mcp` case in `OnboardingStep.ID` included
for `.aiAgent` and embedding that form the way `.connection` embeds the tunnel's, and the API
step's "an MCP server is planned" sentence removed.


## `UpdateInstalling` has a seam, an endpoint, and no implementation

`POST /api/v1/server/update/install` is written against a capability — `UpdateInstalling`,
declared in `BBHandlers/UpdateHandlers.swift` — that **nothing in the package conforms to**.
`AppContext.setUpdateInstaller(_:)` exists and has no callers, so `updateInstaller` is nil in
every configuration and the endpoint refuses on every server, GUI app included.

The refusal used to blame headless operation and tell the user to run the server inside the
BlueBubbles app — which they may already have been doing. That message now says only that no
updater is available, because that is all this code can honestly know.

The app checks for updates already (`AppModel.checkForUpdates`, sharing `UpdateChecker` with
`GET /server/update/check`, so the menu item and the API cannot disagree). What is missing is
the half that installs one: there is no Sparkle integration anywhere in the tree.

Found while consolidating `AppContext`'s late-binding points — it is one of two capabilities
that had a setter nobody called. The other, the contacts ingestor, was fixed;
`Tests/CompositionTests/AppContextWiringTests.swift` now asserts this one is nil so the day
someone implements it, a test says what changed.

- [ ] Decide whether the app owns an updater at all. If yes: add Sparkle, conform something in
      `BlueBubblesApp` to `UpdateInstalling`, call `setUpdateInstaller` during composition, and
      update the wiring test. If no: delete the seam, the setter and the endpoint rather than
      leaving a route that is guaranteed to refuse.

## Per-device codec negotiation never reaches FCM

§ 4's negotiation table names `POST /api/v1/fcm/device`'s optional `supportedCodecs` /
`publicKey` as how an FCM device declares capability. The handler ignores both, and `PushSink`
resolves `negotiator.resolve(for: .legacy)` unconditionally with a comment saying so. So
`reference-v2` and `sealed-v2` are reachable over the socket and over enrollment and never over
push — which is the target they were designed for, since the whole point is that message
content stops transiting Google.

- [ ] Accept and store the two fields on device registration, and resolve per device in
      `PushSink`. Both codecs are default-off, so this is enabling a switch rather than
      flipping one.

## Socket replay stamps `seq` and can never be asked for it

Half of § 4's opt-in replay ships and half does not. The ring is maintained, `replay=1` is
parsed, and a client that asks gets a `seq` on every frame. What it cannot do is use it:
`since` is parsed nowhere — `SocketClientOptions.parse` reads `EIO`, `replay`, `transport` and
`codecs` only — and `SocketServer.replay(since:)` **has no caller anywhere in the project**. So
"gain the ability to reconnect with `?since=<seq>`" and the `resync-required` marker that
protects a client from a partial history are both unreachable, and the sequence number a client
is handed is decoration.

Worse than merely unfinished: the sequence number is already visible on the wire, so a client
author could reasonably build against a reconnect path that does not exist.

- [ ] Parse `since` at handshake, deliver the ring's tail before the live stream, and answer
      `resync-required` on overflow. Then test it — the only replay assertion today is that the
      opt-in parses.

## Auth usage telemetry does not exist

§ Security: "the server records which connected clients authenticate how, so a future decision
about `auth_mode` rests on data rather than guesswork." Nothing records it. Purely
observational, changes nothing a client sees, and it is the evidence the deferred-migration
table would be argued from.

## There is no internal extension seam, and nothing needs one yet

A richer internal event stream with interception hooks was sketched during design and never
built — no such type has ever been committed. `CustomEventSink` is the only extension point,
and `WebhookSink` and `NtfySink` go through it with no special-casing, which is the standing
proof it is expressive enough for a new delivery route.

- [ ] Only if a concrete consumer appears — a service that must intercept an outgoing message
      before dispatch is the obvious one. Build it for that consumer, not ahead of one. Two
      properties are non-negotiable if it happens: a subscriber must not be able to stall the
      poller, and interception must fail **open** so a hook that throws or times out is skipped
      and the send proceeds.

## New surface to move to v2

`/api/v1` is the Node server's table and nothing else; everything this server added lives under
`/api/v2` (see `.claude/docs/api.md`). The 33 additive routes moved; two things did not, because
they are not routes:

- [ ] **`GET /chat/:guid/typing` still has no route at all.** `checkTypingStatus` is implemented
      in the bridge and wired through the client, so it is dead code from a client's point of
      view. The reference has only POST and DELETE on `:guid/typing`, so this is new surface —
      it belongs in a v2 group, not in the v1 table.
- [ ] **Permission state has nowhere to go.** § 17 wants it on `GET /server/info`, and the
      compatibility contract forbids adding a field there. With v2 existing, the answer is no
      longer "accept that clients cannot see it": an additive `GET /api/v2/server/permissions`
      is exactly what the split is for. Decide and build it, or write down that clients do not
      need it.
- [ ] **Advertise v2 to clients.** Nothing tells a client which versions this server speaks. A
      client has to probe. `server/info` cannot carry it — the field set is frozen — so this is
      itself a v2 route, or a header, or both. Worth deciding before any client adopts v2.

## Private API — methods and routes still missing

- [ ] **`icloud.contactCard` is the last 501.** No contract method for reading the account's own
      contact card. Everything else in the table is implemented.
- [ ] **`deny-nickname`.** Present upstream (`denyHandlesForNicknameSharing:`), absent from
      `BBPrivateAPIContract` entirely. The other two nickname actions are wired; this one was
      missed.
- [ ] **`GET /chat/:guid/typing` has no route.** `checkTypingStatus` is implemented in the
      bridge and wired through the client, so it is dead code from a client's point of view.
      CHECKED: Node has only POST and DELETE on `:guid/typing`, so this belongs in
      `AdditiveRoutes` — alongside `chatPinning`, which is there for the same reason — not in
      the default table, which has to match Node's exactly.
- [ ] **`searchMessages` is refused by design, not missing.** The server answers the same
      question from chat.db with SQL, over full history and with paging. Listed only so nobody
      "fixes" it later by adding a second, slower implementation that disagrees with the first.

## Private API — design follow-ups

- [ ] **Move `react` onto ChatKit.** It goes through IMCore today. The reference uses
      `CKChatItem` + `chat.sendTapback:forChatItem:`, which is also where the macOS 26
      `IMEmojiTapback` path lives — so arbitrary-emoji tapbacks are unreachable until this moves.
- [ ] **Move replies onto `IMCreateThreadIdentifierForMessagePartChatItem` + `threadOriginator`,**
      matching the reference.
- [ ] **Consider routing text-only `sendMultipart` through IMCore.** It goes through ChatKit
      today for uniformity. ChatKit is the larger and less stable surface and text does not need
      it; narrowing the ChatKit dependency to attachments only would reduce the blast radius of
      a ChatKit change.
- [ ] **Fill in the event-observation ladder table (§ 15).** The rule is: resolve each inbound
      event to the highest non-swizzle rung that works. Only an exercised probe run on a real
      Mac fills this in, and it has not been run.
- [ ] **Decide whether FindMy DEVICE locations should refresh through IMCore too.** Devices come
      off the FindMy app's disk cache, so they are only as fresh as the last time that app ran —
      `open_findmy_on_startup` exists to paper over it. `IMFMFSession` has `activeDevice` and
      `makeThisDeviceActiveDevice` but no device-location read; that lives in FindMy's own
      frameworks, which Messages genuinely does not load. So this is probably a FindMy-hosted
      helper rather than anything the Messages helper can do — worth recording as a conclusion
      rather than rediscovering.

## Scoped settings are handed out and only half used

`ScopedSettings` is constructed for every service and throws on an undeclared read, and
`ServiceSettingsBridge.validate` runs at startup. But only the connection methods route their
CORE reads through the scope; the others still read `context.settings` directly, so their
entitlement lists are accurate documentation rather than enforced limits.

- [ ] Mechanical to finish, and worth doing before any third-party loading exists so the pattern
      is uniform. The rule that matters: an undeclared read must THROW, not return nil —
      returning nil would recreate the "setting is silently inert" bug this exists to end.
- [ ] Note the honest limit: in-process code can read the database file directly, so the
      boundary is only real for the out-of-process plugins § 12 specifies. For first-party
      services it is a declaration that can be checked, not a sandbox.

## Plugin/service manifests — what is left

The model is enforced: `Service.manifest` is the single source of truth, `id` and
`dependencies` derive from it, forms render, validation runs at startup, and the five
connection methods are five services in an exclusive category. What remains:

- [ ] **A conflict found during composition cannot alert.** Validation runs before the alert
      centre exists, so an exclusive-category conflict is logged and not raised. Either move the
      centre earlier or re-validate once it is up.
- [ ] **Categories cannot be reordered or disabled by a user.** `canRun` reads the selection for
      reverse proxies, but there is no general enable/disable UI and event sinks have no
      per-service toggle. (Same underlying gap as `disabled_services` above.)
- [ ] **`ngrok_protocol` migrates into a field that does not exist.** Deliberate — the value is
      meaningful to an existing install and dropping it silently would lose a choice the user
      made — so it is carried into the namespace and left unread. Either declare the field or
      decide the option is retired.
- [ ] **`.network(hosts:)` is declarative only.** Nothing restricts egress, so it is an honest
      label rather than a control. Real enforcement needs § 12's out-of-process design; until
      then do not describe it to users as a restriction.
- [ ] **No consent flow.** Entitlements are declared and user-facing strings exist
      (`Entitlement.userFacingDescription`, `isSensitive`), but nothing shows them or records a
      grant. Needed before any third-party loading: show the list before enabling, re-prompt
      when an update asks for MORE than was granted, and store the decision.
- [ ] **Uninstall is not implemented**, deliberately — there is nothing to uninstall until
      third-party loading exists. Built-ins can only be disabled, which is why the detail page
      offers a toggle rather than a Remove button.
- [ ] **Third-party loading stays closed.** § 12's out-of-process RPC design is unbuilt and the
      sensitive entitlements are refused to non-built-ins by the validator. That refusal is a
      placeholder for a decision, not the decision itself.

---

# 4. Robustness and known traps

- [ ] **`DaemonProcess` blocks its drain on an orphaned grandchild.** Found while building the
      race regression test: a daemon that forks a child which inherits the pipe's write end and
      outlives it leaves the read at termination unable to return until the orphan exits. The
      fixture hit a 30-second stall from `sh -c "…; sleep 30"`; cloudflared spawns helpers, so
      this is reachable in production and would hang the actor for as long as the orphan lives.
      A bounded read, or `posix_spawn` with `POSIX_SPAWN_SETPGROUP` so the whole tree can be
      signalled, closes it.
- [ ] **Guard against the `send`-instead-of-`invoke` class of bug.** `IMCoreRuntime.send` uses
      `perform`, which has no exception barrier: a raise unwinds through Swift frames and kills
      the dispatch task WITHOUT killing the process, so the action applies and the caller waits
      forever for a reply. Found because `setDisplayName` renamed a chat and then timed out;
      four other void writes were on the same path and worked by luck. All five moved to
      `invoke` and the rule is in `send`'s documentation — but documentation is not a guard. A
      source-level check ("no void-returning write calls `send`") catches the next one.
- [ ] **Decide what a partial-success reply should look like.** The `setDisplayName` failure was
      bad specifically because the action SUCCEEDED and the client was told it failed, which
      invites a retry of something already done. Worth a pass over the write paths for other
      places where the reply can be lost after the effect lands.
- [ ] **Sweep `AttachmentStaging` at startup, not only on stage.** The sweep runs from
      `stage()`. A server that crashes after staging and is then left idle keeps a copy of a
      user's file inside Messages' container until the next attachment is sent.
- [ ] **The uploads directory is never swept by anything.** `UploadStore` writes every uploaded
      attachment to `Application Support/bluebubbles-server/uploads` and nothing ever removes
      one — not after a successful send, not at startup, not on a size budget. A chunked
      transfer that dies partway leaves its fragment there too, under a client-chosen id. This
      is the third instance of the same § 10 rule as the two items around it, and the only one
      of the three holding whole files a user chose to send, indefinitely.
- [ ] **The attachment conversion cache has no eviction.** `AttachmentConversion` writes JPEGs
      and M4As under `Application Support/bluebubbles-server/ConvertedAttachments` and never
      removes them. § 10 says explicitly that "every cache gets a byte budget and an eviction
      policy, not just a TTL", and this one has neither. Needs a size cap with LRU eviction, and
      a settings row so a user can see and clear it — pair it with the attachment-cache readout
      in § 5.
- [ ] **Conversion is synchronous with the request.** A first fetch of a large photo transcodes
      before any bytes are sent. Fine for a photo; worth measuring for a long voice note, where
      `AVAssetExportSession` is doing real work. If it is slow enough to matter, converting on
      ingest rather than on download moves the cost off the request path entirely.
- [ ] **`FileBodySequence` is still the placeholder its own comment says it is.** § 10 calls for
      NIO's `FileRegion`/sendfile so attachment bytes never enter the heap; what ships reads 64
      KB chunks through a blocking `FileHandle.read` on a cooperative-pool thread. Peak memory
      is bounded, which is the property that mattered, so this is a latency and thread-parking
      concern rather than a correctness one — but the comment claims Phase 9 would wire it and
      Phase 9 is done.
- [ ] **`reindexAll` has a window where the address book does not exist.** It deletes every
      `.macOS` contact and then streams the new ones in batches, so a message serialized during
      a reindex can show a phone number instead of a name. Deliberate as far as it goes —
      holding the whole address book in one transaction is what the streaming design avoids —
      but the two are not actually in conflict: one write transaction can span the streamed
      batches, at the cost of holding the write lock for the length of the ingest. Worth
      measuring which is worse on a large address book.
- [ ] **A pinned bind address that disappears retries ten times and gives up.** The retry is
      correct and deliberate — at login the server can start before Wi-Fi associates — but the
      backoff exhausts, so a network that comes up two minutes later leaves the server bound to
      nothing until someone restarts it. Either retry indefinitely for this specific error, or
      watch for interface changes (`NWPathMonitor`) and rebind.
- [ ] **`lan_address` and `bind_address` can disagree.** Binding to `192.168.1.50` while
      publishing `10.0.0.5` produces a URL nothing can reach, and neither setting is wrong on
      its own. Worth a validation warning on the Connection settings — not a hard refusal, since
      a NAT or a reverse proxy is a legitimate reason for them to differ.
- [ ] **`os_log` does not escape an injected dylib in a sandboxed host.** Measured on macOS
      26.5.2: queries by subsystem, by `senderImagePath` and by process all return nothing while
      the helper is running and connected. `HelperMain` still logs through `os_log`, so those
      lines are write-only. Either find a channel that works or drop the logging and lean on the
      socket, which demonstrably does — the code currently implies an observability it does not
      have.

## Tunnel binaries

Decided and built: downloaded and version-managed (`BBTooling`), not bundled. Recommended
versions, per-architecture builds with a Rosetta-aware fallback, quarantine stripping, SHA-256
verification, Developer ID team-ID pinning on all three tools, a version probe that RUNS the
binary before adopting it, an atomically swapped `current` symlink, one previous version kept
for offline revert, and "Choose Existing…" for offline installs. **Bumping a recommended
version is a release step.**

- [ ] **zrok 2.x is published and deliberately not adopted; 1.1.11 is pinned.** zrok 2 renames
      its binary to `zrok2` and **removes `zrok share reserved`**, which is what `Tunnels.zrok`
      invokes for a reserved share — so installing the newest would give a tunnel that works for
      public shares and fails for reserved ones, at runtime, on an unattended machine. 2.x
      replaces `reserve` with `create` plus `share public -n <name>`. Porting means changing the
      invocation AND `executableName`, which currently cannot vary by version. Either make that
      per-build or cut over wholesale.
- [ ] **A tool is never uninstalled.** Switching connection method leaves the binary on disk and
      there is no remove button. Cheap to add, and worth pairing with a size readout —
      cloudflared is 38 MB and nothing tells the user it is there.
- [ ] **Nothing verifies a bundled or user-chosen binary.** `adoptExternalBinary` checks only
      that the file is executable: a copy someone points at is trusted because they pointed at
      it. That is the right default for an explicit act, but the signature could still be
      REPORTED on the page rather than left unstated.
- [ ] **Update checks are gated on `check_for_updates`, which defaults off.** Deliberate — a
      scheduled check is network traffic nobody asked for — but it means most installs will
      never be told about a new cloudflared unless they press Check. Worth revisiting now that
      the one key is doing two different jobs.

## Deliberately not built, recorded so it is not re-litigated

- **Multiple simultaneous proxy services.** The tunnels have no conflict with each other; what
  blocks it is that `server_address` is a single string with six consumers (Firebase
  publication, the `new-server` socket event which carries a BARE string, TLS SAN generation,
  `DynamicDNSProxy` which reads it as input, and two app views) — and downstream of that,
  clients store one URL, so publishing several helps nobody until a client can hold a list and
  fail over. § 17's tunnel allowlist also assumes one egress address; N tunnels means N to
  allowlist and trust for `X-Forwarded-For`, where missing one is a lockout and over-trusting
  is spoofable client IPs. **The LAN-plus-tunnel case that motivates this needs no
  multi-provider work**: `server/info` already advertises `local_ipv4s`. Revisit only alongside
  client-side failover.
- **Inbound socket commands.** The socket is server→client only. Re-adding the ~30 legacy
  commands would mean a second implementation of every endpoint, with its own auth, over a
  transport never designed to carry it.
- **Google contacts sync.** Removed: `CNContactStore` sees Google-synced contacts, and the Node
  server only had the flow because `node-mac-contacts` enumerates CONTAINERS and CardDAV
  accounts do not reliably appear in that list. Verified on macOS 26.5.2 with a Google account
  in Contacts.app: 584 contacts indexed, 25/25 sampled CardDAV numbers resolved through the
  index.

---

# 5. UI parity and cleanup

## Settings that are declared, invisible and unread — decide, then delete or build

Each has a `Setting` declaration with no `presentation:` AND no reader. Do not give them a row;
decide whether they mean anything.

- [ ] **`encrypt_coms`** — superseded by the `sealed-v2` codec. Delete.
- [ ] **`start_via_terminal`** — an Electron relaunch workaround. Delete.
- [ ] **`disable_gpu`** — Electron-only. Delete.
- [ ] **`headless`** — the SETTING is dead, but `--headless` works: `LaunchOptions` parses it
      into `ServerComposition.Options` directly. Remove the setting or have the launch path read
      it, but not both spellings.
- [ ] **`tutorial_is_done`** — dead AND duplicated. Onboarding gates on `UserDefaults`
      `hasCompletedOnboarding`, while `LegacyConfigMigration` writes `tutorial_is_done` from an
      Electron config — so **an upgrading user who completed the old tutorial is shown
      onboarding again**, and the migrated value lands where nothing reads it. One source of
      truth, and it should be the migrated one.
- [ ] **`auto_install_updates`** — no installer path. The checker exists and only reports; this
      needs a download-and-swap step before the setting means anything.
- [ ] **`facetime_calling`** — nothing gates on it. (`enable_ft_private_api` IS read now: it
      gates every FaceTime route and the helper's injection.)

`headless`, `disable_gpu` and `tutorial_is_done` are correctly absent from the UI either way —
listed so the next reader does not re-flag them as missing rows.

## Actions the old UI had and the new one does not

- [ ] **Restart controls.** `AppModel.restart()` has exactly one caller, the `.restartServer`
      alert action. The old Debug & Logs page offered *Restart Services*, *Full Restart* and
      *Restart via Terminal*; the new UI has only Start/Stop, so recovering from a wedged
      service means quitting the app.
- [ ] **Per-webhook event subscriptions.** `WebhooksView` hardcodes `events: ["*"]`; the old
      `AddWebhookDialog` had an Event Subscriptions picker. The model already carries the field,
      so this is UI only.
- [ ] **Contacts: Add Contact, Import VCF, Clear Local Contacts.** The new page can only refresh
      from the Address Book. `ContactDialog` (first/last/display name, addresses) has no
      counterpart, and `POST /contact/import/vcf` exists server-side.
- [ ] **Logs: Open Log Location, Open App Location, Copy Binary Path, Clear Logs, Clear Event
      Cache, Show Messages App Logs.** The new page has level, filter, follow and copy.
- [ ] **Attachment cache info and clear.** Old `AttachmentCacheBox` showed attachment count and
      cache size in MB with a clear button. Nothing equivalent — and it is the same cache the
      eviction item in § 4 is about, so build them together.
- [ ] **Danger Zone.** Old `ResetSettings` offered *Reset Tutorial* and *Reset App* (wipe all
      configuration and restart). Per-service "Reset to Defaults" exists; a whole-app reset does
      not.

## Home page

The old Home was the connect-a-client page; the new one is a status grid.

- [ ] **Server URL with a copy button, and the QR code.** Both were on old Home. The QR code
      does not exist anywhere in the Swift app, and pairing by hand-typing an ngrok URL into a
      phone is the worst version of setup. `GuidesView` shows the address with a Copy button,
      which covers part of it, but nobody looks there first.
- [ ] **The insecure-connection warning.** Old Home warned, at length, when the address was
      plain HTTP.
- [ ] **Computer ID.** Present in `/server/info`, shown nowhere.
- [ ] **Stats.** Old: Total Messages, Daily Messages (with a timeframe dropdown), Best Friend,
      Top Group, Total Pictures, Total Videos. New: Messages, Chats, Handles, Attachments.
      `/server/statistics/media` exists, so pictures/videos are a UI change; best friend and top
      group need new queries.

## Other app gaps

- [ ] **Alert actions are only reachable from the Notifications page.** The remedy renders where
      the problem is reported, which is the § 17 requirement — but macOS notification banners
      carry no actions, so an alert raised while the app is in the background still needs the
      user to open the app and find it. `UNNotificationAction`s mapping to the same
      `AlertAction` cases would close it.
- [ ] **`GuidesView` reads its state once, on appear.** Everything it shows can change while the
      page is open — a tunnel reconnecting, the helper attaching, contacts finishing an index —
      so a user watching the page sees stale answers. Either poll it the way the Permissions
      page does, or drive it from the same observation the Home page uses.
- [ ] **The dock badge counts unread ALERTS, not messages.** The Electron server badged a
      notification count that meant roughly the same thing, but this is worth a decision rather
      than an assumption.
- [ ] **`start_minimized` miniaturises rather than hiding.** `NSApp.hide` would remove it from
      view entirely, which is not what someone who still wants it in the Dock asked for — but it
      is a judgement call, and a user who wants a truly invisible start probably wants
      `hide_dock_icon` too.

## Deliberate relocations, not gaps

The standalone Notifications page (now the toolbar bell); the Permissions and Security pages
(now settings tabs); ngrok/zrok settings pages (now manifest-driven Integrations pages).

---

# 6. Housekeeping

## Statics the lock pass left alone, and `@unchecked Sendable` not re-audited

Three `nonisolated(unsafe)` statics remain (`HelperMain`/`FaceTimeHelperMain.client` and
`started`, `EventObservation.emit`/`handler`/`rung`, `FaceTimeBridge.emit`/
`lastLinkSnapshotCount`) — 11 declarations, all inside the injected helpers and none in the
server. Each is written once at load before any listener exists and says so; none is a latch.
25 `@unchecked Sendable` conformances remain in `Sources`+`Helper`; the ones touched in the
lock pass now carry a precise comment, the rest were not re-read. The services no longer
contribute: `Service` refines `Actor`, so each holds its own state and `TaskBox`/`RuntimeBox`
are gone. Done looks like: each
`@unchecked` names the invariant that makes it safe, or becomes an `OSAllocatedUnfairLock`.

## Two structural findings the audit left open

Both are preferences on working code, and both were checked before being left:

- ~~**`AppContext`'s publish/withdraw slots.**~~ DONE, and smaller than the plan: the four
  slots became one `PublishedRuntime` value with a `didSet` clearing the interface cache, so
  invalidation follows from the data without a separate registry actor or a change stream.
  Three tests assert the rebuild and fail without it.
- **`BBInterfaces` holds repositories that belong elsewhere** — RETRACTED, do not do this.
  Moving them would push GRDB into `BBDiagnostics`, `BBEvents` and `BBPushKit`, none of which
  has a persistence dependency today. `BBDiagnostics` declares `AlertStoring` and
  `AlertRepository` implements it from up here; that is dependency inversion working, not a
  misplaced file. The build-time argument was separately wrong: touching `BBInterfaces`
  rebuilds in 7.9s against 3.4s for `BBCore`.

## `AppModel` still owns tool-status observation

`toolStatuses`, `toolsTask`, `toolObservers` and `beginObservingTools` stayed on the root
model in the split; a `ToolsModel` following the `PermissionsModel` pattern is the obvious
next cut, and `ToolActions` is its only consumer.


- [ ] **A test asserting every setting with a `presentation:` has a READER.** The existing
      `RenderableSettingsTests` catches the adjacent mistake — a presented setting missing from
      `renderable` — and would have caught eight of the wired-up settings the moment they were
      written. It cannot be a grep from inside the test process, but a build-time script over
      `Sources/` wired into CI is the same shape as the coverage test that already exists.
- [ ] **Dump headers for ChatKit and the daemon listener.** The mechanism exists —
      `Tools/header-dump/dump.sh` reads the running Objective-C runtime and writes
      `docs/headers/macos-<version>/`, so the diff between two releases answers "what did Apple
      move". FindMy and the FaceTime `TU*` classes are dumped; ChatKit's `CKMediaObjectManager` /
      `CKComposition`, which the send path now depends on, and `_IMLegacyDaemonListener`'s 127
      methods (dumped ad hoc for Phase 15 and thrown away) are not. Add names to the list in
      `dump.sh`. Note the frameworks are NOT on disk — macOS 26 ships them in the dyld shared
      cache, so `nm`/`strings` against a path fails; extract with `dyld_shared_cache_util
      -extract`.
- [ ] **Test group 481** ("Renamed By Swift Helper", `any;+;bcb9a1843dfc4b65bb47ce50afec8d32`)
      is left in the user's Messages with the user departed from it. Delete when convenient.

# 7. Architecture audit — 2 September 2026

A whole-tree read of `Sources/` and `Helper/` for maintainability, standardisation and
extensibility, done from the code rather than the comments. The verdict was that the shape is
sound — strict concurrency everywhere, actors as the isolation model, layering checked by
`Tools/package-graph/check.py`, typed errors, swift-testing with real doubles — and that the
problems are second-order. Ten findings came out of it. Three are done; the rest are recorded
here so they can be picked up cold, in the order the audit recommended.

## ~~Manifest forms saved per keystroke and restarted the tunnel each time~~ — DONE

`ServiceFormView` wrote the store on every change of a text binding. Every `ProxyService`
watches its own fields and answers `.restart`, so typing a Cloudflare or zrok token restarted
the selected tunnel once per character, and each partial token reached the vendor's binary.
Text now drafts and commits on Return, focus loss or leaving the page, with a "Not saved yet"
footnote while a draft is pending, the same policy `SettingRow` already had. Toggles, pickers,
dates and the path chooser still commit at once, because a click is a finished decision.

## ~~Two identifier types for one concept~~ — DONE

`ServiceID` and `ServiceIdentifier` named the same thing and were converted through
`rawValue` at forty sites, with `ContextualService.swift` re-declaring every built-in id as a
second set of constants. `ServiceID` is gone: `Service.id` returns `manifest.id`, the registry
keys on `ServiceIdentifier`, and a dependency is written as `BuiltInManifests.ID.http`.

## ~~The composition root implemented as well as wired~~ — DONE, as `BBBuiltIns`

The manifests, the tool descriptors, `ServiceEnablement`, `ScopedSettings` and
`ServiceSettingsBridge` lived in `BlueBubblesServerCore/Composition`, so the app linked the
whole wiring to render a manifest and parse the disabled list. They are `Sources/BBBuiltIns`
now — a data module depending on `BBServiceKit`, `BBSettings`, `BBDiagnostics` and `BBSystem`
— and the root reads it like the app does. Still in the root and still worth moving later:
`TLSProvisioning`, `ServerAddressAnnouncer` and the per-vendor option building in
`Services/Proxy/*Method.swift`, which is behaviour rather than wiring.

## ~~`AppContext` is a service locator with mixed access rules~~ — DONE

`secretsForPush` (an alias of `secrets`), the `Interfaces` typealias and the
`groupChatShortcuts()` accessor over a `let` are gone. Announcing a new address and restarting
push moved to `ServerLifecycle`, which now owns the announcer; the container no longer holds a
lazily built one. `hasMessageAccess` and `groupChatShortcuts` are `nonisolated`, so reading
them costs nothing. The header now states the three member shapes — `nonisolated let`,
`nonisolated var` value, isolated state — and `Sources/BlueBubblesServerCore/CLAUDE.md` says
not to add a fourth. What stays on the container, deliberately: `requestRestart` and
`requestFullRestart` as two-line delegations, because `ServerControlling` is a capability the
handlers compose and the container is what conforms; and the lazily built `faceTime()`,
`applicationRestart()` and `callHistory()`, which close over the container's own published
state and are honestly isolated.

## ~~Rules enforced in one place and hand-maintained in another~~ — DONE

Four drift classes, each now derived from the declaration it used to mirror:

- `Settings.secretKeys` is `Set(all.filter(\.isSecret).map(\.key))`.
- `IntegrationsModel` parses and writes `disabled_services` through `ServiceEnablement`.
- `ConfigurableService.watchedSettings` DEFAULTS to `manifest.watchedSettingKeys` — own
  fields plus declared reads, minus declared writes so a connection method never restarts
  on its own `server_address` publish. A service may only ADD to it (`HTTPService` and
  `SocketService` add `password`; `WebhookDeliveryService` adds `ntfy_token`, a secret no
  entitlement may name; `PushDeliveryService` adds `remote_restart_enabled`, which has no
  presentation and so no name the permissions sentence could use). Every other core read
  is now declared on its manifest, which also fixed the permissions list — the Private API
  reads its four helper settings, HTTP reads the TLS switch, and every proxy declares that
  it writes `server_address`. Two tests in
  `WatchedSettingsTests` pin the rule: declared ⊆ watched, and written ∩ watched = ∅.
  `PushDeliveryService.apply` now answers `.none` for `server_address`, which it consumes
  live.
- `AlertAction.openSettings` takes an `AlertDestination` enum and the app routes it with an
  exhaustive switch.

## ~~`BBInterfaces` has become the everything-domain module~~ — DONE, in the narrowed form

Section 6's retraction stands: the repositories stay. What moved: the FaceTime trio is
`Sources/BBFaceTime`, `FindMyRuntime` is in `BBSystem` beside the other FindMy types, and the
three capabilities only handlers compose — access control, token auth, the update installer —
are `BBHandlers/HandlerCapabilities.swift`. `ToolProviding` had no composer and is deleted.
`BBInterfaces` no longer depends on `BBAuth`, `BBTooling` or `BBUpdates`.

## ~~The registry has no per-service state machine~~ — DONE, as lanes

Every start, stop, restart and supervised retry for one service now passes through that
service's lane in `ServiceRegistry` — a chain of tasks, one per service, each waiting for the
last — so a stop or a second restart arriving while a start is in flight waits for it and then
runs against a service that is genuinely up or genuinely failed. A restart is one lane
operation, so two restarts are stop, start, stop, start and never interleave. `stop` cancels
the supervisor at once, so no further retry is scheduled, and an attempt already in the lane
completes before the stop runs. `health()` reports `.starting` while a start is in flight,
which the enum had a case for from the first commit and nothing reported. Three gate-driven
tests in `ServiceRegistryTests` pin it: a stop during a start, two concurrent restarts, and a
stop during a supervised retry. Lanes are per service and never shared, so this adds no
cross-service waiting.

## Fire-and-forget persistence can reorder

`AccessControlService.persist` snapshots state and writes it in a detached task with no
ordering, so two rapid blocks produce two tasks and the older snapshot can land last.

- [ ] Give the writes a serial lane, the way `EventBus` gives each sink one, or fold them into
      one task that drains a queue. Done looks like a test with a slow `AccessControlPersistence`
      double that proves the last write wins.

## ~~Comment rot, and the volume that guarantees more~~ — DONE, as a rule

Fixed the four found: the delegate doc that contradicted its code, the duplicated FaceTime
sweep paragraph (and the `serverEvent` doc it had displaced), the duplicated `alertJSON`
paragraph, and two orphaned paragraphs in `MessageRepository`. The rule is in `CLAUDE.md`
under the non-negotiables: a header states the decision and the failure it prevents, history
goes in git and the decisions doc, and a comment above changed code is part of the change.
The thirty-odd files that still carry narrative are trimmed as they are opened for other
reasons, not in a sweep.

## ~~Smaller consistency items~~ — DONE, one retracted

- `PrivateAPIRuntime.swift` and `ProxyCoordinator.swift` are named after what they define.
- `ServerInterface` is `AdminInterface`, reached as `admin`; the `Interfaces` alias is gone.
- `PushHandlers` no longer imports GRDB and `BBHandlers` no longer declares it.
- `SettingValue.parse(loose:)` is a protocol requirement; the store no longer switches on
  `type == Bool.self`. Enum-backed settings get it from a constrained extension, and `Date`
  now parses ISO 8601 from the command line where before it parsed nothing.
- **`BBError` boilerplate — RETRACTED.** The repeated lines are the `code` switches, and
  `code` is a searchable, per-case contract that has to be written out. `domain` is one line
  per type, and a reflective default would change every logged domain string. Nothing to
  remove.
