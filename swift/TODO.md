# Running list

Things to do or think about later. Not a backlog of everything — the docs hold the
design. This is for what we deliberately deferred, what we could not verify from here, and
what we learned late enough that it did not get folded in.

Each entry says what it is, why it is not done, and what "done" would look like, so it can be
picked up cold. Finished work is deleted, not struck through: git holds the history, and a
list that carries its own past stops being readable as a list.

**Ordered by priority, re-sorted 2 September 2026 after the architecture audit.** Section 1
is what is wrong for a user or a contributor right now. Section 2 is verification the plan
claims and CI does not do, plus shipping surface no test touches. Section 3 is
designed-but-unbuilt surface. Sections 4 and 5 are robustness and UI parity. Section 6 is
housekeeping. Within a section, worst first.

---

# 1. Wrong for users now

## `tempGuid` is echoed but never used to deduplicate

The reference registers `tempGuid` in a send cache before sending and removes it after, so a
client that retries a send it never got an answer to can be told the first one is still in
flight. This server echoes `tempGuid` back on the response and keeps no cache, so a retry
sends the message twice.

Worth noting because the hydration work made the window bigger, not smaller: every
message-bearing route now holds its response until the row appears — up to 60 seconds for a
send, 30 for an edit — so a client with a short timeout is MORE likely to retry than it was
when the answer came back immediately.

- [ ] Decide whether to build the cache. It is not visible in any recorded response — the
      reference's cache changes what a concurrent duplicate does, not what a single send
      returns — so this is a behaviour question rather than a parity one.

## The notification payload drops chat participants

`MessageSerializerConfig.notification` sets `loadChatParticipants: false`; the reference
inherits `true` from `DEFAULT_MESSAGE_CONFIG` and only strips participants when the payload
exceeds 4000 bytes. So every push notification for a group chat carries less than it does
today — and the size cap, which exists precisely to drop participants, can never fire because
there is nothing there to drop. `ChangeDetectionService.event(for:serializer:)` compounds it:
both projections are built from an empty `MessageSerializer.Context()`.

- [ ] Load participants for the notification projection, with a per-chat cache for the fan-out
      (the reference keeps a `chatCache` in `serializeList` for the same reason). Done = a group
      message's FCM payload carries `chats[0].participants`, and `NotificationSizeCapTests`
      proves the cap trims them when it must.

## An upgrading user who finished the old tutorial is shown onboarding again

Onboarding gates on `UserDefaults` `hasCompletedOnboarding`, while `LegacyConfigMigration`
writes the Electron `tutorial_is_done` into a `Settings.Legacy` row that nothing reads. So the
migrated value lands where nothing looks, and the walkthrough runs for someone who already
did it. One source of truth, and it should be the migrated one.

- [ ] Have `OnboardingModel.isComplete` consult the migrated row (or seed the default from it
      on first launch), then delete the duplicate. Pair with the dead-settings sweep in § 5.

## Keychain items are readable by any same-user process

§ Security #1 asks for Keychain items whose ACL is "bound to the app's code signature rather
than being readable by any same-user process". `SecretStore` sets
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and no `SecAccessControl` at all, so the second
half was never built — the password, the FCM service account and the tunnel tokens are
readable by anything running as the user. The accessibility attribute is the right floor and
is not the claim. The header of `SecretStore.swift` records why: these are LEGACY keychain
items, and the data-protection keychain needs the app signed with `keychain-access-groups`.

- [ ] Add a `SecAccessControl` bound to the signing identity, decide what happens to items
      written before it (they cannot be re-ACLed in place — read, delete, rewrite), and assert
      it. This has to land before the § Security regression suite can honestly claim #1.

## Access-control persistence can reorder

`AccessControlService.persist` snapshots state and writes it in a detached task with no
ordering, so two rapid changes — a block and the unblock that follows it — produce two tasks
and the OLDER snapshot can land last. To a user that is "I unblocked it and after a restart it
was blocked again". The last of the ten audit findings; the other nine are done.

- [ ] Give the writes a serial lane, the way `EventBus` gives each sink one and
      `ServiceRegistry` gives each service one. Done looks like a test with a slow
      `AccessControlPersistence` double that proves the last write wins.

## The uploads directory is never swept by anything

`UploadStore` writes every uploaded attachment to
`Application Support/bluebubbles-server/uploads` and nothing ever removes one — not after a
successful send, not at startup, not on a size budget. A chunked transfer that dies partway
leaves its fragment there too, under a client-chosen id. This holds whole files a user chose
to send, indefinitely, on a project whose stated target is an old Mac mini.

- [ ] Remove an upload once its send has been handed to Messages; sweep the directory at
      startup on age; cap it. `AttachmentConversion` has the hourly sweep gate to copy.

## A pinned bind address that disappears retries ten times and gives up

The retry is correct and deliberate — at login the server can start before Wi-Fi associates —
but the backoff exhausts, so a network that comes up two minutes later leaves the server bound
to nothing until someone restarts it.

- [ ] Either retry indefinitely for this specific error, or watch for interface changes
      (`NWPathMonitor`) and rebind.

## `new-findmy-location` has a rung-1 path and is still unwired

Established and not acted on. `EventObservation` still records "selectors matching
'location': NONE". Observe `__kIMFMFSessionLocationReceivedNotification` (object: an
`IMFindMyHandle`, userInfo: nil), read the position with `findMyLocationForFindMyHandle:`, and
push it through `FindMyFriendsCache`, whose merge rules already decide what counts as a change
worth emitting. `EventObservation` is where the observer goes — it reaches rung 2 for typing
and swizzles nothing, so this would be its second rung-1 tenant. The server side is ready:
`HelperEventDecoder` and `PrivateAPIGatedService` already forward `findMyLocationUpdated`.

- [ ] Wire it. The open decision is emission policy, not discovery: a position can update every
      few seconds, `CoalescingRateLimiter` exists for exactly this, and nobody has picked an
      interval.
- [ ] **`aliases-removed` deserves the same second look.**
      `__kIMAccountAliasesChangedNotification` IS in IMCore as a string literal. The earlier
      "not exported" finding was the wrong test — the identical false negative that stalled
      FindMy for a release. If it fires on removal as well as addition, the rung-3 swizzle of
      `IMAccount._registrationStatusChanged:` can go.

## The server injects the wrong architecture in debug builds

`swift build` produces an arm64 dylib; Messages runs arm64e, so the server's own injection
fails with a correct and clear error while a manually built `--arch arm64e` helper works fine.
Release builds are universal, so users are unaffected — but it makes the Private API
untestable from a plain debug build, which is the configuration a contributor has.

- [ ] Either `DylibInjector` prefers an arm64e slice built alongside, or `Tools/dev-bundle.sh`
      builds one.

---

# 2. Verification the plan claims and CI does not do, and code nothing tests

## The parity corpus is replayed; five things it still cannot see

`FixtureReplayTests` now mounts the shipping router in-process over the synthetic `chat.db` and
replays every recorded v1 fixture on each build, with `Fixtures/replay-baseline.json` as a
two-way ratchet. That closed the worst of this entry — the claim "the compatibility contract is
mechanically enforced" is now true rather than aspirational, and the first run found the
envelope swap described below. What it still does not do:

- [ ] **Nothing compares response HEADERS.** `Sources/BBParity` contains no occurrence of
      `header` outside the provenance sniff — the recorder captures them, the diff ignores them.
      So the "Misc" contract rows are asserted by nothing: wide-open CORS, `?pretty`, the 504
      timeout body, and `Content-Disposition` on file streams. **It has already diverged:** the
      recorded Node responses carry `access-control-allow-methods` on ordinary 200s, and
      `CORSMiddleware` sends that header only on `OPTIONS` while adding an `allow-headers` Node
      does not send. This is also what `RecordedFixture.recordedFrom` leans on to tell a
      Node recording from one of ours, so fixing the CORS divergence and recording the
      provenance explicitly have to happen together — see the entry below.
- [ ] **Record the write paths that touch only the server's own database.** `POST`/`DELETE`
      `/backup/theme` and `/backup/settings`, `POST /webhook` and `DELETE /webhook/:id`,
      `POST /server/alert/read`, `POST /fcm/device`, the four `/message/schedule` routes and the
      six `/contact` writes send nothing to anyone and can be recorded today against a throwaway
      server. `bb-openapi coverage --check` reports the gap and ratchets it.
- [ ] **Record the sends, carefully.** Sends, reactions, edits and group management are unpinned
      — exactly where the helper work lives. Needs a dedicated throwaway conversation and a
      driver that is explicit about what it will send. Note that the replay DENY-LISTS all of
      these (see below), so recording them buys `bb-parity` coverage, not CI coverage.
- [ ] **Capture the socket transcript.** The HTTP half is recorded; the handshake and frame
      sequence are not, and `Fixtures/` has no `socket/` directory yet.
- [ ] **Re-record after any Node-side change.** The fixture is a snapshot of a server that is
      still being maintained. Worth a note in the release process.
- [ ] **Record an attachment with EXIF.** Every attachment in the corpus is a test PNG, and all
      three carry `metadata: {size, height, width}` — which is exactly what
      `AttachmentMetadataReader` now produces, so this reads as parity. It may not be: the
      reference maps forty-odd `kMDItem…` keys out of `mdls`, so a camera photo Spotlight has
      indexed could also carry `aperture`, `focalLength`, `deviceMake`, `orientation`. One
      recorded photo settles whether that is a gap. If it is, ImageIO's
      `kCGImagePropertyExifDictionary` is the same data without the subprocess — and worth
      weighing against the fact that the EXIF tail is the part most likely to carry something
      personal out of someone's picture.

## The replay harness locked the developer's Mac, and only a deny-list stops it

Its first run issued `POST /api/v1/mac/lock` against a real in-process server, on a machine
being used over a remote session, and went on to restart Messages and kick off a service
restart in the same pass. `FixtureReplay.destructiveRoutes` and `sendingPrefixes` now refuse
them, and `ReplayDenyListTests` asserts it — but the protection lives in the DRIVER, and
anything else that ever replays this corpus has to remember it exists.

- [ ] Move the refusal somewhere a future harness cannot miss: a flag on `RouteDefinition`
      (`isDestructive`) that the route table declares once, that `FixtureReplay` reads instead
      of keeping its own list, and that `bb-parity`'s corpus can read too. Done = deleting
      `destructiveRoutes` from `FixtureReplay` changes nothing about what runs.

## The recorder does not stamp which server it recorded

Nothing in a fixture file says whether Node or this server answered, so `RecordedFixture`
infers it from a CORS header — which works only because the two happen to differ, and stops
working the moment `CORSMiddleware` is fixed to match. That inference is what
`CorpusProvenanceTests` rests on, and what found that **fifteen v1 routes have no reference
recording at all**: the group-management writes, `chat/:guid/leave`, the participant routes, the
group icon, the FaceTime session routes, the alias change, `POST /webhook`,
`DELETE /webhook/:id`. Diffing those compares this server against a photograph of itself.

- [ ] Have `Tools/conformance-recorder` write `"recordedFrom": "node" | "swift"` into each file,
      backfill the existing corpus from the header sniff, and switch `RecordedFixture` to read
      the field. Then re-record the fifteen against a Node server.

## The corpus scrubber destroyed an epoch timestamp it mistook for a phone number

`get_api_v1_message_count_updated-ad9b67-200.json` records the path
`/api/v1/message/count/updated?after=+15555550100`. `after` is epoch **milliseconds**; the
scrubber's phone-number rule matched the digits and replaced them, so the fixture now asks a
question no server can answer — the reference's recorded 200 against a replayed 400. It is in
the replay baseline as an OPEN corpus bug.

- [ ] Narrow the scrubber so it does not rewrite numeric query values whose parameter is a known
      date field, re-record that fixture, and add a scrubber self-test for it
      (`Tools/conformance-recorder/selftest.mjs` is the place).

## There is no request-validation layer, so this server accepts what the reference rejects

The reference runs validatorjs rules per route (`validators/*.ts`): `limit: "numeric|min:1|max:1000"`,
`after: "required|numeric|min:0"`, `sort: "string|in:ASC,DESC"` and so on, and a violation is a
400 whose `error.message` is the generated sentence. This server has none of it — the
`RequestValues` accessors are lenient by design, so a field of the wrong type reads as absent
and the route's default applies. `POST /api/v1/message/query` with `{"limit": "not-a-number"}`
is a 400 in the reference and a 200 here, and that is the only case the corpus happens to
capture; the gap is every route with a rule set.

Note that the leniency is right for the case it was written for and wrong for this one:
validatorjs's `numeric` accepts `"5"`, so a client sending numbers as strings passes there too.
What it rejects is genuine garbage, which we silently ignore.

- [ ] Transcribe the rule sets into a table beside `RouteTable`, and a small evaluator for the
      dozen rules actually used (`required`, `string`, `numeric`, `boolean`, `array`, `present`,
      `in:`, `min:`, `max:`). Match validatorjs's message format and its FIRST-error-only
      behaviour — `ValidationFailure` already documents the second half. Done = the
      `post_api_v1_message_query-5baa61-400` baseline entry is deleted.

## Contact ids are UUIDs where the reference gives integers — checked, and kept

`POST /api/v1/contact` answers `data[0].id: 554` in the reference — a row id in its own contacts
table — and a UUID string here. It is not only the create route: every Node-recorded contact id
in the corpus is an integer (1, 2, 3, 553, 554, 555), so `GET /contact`, the two `PUT`s,
`DELETE`, `contact/query`, `import/vcf` and `contact/external/:externalId` all differ the same
way.

Where the UUID comes from: this server has ONE `contact` table with a TEXT primary key, because
it merges both sources. An address-book record is `"macos:" + CNContact.identifier`; a
client-created one is a freshly generated `UUID()` — invented, nothing to do with Contacts. The
reference has two stores instead and concatenates them, so its ids are integers for its own rows
(`sourceType: "db"`) and bare Contacts UUIDs for the address book (`sourceType: "api"`).

**Checked against the client before deciding** (`bluebubbles-app`, `contact_service_v2.dart` and
`contact_v2_actions.dart`). Both consumers do the same thing:

```dart
nativeContactId: (map['id'] ?? displayName).toString(),
```

- **Stringified**, so an integer and a UUID are the same to it, and stored as a `String`.
- **Never sent back.** The app calls only `fetchAll`, `query` and `create`; there is no PUT or
  DELETE by id and no external-id lookup. `create` does not read the response body at all — only
  its error. `query` is not called from anywhere.
- Used as a local dedup key and, sanitised, as an avatar FILENAME.
- Its own comment already expects UUIDs from us: "macOS IDs look like `<uuid>:ABPerson`".

And the decisive general point: **the reference itself returns UUIDs for address-book contacts**
(`identifier ?? id` in `mapContacts`), so no client can assume an integer from these routes. One
that parses this field as a number is already broken against the reference.

**Decision: keep the UUIDs.** Changing them buys parity on a field whose type is not uniform in
the reference either, and costs a schema change plus a re-download of every cached avatar on
every client — the filename is derived from this id.

The `macos:` prefix is gone from the wire. It was ours — one table holds both sources and the
keys must not collide — and the reference sends the identifier as Contacts gives it.
`ContactIndex.contact(id:)` resolves either spelling, so an id read from `GET /contact` still
round-trips to `PUT`, `DELETE` and `/contact/:id/avatar`; `update` and `delete` write by the
STORED id, because resolving and then writing by the client's spelling would have created a
duplicate row and deleted nothing.

- [ ] Still unverified against a reference recording: no fixture contains an `api`-source
      contact, so the bare identifier is what the reference's `mapContacts` says it sends
      (`identifier ?? id`) rather than something the corpus has seen. Record a contact list from
      a Node server with the address book populated.

## Two statuses the reference's `ValidStatuses` does not contain

`PayloadTooLarge` sends 413 and `ServiceUnavailable` sends 503; the reference's union is
`200 | 201 | 400 | 401 | 403 | 404 | 500 | 504`. Both are better descriptions than what Node
sends — a body past the limit is the client's constraint to respect, and "a thing this server
needs is not available" is not "this server is broken" — and both are, strictly, statuses no
shipped client has ever been given. `GET /fcm/client` was moved back to the reference's 404
because the corpus caught it; the other call sites were not audited.

- [ ] Enumerate what still answers 413 or 503 on a v1 route and decide each. Neither is visible
      to the replay today: no fixture provokes them.

## The helper's 40-command vocabulary is tested seven commands deep

`HelperDispatch` has 40 `case` arms. `HelperRoundTripTests` proves the pattern works — "Every
FindMy action is recognised by the helper" drives the real dispatch and asserts none of them
answer "unknown action" — and it was never extended past FindMy. `send-multipart`,
`send-reaction`, `edit-message`, `create-chat`, `update-group-photo`, `modify-active-alias`,
`download-purged-attachment` and about twenty-five others appear in no test at all.

Nothing asserts the two vocabularies AGREE, either. `PrivateAPIClient` writes command strings
and `HelperDispatch` reads them; a rename on one side compiles cleanly on both and fails at
runtime, on a user's Mac, as a silently dead feature.

- [ ] Extend the FindMy round-trip to every action in the contract, and add the set-equality
      test: every command `PrivateAPIClient` can send is a command the helper recognises.
      Highest blast-radius-to-effort ratio in this section — one test over two tables.

## `Query.parse` is in the path of every read and has no test

`MessageInterface.Query.parse` and `ChatInterface.Query.parse` turn a client's request body
into a repository query: `with=` relation expansion, `limit`, `offset`, `sort`. The layer below
is covered hard (`MessageRepositoryTests`) and the layer above is too (`MessageSerializerTests`,
`WireFormatTests`); the translation between them is covered by nothing. A regression here
changes what every client receives while every unit test stays green. Replaying the corpus
(above) covers much of it, which is an argument for doing them together.

- [ ] Table-test both `parse` implementations directly: each relation name, unknown names,
      missing keys, `sort` casing, and the limit/offset defaults.

## Scope enforcement is asserted by nothing, and there are two of it

§ Verification: "Assert scope enforcement rejects a write on a read-only credential." No test
in the suite produces a 403. Only meaningful with `auth_mode` flipped on, which is why it has
survived — but it is the mechanism the whole dormant token design is judged by.

`ScopeEnforcement.authorize` in `BBAuth/BearerTokenScheme.swift` has **no caller**. The live
path is `AuthenticationStage.authorize`, called from `HTTPServer`, and it throws a different
error type. Two implementations, one dead, neither tested.

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

Three `SchemaProfile` constructions across the whole suite. § 6 and § Verification ask for
the full read surface across all three profiles, asserting that columns absent from a profile
produce ABSENT fields rather than nulls — including the case that bites hardest, a table
present in Sonoma and gone in Sequoia (`message_processing_task`).

- [ ] Parameterise the serializer and repository tests over the three profiles.

## `AppDatabase` migrations only ever run on an empty database

Every test goes through `inMemory()`, which runs the whole migrator at once, so the
append-only rule the file insists on is never actually exercised: nothing builds a database at
migration N with rows in it and migrates it forward. The Electron `config.db` migration is well
covered; our own upgrade path is not.

- [ ] Build a database at each released migration with representative rows, migrate forward,
      and assert the rows survive.

## Shipping surface with no test at all

Not plan-claimed, just never written. Each is code a user reaches today.

- [ ] **`NtfySink`.** Zero test references, while § Verification names it explicitly and the
      deployment matrix makes webhook/ntfy-only one of the four configurations. `WebhookSink`
      has `WebhookDeliveryTests`; the ntfy title/tags/priority mapping, the `matches` event
      filter, the endpoint join and the bearer header have nothing.
- [ ] **`HelperEventDecoder`, everything except FaceTime.** The typing branch — which
      tolerates BOTH `started-typing` and `typing` for the same thing — and `aliases-removed` —
      which tolerates a list or a bare string — are exactly the tolerant branches worth
      pinning, and are the ones with nothing on them. The event names are a compatibility
      contract with a binary we do not build.
- [ ] **Log rotation.** `FileSink`'s `.2→.3, .1→.2, current→.1` shift, the 10 MB cap, and
      `tail()` — which reads the entire file into a `String` on every `GET /server/logs`, worth
      a look against § 10's budget while writing the test.
- [ ] **Backups.** `/backup/theme` and `/backup/settings`, four routes storing client blobs:
      no tests, and no fixtures either.
- [ ] **ngrok and zrok argument construction.** `CloudflareArgumentTests` is thorough across
      nine tests; the other two tunnels are touched only in passing by `DaemonTests`. zrok's
      reserved-versus-public share selection and ngrok's environment-carried token deserve the
      same treatment cloudflared got.
- [ ] **`FileBodySequence`.** Its stated contract is "peak memory is the chunk size and not the
      file size" and no test says so. Neither does anything cover the mid-stream vanish path,
      which is reachable whenever an attachment is purged to iCloud between the route's
      existence check and the read.

## A suite that skips itself still reports success

`IMCoreSelectorTests` returns early when `frameworksLoaded` is false. That is deliberate and
explained in the file — the suite is meaningless without the frameworks — but nothing asserts
it ever RAN. On a machine or runner where `dlopen` fails, thirty selector pins go green having
checked nothing. It is also the suite the macOS-version item below is built on, so a silent
skip there would make that whole exercise report a pass.

- [ ] A floor: one test that fails if the frameworks did not load, skipped only where we have
      decided they legitimately cannot be.

## macOS versions other than the host

The floor is **macOS 14 (Sonoma)** through **Tahoe (26)**. CI runs on `macos-15` only, and
every private-API finding in this project was measured on Tahoe, because that is the host; at
least one conclusion drawn that way has already turned out to be backwards. **These need
headers or a real machine per version, not more reasoning.**

- [ ] **Run `IMCoreSelectorTests` on Sonoma and Sequoia.** It pins ~30 IMCore selectors, and a
      red test names the selector that moved, which is the whole diagnosis.
- [ ] **Re-check every `unavailableOnThisOS` branch per version.** Each was derived from
      Tahoe-only probing, so a branch may be exactly inverted on an older OS. Current sites:
      `shareNickname` (`IMNicknameController`), `setPinned` (falls back to
      `setPinnedConversationIdentifiers:withUpdateReason:`, which is what the reference targets
      and which Tahoe has REMOVED), and FindMy's two modern-session-only calls,
      `refreshFindMyLocation` and `requestFindMyLocationShare`, which report unavailable when
      `fmlSession` is nil — the branch most likely to be hit on an older OS.
- [ ] **Check ChatKit's availability at all.** It is Mac Catalyst and ships inside
      `/System/iOSSupport`. Present on Tahoe; the further back we go the less certain that is,
      and the whole send path now depends on it.
- [ ] **Confirm the ChatKit attachment path exists pre-Tahoe.** Attachment sending goes through
      `CKMediaObjectManager`, and the IMCore path it replaced is dead on Tahoe for sandbox
      reasons. Whether the older path is the one that works on Sonoma is unmeasured — this may
      have to stay a runtime fork rather than a straight replacement.
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
      the user through creating the project by hand in the console. This port throws instead.
      If the fallback is still needed it belongs in `FirebaseView` as a guided step.

## Signing, notarization and stapling remain unverified

Unchanged since Phase 11, and the last thing standing between the build and a user installing
it. The scripts are written and exercised locally, but a Developer ID certificate and an App
Store Connect key are needed to prove them, and the first real tag is what does that. A
notarization failure is visible only to end users.

## The deployment matrix and the soak are unasserted

§ Verification: every phase's integration tests run against socket-only, webhook/ntfy-only,
full FCM, and each of those with and without the Private API. Sink independence is unit-tested
(`EventBusTests`) and that is a narrower claim; specifically missing is the assertion that a
socket-only install starts with **zero warnings**. Separately, `MemoryBudgetTests` covers the
+40 MB query budget and the no-accumulation property, but § 10's "< 60 MB idle, headless,
socket-only" and the 24-hour flat curve need the shipped binary and a soak harness that does
not exist.

- [ ] Make the matrix real, or write down that unit-level coverage is what we accept and why.
- [ ] Build the soak harness. This is the number the whole § 10 tactic list is justified by.

---

# 3. Designed but unbuilt

## `UpdateInstalling` has a seam, an endpoint, and no implementation

`POST /api/v1/server/update/install` is written against `UpdateInstalling`, declared in
`BBHandlers/HandlerCapabilities.swift`, that **nothing in the package conforms to**.
`AppContext.setUpdateInstaller(_:)` has no callers, so the endpoint refuses on every server, GUI
app included; the refusal says only that no updater is available, because that is all the code
can honestly know. The app checks for updates already (`UpdatesModel`, sharing `UpdateChecker`
with `GET /server/update/check`). What is missing is the half that installs one: there is no
Sparkle integration anywhere in the tree, only the appcast tool that publishes for it.
`AppContextWiringTests` asserts the installer is nil so the day someone implements it, a test
says what changed.

- [ ] Decide whether the app owns an updater at all. If yes: add Sparkle, conform something in
      `BlueBubblesApp`, call `setUpdateInstaller` during composition, and update the wiring
      test. If no: delete the seam, the setter, the endpoint and the `auto_install_updates`
      setting rather than leaving a route that is guaranteed to refuse.

## Socket replay stamps `seq` and can never be asked for it

The ring is maintained, `replay=1` is parsed, and a client that asks gets a `seq` on every
frame. What it cannot do is use it: `since` is parsed nowhere — `SocketClientOptions.parse`
reads `EIO`, `replay`, `transport` and `codecs` only — and `SocketServer.replay(since:)`
**has no caller**. The sequence number is already visible on the wire, so a client author could
reasonably build against a reconnect path that does not exist.

- [ ] Parse `since` at handshake, deliver the ring's tail before the live stream, and answer
      `resync-required` on overflow. Then test it — the only replay assertion today is that
      the opt-in parses.

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

## New surface to move to v2

`/api/v1` is the Node server's table and nothing else; everything this server added lives under
`/api/v2`. Three things have nowhere to live yet:

- [ ] **`GET /chat/:guid/typing` has no route.** `checkTypingStatus` is implemented in the
      bridge and wired through the client, so it is dead code from a client's point of view.
      Node has only POST and DELETE on `:guid/typing`, so this belongs in `AdditiveRoutes` —
      alongside `chatPinning`, which is there for the same reason.
- [ ] **Permission state has nowhere to go.** § 17 wants it on `GET /server/info`, and the
      compatibility contract forbids adding a field there. An additive
      `GET /api/v2/server/permissions` is exactly what the split is for. Decide and build it,
      or write down that clients do not need it.
- [ ] **Advertise v2 to clients.** Nothing tells a client which versions this server speaks;
      it has to probe. `server/info` cannot carry it — the field set is frozen — so this is
      itself a v2 route, or a header, or both. Worth deciding before any client adopts v2.

## Private API — still missing

- [ ] **`deny-nickname`.** Present upstream (`denyHandlesForNicknameSharing:`), absent from
      `BBPrivateAPIContract` entirely. The other two nickname actions are wired; this one was
      missed.

## Private API — design follow-ups

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
      frameworks, which Messages does not load. Probably a FindMy-hosted helper rather than
      anything the Messages helper can do — recorded as a conclusion rather than rediscovered.

## Scoped settings are handed out and only half used

`ScopedSettings` is constructed for every service and throws on an undeclared read, every
core read is now DECLARED on its manifest (the audit derived `watchedSettings` from those
declarations), and `ServiceSettingsBridge.validate` runs at startup. But only the connection
methods route their core reads through the scope; the other services still read
`context.settings` directly, so their entitlement lists are accurate documentation rather than
enforced limits.

- [ ] Mechanical to finish, and worth doing before any third-party loading exists so the pattern
      is uniform. The rule that matters: an undeclared read must THROW, not return nil —
      returning nil would recreate the "setting is silently inert" bug this exists to end.
- [ ] Note the honest limit: in-process code can read the database file directly, so the
      boundary is only real for the out-of-process plugins § 12 specifies. For first-party
      services it is a declaration that can be checked, not a sandbox.

## Plugin/service manifests — what is left

The model is enforced: `Service.manifest` is the single source of truth, `id`, `dependencies`
and `watchedSettings` derive from it, forms render, validation runs at startup, the five
connection methods are five services in an exclusive category, and every additive service has
an enable switch the registry honours. What remains:

- [ ] **A conflict found during composition cannot alert.** Validation runs before the alert
      centre exists, so an exclusive-category conflict is logged and not raised. Either move the
      centre earlier or re-validate once it is up (`SettingsPropagation` does not, despite a
      comment in `ServerComposition` that says it does).
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
      third-party loading exists. Built-ins can only be disabled.
- [ ] **Third-party loading stays closed.** § 12's out-of-process RPC design is unbuilt and the
      sensitive entitlements are refused to non-built-ins by the validator. That refusal is a
      placeholder for a decision, not the decision itself.

## An MCP server beside the HTTP API, and its setup step

Setup already offers "AI agent" as a use; today it routes to the HTTP API. The plan is a
service (manifest-described, in the `.integration` category, dependent on `http`) that speaks
the Model Context Protocol against the same interfaces layer the routes use, so an assistant
gets typed tools rather than raw endpoints. Done looks like: the service with its own
`ServiceFormView` fields (bind address, token), a `.mcp` case in `OnboardingStep.ID` included
for `.aiAgent` and embedding that form the way `.connection` embeds the tunnel's, and the API
step's "an MCP server is planned" sentence removed.

## Auth usage telemetry does not exist

§ Security: "the server records which connected clients authenticate how, so a future decision
about `auth_mode` rests on data rather than guesswork." Nothing records it. Purely
observational, changes nothing a client sees, and it is the evidence the deferred-migration
table would be argued from.

## There is no internal extension seam, and nothing needs one yet

A richer internal event stream with interception hooks was sketched during design and never
built. `CustomEventSink` is the only extension point, and `WebhookSink` and `NtfySink` go
through it with no special-casing, which is the standing proof it is expressive enough.

- [ ] Only if a concrete consumer appears — a service that must intercept an outgoing message
      before dispatch is the obvious one. Two properties are non-negotiable if it happens: a
      subscriber must not be able to stall the poller, and interception must fail **open** so a
      hook that throws or times out is skipped and the send proceeds.

---

## Reply threading has only been measured on macOS 26

`IMThreads` resolves a reply's `threadIdentifier` from the target part the way the
Objective-C helper has since Big Sur (`IMCreateThreadIdentifierForMessagePartChatItem`, or
the part's existing thread). Verified on 26.5.2 only; the shipping helper's four years on
Big Sur through Ventura are the evidence for the older releases.

- [ ] On a macOS 14 or 15 machine, send one reply through `/message/text` with the Private
      API and confirm `thread_originator_guid` is set. Done = one row.

## Text formatting: what the first pass left out

`textFormatting` on `/message/text` and per part on `/message/multipart` sends the four
styles and the eight menu effects (`.claude/docs/api.md` § Text formatting). Verified on
26.5.2 from the sender's side.

- [ ] Nobody has watched an effect play on a receiving device. The attribute and number
      match what iOS-sent rows carry, so it should, but "should" is the word.
- [ ] No recorded fixture carries `textFormatting`, so the inferred OpenAPI request schema
      for the two routes does not mention it. Either record one or add a hand-written
      body declaration the way `MultipartBodies` does for files.
- [ ] The read side reports the raw attribute keys and the effect NUMBER. A v2 read could
      add a decoded `formatting` array using `TextEffect(attributeValue:)`; v1 is frozen.
- [ ] The Flutter client neither renders nor sends these yet.

## Send Later and polls: what is left

`POST /api/v2/message/send-later` schedules through Apple (`docs/PRIVATE_API_SURFACE.md`
§ Send Later); polls are researched only, in [`docs/POLLS.md`](docs/POLLS.md).

- [ ] **Polls: look at one on a participant's phone.** Created and voted from here and both
      render on this Mac's transcript (options, vote); neither row showed a delivery receipt
      after two minutes. `docs/POLLS.md` § 8 has the remaining differences from Apple's rows.
- [ ] Polls: an existing option's TEXT cannot be edited from here; adding one can
      (`POST /api/v2/message/poll/:guid/option`). Same type-2 re-send, `docs/POLLS.md` § 6.
- [ ] `GET /api/v2/message/send-later` lists rows with `schedule_state` 1 or 2 — the two
      pending values observed. The states a DELIVERED scheduled message moves through were
      not observed (the test cancelled it); if one shows up in the list after delivery, that
      is the filter to widen.
- [ ] Editing a scheduled message's TEXT is not built; moving its time and releasing it early
      are (`PUT` and `…/send-now`). `editScheduledMessageItem:atPartIndex:withNewPartText:
      newPartTranslation:` is the selector for the text.
- [ ] Send Later is untested for attachments and multipart — only `sendMessage` carries
      `scheduledFor`. The same composition trick should work on `sendMultipart`.
- [ ] `_supportsSendLater` / `_supportsPolls` on IMChat are not consulted. A conversation that
      cannot schedule (SMS) will fail at ChatKit's `canSend` instead of being refused up front.
- [ ] Nothing verifies a scheduled message actually ARRIVES at its time; every test cancelled it.

## Emoji reactions: what the first pass left out

`reaction: emoji` on `/message/react` sends through `IMTapbackSender` (`docs/PRIVATE_API_SURFACE.md`
§ Tapbacks). Verified on 26.5.2 from the sender's side.

- [ ] Nothing has looked at an emoji reaction on a receiving device.
- [ ] The read side reports `associatedMessageType: "2006"` (the reference's numeric
      fallback) plus our `associatedMessageEmoji`. A v2 read could spell the type `emoji`;
      v1 stays as it is.
- [ ] The Flutter client neither renders nor sends emoji reactions.
- [ ] Sticker tapbacks (`IMStickerTapback`, 2007 / 3007) are the same sender with a
      different tapback object and a sticker transfer; not built.

## `POST /message/attachment/chunk` reads base64 JSON; the reference reads a multipart `chunk`

Found while fixing `/message/attachment`, which had the same problem: the reference's chunk
route (`messageRouter.sendAttachmentChunk`) reads `files.chunk` from a multipart form plus
`attachmentGuid`, `chunkIndex`, `totalChunks`, `isComplete` and the send fields as form
strings. This server's handler wants `attachmentChunkData` as base64 inside JSON, with
`index`/`total` keys the reference does not use. `MultipartBodies` documents the reference's
form, so the OpenAPI document promises one shape and the handler accepts another. No shipped
client appears to use the chunk route today, which is why it has not bitten.

- [ ] Accept the reference's form through `UploadedFileBody` (part `chunk`) and its field
      names, keeping the base64 body for whoever it was written for. Then add a
      `UploadedFileBodyTests` case for it.

## Stickers: what the first pass left out

`POST /api/v2/message/sticker` (additive, Private API) places a sticker on a message part
through the chain Messages itself runs — `docs/PRIVATE_API_SURFACE.md` § Stickers has the
selectors and the disassembly they came from. Sent twice from this Mac on 2 September 2026
to a test address; both rows landed with `associated_message_type 1000`, `is_sticker 1`,
the full `sticker_user_info`, `is_delivered 1`. What was verified is the SENDER's side.

- [ ] Look at one on a receiving device. chat.db here says the geometry, attribution and
      association are what an incoming iOS sticker carries, but the balloon has not been seen
      drawn. One difference is known: the sent `sticker_user_info` carries
      `stickerEffectType = -1` (what a bare `IMSticker` reports) where iOS-sent stickers omit
      the key. If the receiving device draws it wrong, `setStickerEffectType:0` on the
      `IMSticker` is the first thing to try.
- [ ] `stickerEffectType`, and animated stickers. `mediaObjectWithSticker:` picks
      `CKAnimatedStickerMediaObject` for an animated file and an `animatedImageCacheURL`
      travels with the transfer; nothing here sets either. A GIF/APNG sticker has not been
      tried.
- [ ] Emoji stickers (`associatedMessageType` 1001, `IMEmojiSticker`) and sticker TAPBACKS
      (`IMStickerTapback`, types 2007/3007, `-[IMChat sendTapback:forChatItem:]`) are
      different objects and are not built. The tapback form is what iOS 17's "react with a
      sticker" sends.
- [ ] Repositioning: `-[IMChat repositionSticker:associatedChatItem:]` exists. Not built.
- [ ] The fallback reaction path (no `IMTapbackSender`) still passes the bare message GUID
      and `(partIndex, 1)`. Emoji reactions are gated to macOS 15 at the interface, so on
      Sonoma only the six named tapbacks reach it; whether Sonoma has `IMTapbackSender` at
      all has not been checked.
- [ ] Record a fixture. The route sits in `docs/api/uncovered-routes.txt` because the
      conformance recorder runs against the Node server, which has no sticker route.
- [ ] An `NSException` raised inside an IMCore call surfaces as
      `PrivateAPIError.unavailableOnThisOS` (via `IMCoreLookupError.raised`), so a bad
      argument read as "requires a newer macOS" during this work. The two are different
      things to a user. Worth a distinct case.
- [ ] Client side: nothing in the Flutter app sends a sticker yet. It needs a sticker
      picker/drag target that knows the balloon's width to fill `parentPreviewWidth` and
      the scalars.

# 4. Robustness and known traps

- [ ] **`DaemonProcess` blocks its drain on an orphaned grandchild.** A daemon that forks a
      child which inherits the pipe's write end and outlives it leaves the read at termination
      unable to return until the orphan exits. The fixture hit a 30-second stall from
      `sh -c "…; sleep 30"`; cloudflared spawns helpers, so this is reachable in production.
      The file records why signalling the group is wrong today (the child inherits OUR group,
      so `kill(-pgid)` would hit the server). A bounded read, or `posix_spawn` with
      `POSIX_SPAWN_SETPGROUP` so the daemon has a group of its own, closes it.
- [ ] **Guard against the `send`-instead-of-`invoke` class of bug.** `IMCoreRuntime.send` uses
      `perform`, which has no exception barrier: a raise unwinds through Swift frames and kills
      the dispatch task WITHOUT killing the process, so the action applies and the caller waits
      forever for a reply. All five void writes moved to `invoke` and the rule is in `send`'s
      documentation — but documentation is not a guard. A source-level check ("no
      void-returning write calls `send`") catches the next one.
- [ ] **Decide what a partial-success reply should look like.** The `setDisplayName` failure was
      bad specifically because the action SUCCEEDED and the client was told it failed, which
      invites a retry of something already done. Worth a pass over the write paths for other
      places where the reply can be lost after the effect lands.
- [ ] **Sweep `AttachmentStaging` at startup, not only on stage.** The sweep runs from
      `stage()`. A server that crashes after staging and is then left idle keeps a copy of a
      user's file inside Messages' container until the next attachment is sent.
- [ ] **Conversion is synchronous with the request.** A first fetch of a large photo transcodes
      before any bytes are sent. Fine for a photo; worth measuring for a long voice note, where
      `AVAssetExportSession` is doing real work. If it is slow enough to matter, converting on
      ingest rather than on download moves the cost off the request path.
- [ ] **`FileBodySequence` is still the placeholder its own comment says it is.** § 10 calls for
      NIO's `FileRegion`/sendfile so attachment bytes never enter the heap; what ships reads 64
      KB chunks through a blocking `FileHandle.read` on a cooperative-pool thread. Peak memory
      is bounded, which is the property that mattered, so this is a latency and thread-parking
      concern rather than a correctness one.
- [ ] **`reindexAll` has a window where the address book does not exist.** It deletes every
      `.macOS` contact and then streams the new ones in batches, so a message serialized during
      a reindex can show a phone number instead of a name. One write transaction can span the
      streamed batches, at the cost of holding the write lock for the length of the ingest.
      Worth measuring which is worse on a large address book.
- [ ] **`lan_address` and `bind_address` can disagree.** Binding to `192.168.1.50` while
      publishing `10.0.0.5` produces a URL nothing can reach, and neither setting is wrong on
      its own. Worth a validation warning on the Connection settings — not a hard refusal, since
      a NAT or a reverse proxy is a legitimate reason for them to differ.
- [ ] **`os_log` does not escape an injected dylib in a sandboxed host.** Measured on macOS
      26.5.2: queries by subsystem, by `senderImagePath` and by process all return nothing while
      the helper is running. `HelperMain` still logs through `os_log`, so those lines are
      write-only. Either find a channel that works or drop the logging and lean on the socket,
      which demonstrably does.

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
      invocation AND `executableName`, which currently cannot vary by version.
- [ ] **A tool is never uninstalled.** Switching connection method leaves the binary on disk and
      there is no remove button. Cheap to add, and worth pairing with a size readout —
      cloudflared is 38 MB and nothing tells the user it is there.
- [ ] **Nothing verifies a bundled or user-chosen binary.** `adoptExternalBinary` checks only
      that the file is executable. That is the right default for an explicit act, but the
      signature could still be REPORTED on the page rather than left unstated.
- [ ] **Update checks are gated on `check_for_updates`, which defaults off.** Deliberate — a
      scheduled check is network traffic nobody asked for — but it means most installs will
      never be told about a new cloudflared unless they press Check. The one key is doing two
      different jobs.

## Deliberately not built, recorded so it is not re-litigated

- **Multiple simultaneous proxy services.** The tunnels have no conflict with each other; what
  blocks it is that `server_address` is a single string with six consumers, and downstream of
  that, clients store one URL, so publishing several helps nobody until a client can hold a
  list and fail over. § 17's tunnel allowlist also assumes one egress address. **The
  LAN-plus-tunnel case that motivates this needs no multi-provider work**: `server/info` already
  advertises `local_ipv4s`. Revisit only alongside client-side failover.
- **Inbound socket commands.** The socket is server→client only. Re-adding the ~30 legacy
  commands would mean a second implementation of every endpoint, with its own auth, over a
  transport never designed to carry it.
- **Google contacts sync.** Removed: `CNContactStore` sees Google-synced contacts. Verified on
  macOS 26.5.2 with a Google account in Contacts.app: 584 contacts indexed, 25/25 sampled
  CardDAV numbers resolved through the index.
- **A helper-side `searchMessages`.** The server answers the same question from chat.db with
  SQL, over full history and with paging. Do not add a second, slower implementation that
  disagrees with the first.
- **Moving the `app.db` repositories out of `BBInterfaces`.** Tried and retracted: it pushes
  GRDB into `BBDiagnostics`, `BBEvents` and `BBPushKit`, none of which has a persistence
  dependency. `BBDiagnostics` declares `AlertStoring` and `AlertRepository` implements it from
  above; that is dependency inversion working, not a misplaced file. The FaceTime and FindMy
  subsystems DID move (`BBFaceTime`, `BBSystem`), which was the narrowing that held.
- **A per-module default for `BBError.domain`/`code`.** The repeated lines are the per-case
  `code` switches, and `code` is a searchable contract that has to be written out.

---

# 5. UI parity and cleanup

## Settings that are declared, invisible and unread — decide, then delete or build

Each has a `Setting` declaration under `Settings.Legacy` with no `presentation:` AND no
reader. Do not give them a row; decide whether they mean anything. (`tutorial_is_done` is the
exception with a user-visible consequence and is in § 1.)

- [ ] **`encrypt_coms`** — superseded by the `sealed-v2` codec. Delete.
- [ ] **`start_via_terminal`** — an Electron relaunch workaround. Delete.
- [ ] **`disable_gpu`** — Electron-only. Delete.
- [ ] **`private_api_mode`** — the Electron server's choice of injection mechanism. There is
      one here, so the row is carried and never read. Delete.
- [ ] **`headless`** — the SETTING is dead, but `--headless` works: `LaunchOptions` parses it
      into `ServerComposition.Options` directly. Remove the setting or have the launch path read
      it, but not both spellings.
- [ ] **`auto_install_updates`** — no installer path. Tied to the `UpdateInstalling` decision
      in § 3; goes whichever way that goes.
- [ ] **`facetime_calling`** — nothing gates on it. (`enable_ft_private_api` IS read: it gates
      every FaceTime route and the helper's injection.)

## Actions the old UI had and the new one does not

- [ ] **Restart controls.** `AppModel.restart()` has exactly one caller, the `.restartServer`
      alert action. The old Debug & Logs page offered *Restart Services*, *Full Restart* and
      *Restart via Terminal*; the new UI has only Start/Stop, so recovering from a wedged
      service means quitting the app.
- [ ] **Contacts: Add Contact, Import VCF, Clear Local Contacts.** The new page can only refresh
      from the Address Book. `ContactDialog` (first/last/display name, addresses) has no
      counterpart, and `POST /contact/import/vcf` exists server-side.
- [ ] **Logs: Open Log Location, Open App Location, Copy Binary Path, Clear Logs, Show Messages
      App Logs.** The new page has level, filter, follow and copy.
- [ ] **Attachment cache info and clear.** Old `AttachmentCacheBox` showed attachment count and
      cache size in MB with a clear button. `AttachmentConversion` sweeps on a budget now; the
      readout and the button are UI only.
- [ ] **Danger Zone.** Old `ResetSettings` offered *Reset Tutorial* and *Reset App* (wipe all
      configuration and restart). Per-service "Reset to Defaults" and the onboarding reset
      exist; a whole-app reset does not.

## Home page

The old Home was the connect-a-client page; the new one is a status grid.

- [ ] **Server URL with a copy button, and the QR code.** The QR code does not exist anywhere
      in the Swift app, and pairing by hand-typing an ngrok URL into a phone is the worst
      version of setup. `GuidesView` shows the address with a Copy button, but nobody looks
      there first.
- [ ] **The insecure-connection warning.** Old Home warned, at length, when the address was
      plain HTTP.
- [ ] **Computer ID.** Present in `/server/info`, shown nowhere.
- [ ] **Stats.** Old: Total Messages, Daily Messages (with a timeframe dropdown), Best Friend,
      Top Group, Total Pictures, Total Videos. New: Messages, Chats, Handles, Attachments.
      `/server/statistics/media` exists, so pictures/videos are a UI change; best friend and top
      group need new queries.

## Other app gaps

- [ ] **Alert actions are only reachable from the bell.** The remedy renders where the problem
      is reported, which is the § 17 requirement — but macOS notification banners carry no
      actions, so an alert raised while the app is in the background still needs the user to
      open the app and find it. `UNNotificationAction`s mapping to the same `AlertAction`
      cases would close it.
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

## Behaviour still living in the composition root

`BBBuiltIns` took the service declarations out of `BlueBubblesServerCore/Composition`; three
things there are still behaviour rather than wiring: `TLSProvisioning` (certificate lookup and
self-signed generation), the per-vendor option building in `Services/Proxy/*Method.swift`, and
`ServerAddressAnnouncer`. The first two belong beside the modules they drive (`BBSystem` and
`BBProxy`); the announcer is owned by `ServerLifecycle` now and can stay.

## `@unchecked Sendable` not re-audited, and the helper's statics

Eleven `nonisolated(unsafe)` statics remain, all inside the injected helpers and none in the
server. Each is written once at load before any listener exists and says so; none is a latch.
25 `@unchecked Sendable` conformances remain in `Sources`+`Helper`; the ones touched in the
lock pass carry a precise comment, the rest were not re-read. Done looks like: each
`@unchecked` names the invariant that makes it safe, or becomes an `OSAllocatedUnfairLock`.

## `AppModel` still owns tool-status observation

`toolStatuses`, `toolsTask`, `toolObservers` and `beginObservingTools` stayed on the root
model in the split; a `ToolsModel` following the `PermissionsModel` pattern is the obvious
next cut, and `ToolActions` is its only consumer.

## Small tasks

- [ ] **A test asserting every setting with a `presentation:` has a READER.** The existing
      `RenderableSettingsTests` catches the adjacent mistake — a presented setting missing from
      `renderable`. It cannot be a grep from inside the test process, but a build-time script
      over `Sources/` wired into CI is the same shape as the coverage check that already exists.
- [ ] **Dump headers for ChatKit and the daemon listener.** The header-dump script this list
      used to cite (`Tools/header-dump/dump.sh`) is no longer in the tree, so this is two
      steps: restore or rewrite a dumper that reads the running Objective-C runtime into
      `docs/headers/macos-<version>/`, then add ChatKit's `CKMediaObjectManager` /
      `CKComposition` — which the send path now depends on — and `_IMLegacyDaemonListener`'s 127
      methods. The frameworks are NOT on disk on macOS 26 (dyld shared cache); extract with
      `dyld_shared_cache_util -extract`.
- [ ] **Test group 481** ("Renamed By Swift Helper", `any;+;bcb9a1843dfc4b65bb47ce50afec8d32`)
      is left in the user's Messages with the user departed from it. Delete when convenient.
