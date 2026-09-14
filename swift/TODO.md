# Running list

Things to do or think about later. Not a backlog of everything: the docs hold the
design. This is for what we deliberately deferred, what we could not verify from here, and
what we learned late enough that it did not get folded in.

Each entry says what it is, why it is not done, and what "done" would look like, so it can be
picked up cold. Finished work is deleted, not struck through: git holds the history, and a
list that carries its own past stops being readable as a list.

**Ordered by priority, re-swept 14 September 2026.** Since the last sort: the attachment
send that killed Messages, the validation sweep, the `tempGuid` guard and the access-control
write ordering all landed, and their entries are gone or reduced to what is genuinely left.
Two entries moved DOWN within § 1 rather than out — a residual is not a defect — and one
moved from § 1 to § 2, because what remains of it is a testing practice rather than
something a user meets.

Section 1 is what is wrong for a user or a contributor right now. Section 2 is verification
the plan claims and CI does not do, plus shipping surface no test touches. Section 3 is
designed-but-unbuilt surface. Section 4 is private-API features measured from the sender's
side and nowhere else. Section 5 is UI parity. Section 6 is housekeeping. Within a section,
worst first.

---

# 1. Wrong for users now

## Searching message text finds nothing on Tahoe, and answers 200 while it does it

`where: [{"statement": "message.text LIKE ?", ...}]` becomes `m.text LIKE ? COLLATE NOCASE`
(`MessageRepository.messagePredicate`, the `.textLike` case). macOS 26 stopped populating
`message.text`: the words live in `attributedBody` and nowhere else, so that predicate matches
almost nothing a user has received recently.

**MEASURED on 14 September 2026**, decoding the newest 500 bodies with `AttributedBodyDecoder`
and asking whether a real word from each decoded body also appears in that row's `text`:

| | |
| --- | --- |
| messages checked (all decodable) | 500 |
| `text` column empty | **491** |
| a genuine word from the body also found in `text` | **9** |

It arrived as a cliff rather than a drift, which is why it was not noticed earlier: the whole
database is only 3.1% empty-text, because the history predates it.

| month | rows with empty `text` |
| --- | --- |
| through 2026-06 | 0-1.5% |
| 2026-07 | 47.3% |
| 2026-08 | **99.9%** |
| 2026-09 | **99.5%** |

**The asymmetry is what makes it a user-facing defect rather than a curiosity.** The serializer
already reads through to the body: `universalText(decoded:)` fills the response's `text` from
`attributedBody` when the column is empty. So the message is in the list, the words are on the
screen, the user searches for one of them, and the server answers **200 with `total: 0`**. The
client cannot tell a miss from an empty database. `metadata.total` shares the predicate, so it
is consistently wrong rather than inconsistently, which is the only good thing here.

**Not a regression, and not parity drift.** The reference is identically blind: its
`universalText()` is an OUTPUT fallback (`entity/Message.ts`), and its `where` is a raw SQL
passthrough, so its search hits `message.text` too. Both servers went blind on the same macOS
release. We are nevertheless better placed to fix it, and fixing it is NOT a divergence a
client can see in its request: our `where` is a typed allowlist, so the client goes on sending
`message.text LIKE ?` and only the rows coming back change.

**The cheap fix was tried and rejected.** Byte-searching the blob
(`instr(m.attributedBody, CAST(? AS BLOB))`) finds the word in only **283 of 500** — typedstream
stores non-ASCII strings UTF-16-encoded, so anything carrying an accent, an emoji or a smart
quote is NUL-interleaved and a UTF-8 needle walks past it. A search that works for plain ASCII
and silently misses the rest is worse than one that misses cleanly, because it looks repaired.
There is also no index to borrow: `chat.db` ships no FTS table, and Apple indexes messages
out-of-process through Spotlight, which is what `index_state` and
`message_idx_pending_indexing_messages` are for.

Deferred rather than rushed: the honest fix is a store of our own, and a half-built one is the
failure above wearing a different hat.

- [ ] **A searchable text column in `app.db`, ideally FTS5**, written by the change detector as
      messages land, holding `universalText()` keyed by message GUID. This is the only option
      that makes GLOBAL search work. Backfill is a one-off migration over the existing history:
      decoding is ~0.013 ms per message (measured), so 421,125 rows is roughly 6 seconds of CPU
      — fine as a migration, **not** fine on the startup path, so it needs to run behind the
      same progress-reporting shape the other migrations use and leave search degraded rather
      than blocked until it finishes.
- [ ] Decide what a miss means while the backfill is incomplete. Answering from the column
      alone silently under-reports exactly like today; the alternative is saying so in
      `metadata`, which is a new key and therefore a contract.
- [ ] **Interim, and much smaller**: decode-and-filter server-side when the query is ALREADY
      scoped — a `chatGuid`, or an `after`/`before` bound. At 0.013 ms a message that is a few
      milliseconds for a conversation and unusable for the 421k-row unscoped case, so it is a
      real improvement for in-conversation search and must not be offered for global search.
- [ ] Whatever lands, a test that pins the thing the current code gets wrong: a message whose
      `text` is empty and whose body carries the term MUST be returned by
      `message.text LIKE ?`. `MessageFilterSQLTests` is where it goes, and it has to assert the
      ROWS and the `total`, both of which are wrong today.

## A pinned bind address that disappears retries ten times and gives up

The retry is correct and deliberate: at login the server can start before Wi-Fi associates,
but the backoff exhausts, so a network that comes up two minutes later leaves the server bound
to nothing until someone restarts it.

- [ ] Either retry indefinitely for this specific error, or watch for interface changes
      (`NWPathMonitor`) and rebind.

## An upload is kept for a day after the send that needed it

`UploadStore` sweeps: a day's age, a 2 GB ceiling oldest-first, behind the same hourly
`IntervalGate` the conversion cache uses. So growth is bounded, and what is left is a
duplicate of every file a client sends sitting on the disk for up to 24 hours — which on the
old Mac mini this project targets is the cost worth removing.

**MEASURED on 13 September 2026, because the obvious worry is that deleting our copy takes
the attachment out of Messages, and it does not.** A sent attachment exists three times:

| copy | where | referenced by `chat.db` |
| --- | --- | --- |
| ours | `Application Support/bluebubbles-server/uploads/<id>/` | **no row, ever**: 0 of 12083 |
| the helper's | Messages' own container, via `AttachmentStaging` | no |
| Apple's | `~/Library/Messages/Attachments/<xx>/<xx>/<guid>/` | yes: 1508 outgoing rows |

`attachment.filename` points at Apple's copy, which is a regular file with a link count of 1
— its own bytes, not a hardlink or a clone of ours — so nothing we delete can reach it. The
demonstration is the middle row: the helper's staging copy of a test attachment sent that day
is ALREADY swept, and the attachment still draws in the transcript.

The real hazard is the one the old wording pointed at: deleting our copy while the transfer
is still READING it. A 200 from the send route does not mean imagent has finished copying the
bytes, which is why `AttachmentStaging` sweeps by age rather than on completion.

- [ ] Drop our copy once Apple has one, which the send path can already tell. The hydration
      wait holds the response until the row appears in `chat.db`; at that point the
      attachment row's `filename` can be read and checked for a non-empty file under
      `~/Library/Messages/Attachments`. That is a completion signal already in hand — no
      transfer-state observation, no new helper surface — and it degrades to the existing age
      sweep whenever the check does not come back cleanly. The cheaper alternative, if this
      is not worth the code: shorten the age limit and write down that a duplicate lives that
      long.

## A message delayed by more than thirty minutes is announced as history, not news

A row carries the time the message was SENT. The detector announces an unseen row as new when
it postdates the cursor or is dated within the 30-minute fast window; anything older is cached
silently, which is what keeps an iCloud backfill from becoming thousands of notifications. The
same line means a message that arrives more than thirty minutes after it was sent (a long
outage, a sender offline for an hour) raises no `new-message` event. The Electron server
never announced late arrivals at all, so this is strictly better, but the constant is a guess
at where "late" ends and "history" begins, and nobody has measured real outage backlogs.

- [ ] If users report delayed messages arriving silently, widen `fastLookback`'s role in the
      new-message rule (it is one `min` in `ChangeDetector.tick`) or key it on a ROWID
      high-water mark instead, and add the case to `ChangeDetectorTests.lateArrivalIsNew`.

## `canReportJunk` reports false on Sonoma while reporting works

Read from `-_messageToReportJunk`, which only 26 has, so it defaults to `false` on 14, while
`-allMessagesToReportAsSpam`, which `messagesToReportAsSpamCount()` already calls two methods
below and which the junk ladder now uses for its return value, is on all three releases. A
client that hides the button on this flag hides a working feature. Sequoia has
`_messageToReportJunk`, so this one is Sonoma-only.

- [ ] Fall back to `allMessagesToReportAsSpam` being non-empty.

## Spam counts only see the transcript Messages has already loaded

`-[IMChat allMessagesToReportAsSpam]` disassembles to one line:
`[self messagesToReportAsSpamFromChatItems:[self chatItems]]`, and `-chatItems` builds from
the chat's in-memory `_items` through `chatItemRulesClass`. **Nothing in that path queries
`chat.db`.** So `messagesToReportAsSpamCount()` answers about the loaded transcript window,
not the conversation:

- a chat the user has never opened in Messages reports **0 messages to report**, which a
  client reads as "nothing to report" and shows as a disabled button;
- a chat the user has scrolled a long way back in reports more than a freshly opened one;
- and `markAsSpam(count:)` is HANDED that number, so the count it records is whatever
  happened to be in memory.

Not a version difference: same selectors on 14.6.1, 15.6.1 and 26.5.2, and it is Messages'
own behaviour rather than something this port does wrong: Messages never asks unless the
conversation is on screen. But this server is asked over HTTP about conversations nobody has
opened, which is the case Apple's implementation does not have.

`IMChat` carries `loadMessagesUpToGUID:`, `loadMessagesBeforeDate:` and
`loadUnreadMessagesWithLimit:` on all three releases. Nothing in `Helper/` calls any of them.

- [ ] Decide whether the junk/spam routes should load first, and how far back. It is a
      product question before a technical one: "report this conversation as junk" probably
      means the whole conversation, but the API cannot express that today and silently means
      "the part of it that happens to be in memory".
- [ ] Until then, say so where a client can see it. `ChatSpamResult.messageCount` reads as
      authoritative and is not.
- [ ] Cross-check against `chat.db`, which this server can already query, rather than
      trusting IMCore's in-memory view for the COUNT while still using IMCore for the report.

## Two 26-only features a client cannot tell from a bug

Both are genuinely absent below macOS 26, and neither is refused before the helper is asked:
so a client sees a thrown selector or a `false` flag rather than "not supported here".
`docs/MACOS_COMPATIBILITY.md` §3a.

- [ ] Chat backgrounds: `refetchLocalTranscriptBackgroundAssetIfNecessary` throws on 14 and 15.
- [ ] Screen Unknown Senders: `cachedIsKnownSender` and `inUnknownSendersFilter` default to
      `false`, and `markAsKnownAndSaveInContacts:completion:` throws.

## An upgrading user who finished the old tutorial is shown onboarding again

Onboarding gates on `UserDefaults` `hasCompletedOnboarding`, while `LegacyConfigMigration`
writes the Electron `tutorial_is_done` into a `Settings.Legacy` row that nothing reads. So the
migrated value lands where nothing looks, and the walkthrough runs for someone who already
did it. One source of truth, and it should be the migrated one.

- [ ] Have `OnboardingModel.isComplete` consult the migrated row (or seed the default from it
      on first launch), then delete the duplicate. Pair with the dead-settings sweep in § 5.

## A retry can still send twice once the first send has finished

`SendCache` closes the window that mattered: a `tempGuid` with a send IN FLIGHT is claimed,
and a second request carrying it is refused with the reference's own sentence ("Message is
already queued to be sent (Temp GUID: …)!") rather than putting a second message in
somebody's conversation. Measured live: three concurrent requests under one `tempGuid`
produced one send and two refusals, and the same id sent again once the first completed.

Not a transcription, and the entry that asked for one was right to call it a behaviour
question. The reference's HTTP routes `add` and `remove` without ever calling `find`; the
only reader is its socket send path, which this server does not implement at all. So the
claim was applied where this server's clients actually send.

What is left is the case a claim cannot cover:

- [ ] **A retry that arrives after the first send finished sends twice, and always will
      under this design.** The claim is released when the send completes, so a client whose
      request timed out at 61 seconds — one second past the hydration ceiling — retries into
      an empty cache. Closing that needs the server to remember COMPLETED sends and answer a
      duplicate with the original response, which is an idempotency key rather than an
      in-flight guard: a different contract, with a different failure (a client that reuses
      a `tempGuid` deliberately would get the old message back instead of sending a new one).
      Worth doing only if a client reports the duplicate; the reference has the same gap and
      nobody has.

## Access control writes are ordered; nothing retries a failed one

`AccessControlService` had one detached task per change, each carrying its own snapshot and
nothing sequencing them, so a block and the unblock that followed it raced and the OLDER
snapshot could land last: "I unblocked that address, and after a restart it was blocked
again". There is one writer now, it re-reads the live state immediately before each write,
and `ServerComposition.stop` flushes it so a change made seconds before a restart is not
lost. That was the last of the ten audit findings.

`AccessControlWriteOrderTests` holds the first write open while the second is made, which
is what makes the race deterministic — a plain delay did NOT: both writes finished in the
order they started and the suite passed against the broken implementation until the double
was rewritten. It fails against it now, with the address coming back blocked.

- [ ] **A failed write is logged and dropped.** Both the old code and this one treat a
      throwing `saveBlocked` as "log it and move on", on the reasoning that the next change
      rewrites the whole table anyway. That is true and it is not durability: if the write
      that fails is the LAST one, the durable state stays stale until something else changes,
      and nothing tells the operator. A retry with a bounded backoff, or an alert on a write
      that has failed repeatedly, is the shape; the alert centre is already wired here for
      the block-raised warning.

## The keychain is asserted at signing; the app still cannot say which one it is using

`KeychainSecretStore` writes to the data protection keychain, where access is decided by the
`keychain-access-groups` entitlement and a process outside the group is refused categorically,
with no prompt and no dialog to click through. That is what meets § Security #1 ("bound to the
app's code signature rather than readable by any same-user process"), and it is a stronger
property than the `SecAccessControl` this entry used to ask for: an ACL is the LEGACY
keychain's mechanism, it authorises by PROMPTING, and a prompt on the TLS bind path is
invisible in a launchd process. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is honoured
here, where the legacy keychain ignored it entirely; not `WhenUnlocked`, because `auto_lock_mac`
means the server has to keep serving behind a locked screen.

So #1 is met **in a signed release build**, and only there. `Packaging/sign-app.sh` now runs the
nested CLI's `--check-keychain` after signing and fails the build if it fell back to the legacy
store, which closes the dangerous half: a release whose provisioning profile did not embed,
expired, or was issued for a different App ID can no longer ship silently putting every secret
in the weaker store. The check writes a probe item, reads it back and deletes it before
answering, because `usingDataProtection` resolves lazily, on the first call that returns
`errSecMissingEntitlement`; reading the flag without doing keychain work reports success on
exactly the builds the check exists to reject. Verified in both directions against real
signatures.

What is left is the runtime half, and the bytes the old builds left behind:

- [ ] Surface `KeychainSecretStore.usingDataProtection` on the Security or Permissions page and
      in `server/info`'s diagnostics, so "which keychain am I using" is answerable by a user
      rather than only by whoever signed the build. The signing assertion cannot cover a
      profile that expires on an already-installed copy.
- [ ] Decide what happens to items an older build wrote to the legacy keychain. Nothing reads
      them now, so they are dead bytes holding a password in a store this build no longer
      opens. They cannot be moved in place (read, delete, rewrite) and the honest options are
      a one-time sweep or leaving them and documenting it.

---

# 2. Verification the plan claims and CI does not do, and code nothing tests

## Signing, notarization and stapling remain unverified

Unchanged since Phase 11, and the last thing standing between the build and a user installing
it. The scripts are written and exercised locally, but a Developer ID certificate and an App
Store Connect key are needed to prove them, and the first real tag is what does that. A
notarization failure is visible only to end users.

## macOS versions other than the host

The floor is **macOS 14 (Sonoma)** through **Tahoe (26)**. CI runs on `macos-15` only, and
every private-API finding in this project was measured on Tahoe, because that is the host; at
least one conclusion drawn that way has already turned out to be backwards. **These need
headers or a real machine per version, not more reasoning.**

- [ ] **Dump the `AVConference` classes on Sonoma and Sequoia: they exist on NO release.**
      `Tools/private-api/hosts.conf` now declares `AVConferencePreview`, `VCCameraPreview` and
      `AVCamera` under the FaceTime group, but no folder under `docs/headers/` has them:
      14.6.1, 15.6.1 and 26.5.2 all report zero. Everything the idle-camera work rests on came
      from `Tools/private-api/probe.sh` against the LIVE Tahoe runtime, which gives selector
      names and nothing else: no signatures, no return types, no arity. That is thin evidence
      for a class we send `stopPreview` to inside somebody's FaceTime.app, and it is exactly
      the shape of evidence that produced the void-return crash: `stopPreview` returns `void`,
      which a header would have said and a selector list did not.
      Regenerate per release in the VM (never on the host; `docs/private-api/macos-versions.md`)
      and then let `compare-releases.py` do its job, which it currently cannot for these at
      all. Watch particularly for `+AVConferencePreviewSingleton`, an accessor spelling that
      matches none of `IMCoreRuntime.sharedInstance`'s defaults and is named explicitly at the
      call site, and for `TUVideoDeviceControllerProvider`, the delegate the stop is actually
      sent to, reached through `AVConferencePreview.delegate` because it has no singleton.
- [ ] **Run `IMCoreSelectorTests` on Sonoma and Sequoia.** It pins ~30 IMCore selectors, and a
      red test names the selector that moved, which is the whole diagnosis.
- [ ] **Re-check every `unavailableOnThisOS` branch per version.** Each was derived from
      Tahoe-only probing, so a branch may be exactly inverted on an older OS. Current sites:
      `shareNickname` (`IMNicknameController`), `setPinned` (falls back to
      `setPinnedConversationIdentifiers:withUpdateReason:`, which is what the reference targets
      and which Tahoe has REMOVED), and FindMy's two modern-session-only calls,
      `refreshFindMyLocation` and `requestFindMyLocationShare`, which report unavailable when
      `fmlSession` is nil: the branch most likely to be hit on an older OS.
- [ ] **Check ChatKit's availability at all.** It is Mac Catalyst and ships inside
      `/System/iOSSupport`. Present on Tahoe; the further back we go the less certain that is,
      and the whole send path now depends on it.
- [ ] **Confirm the ChatKit attachment path exists pre-Tahoe.** Attachment sending goes through
      `CKMediaObjectManager`, and the IMCore path it replaced is dead on Tahoe for sandbox
      reasons. Whether the older path is the one that works on Sonoma is unmeasured; this may
      have to stay a runtime fork rather than a straight replacement.
- [ ] **Check `IMChat.deleteChatItems:` on older versions.** We moved off the reference's
      `CKChatController.deleteChatItem:` because a headless controller silently deletes nothing
      on Tahoe. `deleteChatItems:` is the model-layer call and is likely older and more stable,
      but that is an assumption.

## Verify the version ladders on real hardware

All twelve selector ladders are written and none is runtime-tested below macOS 26. They are
verified three ways: every rung resolves against the runtime dump for its release, each
release matches exactly one rung, and every call site was read rather than inferred from
`compare-releases.py`, but that is not the same as a message actually sending.

The Sonoma VM is gone; a Sequoia VM existed as of 3 September 2026.

- [ ] On Sequoia, exercise the four paths whose fallback that release actually takes: report
      junk, leave Junk, start a FaceTime call, edit a scheduled message. The first three are
      shared with Sonoma, so they cover both.
- [ ] On Sonoma, if a machine appears: the above plus send a sticker, revoke a FaceTime link,
      send a named tapback, and mute a chat: the four whose Sonoma rung nothing else exercises.

## Three Sonoma questions that now need a macOS 14 machine to exist again

The Sonoma VM has been deleted. None of these blocks a fix: every remaining ladder is
readable off `docs/headers/macos-14.6.1/`, which we still have, but each would have raised
confidence in one, and none can be answered from here now.

- [ ] **The `IMNickname` avatar accessors on Sonoma.** `IMNickname`, `IMNicknameAvatar` and
      `IMNicknameAvatarImage` went into `hosts.conf` after that dump was taken, so `-avatar`,
      `-imageExists` and `-imageFilePath` are unmeasured on 14. All three are `try?`-wrapped
      and degrade to a contact card with no photo, so the exposure is cosmetic. Closing it is
      one `dump-headers-vm.sh` run whenever a Sonoma machine is next available.
- [ ] **Whether `-[IMChat setMuteUntilDate:]` on Sonoma writes where Messages reads.**
      `CHAT_CONTROLS_PLAN.md` §0 measured the `CKDNDList` defaults store on **Tahoe**, and
      that does not transfer. The Sonoma mute path is correct as written; what is unverified
      is whether Messages honours it, and "mute reports success and Messages still notifies"
      is the failure a user would find first.
- [ ] **The shape of `+[IMTapback tapbackWithAssociatedMessageType:messageSummaryInfo:]`.**
      Needed to ladder the reaction path on Sonoma instead of falling back to the association
      initializer: the fallback is correct but has coarser part ranges, which is what the
      sender path was introduced to improve. `probe.sh` / `trace.sh` on a 14 machine.

## Whether muting reaches paired devices on macOS 14 is unmeasured

`IMMutedChatList` arrives in macOS 15 and carries `muteChat:untilDate:syncToPairedDevice:`.
The Sonoma path goes through `-[IMChat setMuteUntilDate:]`, which takes no such argument:
but that does not mean it fails to sync, only that this code cannot steer it. IMCore may
sync it anyway.

It matters because it is the difference between two sentences a user would read very
differently: "muting works" and "muting works but might not reach your iPhone". The
capability catalog deliberately carries neither, because a row there has to be a fact.

- [ ] Measure on a macOS 14 machine with a paired device: mute here, see whether the iPhone
      goes quiet. If it does not sync, add a `PrivateAPICapability` for it; if it does, this
      entry can be deleted.

## The change-detection backup is untested against the idle-FSEvents failure

The Electron server watched `chat.db` through `fs.watch`, which on macOS is FSEvents, and on
some Macs those stop arriving once the disk has been idle: users wrote "pokers" that touch
`chat.db` to wake them. The Swift server watches through kqueue on open descriptors and backs
that up with a `PRAGMA data_version` check every `db_poll_interval` (30 seconds at least),
which needs no file-system event at all, so on paper neither the failure nor the poker applies.
If the watcher does go deaf, three backup passes in a row that find unannounced commits tear it
down and re-arm it, logging "chat.db commits are arriving without file events". Nobody has
watched any of this on a Mac that actually exhibits the failure; the root cause was never
pinned down, and "a different kernel mechanism" is an argument, not a measurement.

- [ ] On a machine known to need a poker, run without one, leave it idle past the point
      where the old server went quiet, and confirm a message arrives within 30 seconds.
- [ ] Watch the log for the re-arm warning. If it appears, the descriptors went stale and
      the self-heal is doing its job; if messages are late and it never appears,
      `data_version` itself stopped moving, which is a different fix.

## Confirm the rung-2 handler is CALLED, not just registered

Registration is proven on macOS 26.5.2: the helper reports `events: "daemon-listener"` and the
server logs it. Delivery is not: an outgoing send does not fire `messageReceived:`, so
confirming it needs an inbound message from another device while the helper is injected.
Done = a `started-typing` event reaching the server when someone types in a chat. If the
handler turns out NOT to be called alongside Messages' own, rung 3 (swizzling
`IMChat._handleIncomingItem:`) is the fallback and `EventObservation` is where it goes.

## The parity corpus is replayed; six things it still cannot see

`FixtureReplayTests` now mounts the shipping router in-process over the synthetic `chat.db` and
replays every recorded v1 fixture on each build, with
`Tests/CompatibilityTests/Fixtures/replay-baseline.json` as a two-way ratchet. That closed the
worst of this entry: the claim "the compatibility contract is mechanically enforced" is now
true rather than aspirational, and the first run found the envelope swap described below. What
it still does not do:

- [ ] **Nothing compares response HEADERS.** `Sources/BBParity` contains no occurrence of
      `header` outside the provenance sniff: the recorder captures them, the diff ignores them.
      So the "Misc" contract rows are asserted by nothing: wide-open CORS, `?pretty`, the 504
      timeout body, and `Content-Disposition` on file streams. **It has already diverged:** the
      recorded Node responses carry `access-control-allow-methods` on ordinary 200s, and
      `CORSMiddleware` sends that header only on `OPTIONS` while adding an `allow-headers` Node
      does not send. This is also what `RecordedFixture.recordedFrom` leans on to tell a
      Node recording from one of ours, so fixing the CORS divergence and recording the
      provenance explicitly have to happen together; see the entry below.
- [ ] **Record the write paths that touch only the server's own database.** `POST`/`DELETE`
      `/backup/theme` and `/backup/settings`, `POST /webhook` and `DELETE /webhook/:id`,
      `POST /server/alert/read`, `POST /fcm/device`, the four `/message/schedule` routes and the
      six `/contact` writes send nothing to anyone and can be recorded today against a throwaway
      server. `bb-openapi coverage --check` reports the gap and ratchets it.
- [ ] **Record the sends, carefully.** Sends, reactions, edits and group management are unpinned:
      exactly where the helper work lives. Needs a dedicated throwaway conversation and a
      driver that is explicit about what it will send. Note that the replay DENY-LISTS all of
      these (see below), so recording them buys `bb-parity` coverage, not CI coverage.
      `POST /message/attachment` is the one to do first, and it is now known to work: sent
      live on 13 September 2026 through the shipping route (200, `is_sent 1`, `error 0`, the
      attachment row carrying the bytes). What has no FIXTURE is the wire shape.
- [ ] **Capture the socket transcript.** The HTTP half is recorded; the handshake and frame
      sequence are not, and `Fixtures/` has no `socket/` directory yet.
- [ ] **Record an attachment with EXIF.** Every attachment in the corpus is a test PNG, and all
      three carry `metadata: {size, height, width}`, which is exactly what
      `AttachmentMetadataReader` now produces, so this reads as parity. It may not be: the
      reference maps forty-odd `kMDItem…` keys out of `mdls`, so a camera photo Spotlight has
      indexed could also carry `aperture`, `focalLength`, `deviceMake`, `orientation`. One
      recorded photo settles whether that is a gap. If it is, ImageIO's
      `kCGImagePropertyExifDictionary` is the same data without the subprocess, and worth
      weighing against the fact that the EXIF tail is the part most likely to carry something
      personal out of someone's picture.
- [ ] **Re-record after any Node-side change.** The fixture is a snapshot of a server that is
      still being maintained. Worth a note in the release process.

## The recorder does not stamp which server it recorded

Nothing in a fixture file says whether Node or this server answered, so `RecordedFixture`
infers it from a CORS header, which works only because the two happen to differ, and stops
working the moment `CORSMiddleware` is fixed to match. That inference is what
`CorpusProvenanceTests` rests on, and what found that **fifteen v1 routes have no reference
recording at all**: the group-management writes, `chat/:guid/leave`, the participant routes, the
group icon, the FaceTime session routes, the alias change, `POST /webhook`,
`DELETE /webhook/:id`. Diffing those compares this server against a photograph of itself.

- [ ] Have `Tools/conformance-recorder` write `"recordedFrom": "node" | "swift"` into each file,
      backfill the existing corpus from the header sniff, and switch `RecordedFixture` to read
      the field. Then re-record the fifteen against a Node server.

## The replay harness locked the developer's Mac, and only a deny-list stops it

Its first run issued `POST /api/v1/mac/lock` against a real in-process server, on a machine
being used over a remote session, and went on to restart Messages and kick off a service
restart in the same pass. `FixtureReplay.destructiveRoutes` and `sendingPrefixes` now refuse
them, and `ReplayDenyListTests` asserts it, but the protection lives in the DRIVER, and
anything else that ever replays this corpus has to remember it exists.

- [ ] Move the refusal somewhere a future harness cannot miss: a flag on `RouteDefinition`
      (`isDestructive`) that the route table declares once, that `FixtureReplay` reads instead
      of keeping its own list, and that `bb-parity`'s corpus can read too. Done = deleting
      `destructiveRoutes` from `FixtureReplay` changes nothing about what runs.

## The corpus scrubber destroyed an epoch timestamp it mistook for a phone number

`get_api_v1_message_count_updated-ad9b67-200.json` records the path
`/api/v1/message/count/updated?after=+15555550100`. `after` is epoch **milliseconds**; the
scrubber's phone-number rule matched the digits and replaced them, so the fixture now asks a
question no server can answer: the reference's recorded 200 against a replayed 400. It is in
the replay baseline as an OPEN corpus bug.

- [ ] Narrow the scrubber so it does not rewrite numeric query values whose parameter is a known
      date field, re-record that fixture, and add a scrubber self-test for it
      (`Tools/conformance-recorder/selftest.mjs` is the place).

## The helper's 60-command vocabulary is round-tripped eighteen commands deep

`HelperDispatch` answers 60 actions. Two round-trip suites drive the real dispatch and assert
none of them comes back "unknown action": every FindMy action (6) and every chat-control
action (11), plus `findmy-status` separately. `send-multipart`, `send-reaction`,
`edit-message`, `create-chat`, `update-group-photo`, `modify-active-alias`,
`download-purged-attachment`, the poll and sticker actions and about thirty others appear in
no round trip at all.

The set-equality half of this entry is done, and done better than a test: each dispatch
switches exhaustively over its own action enum, so a command the helper does not implement
does not COMPILE, and `HelperVocabularyTests` covers what the compiler cannot (the two
vocabularies stay disjoint, and the raw values stay in the shape a shipped helper matches on).

- [ ] Extend the round trip to the remaining actions. The IMCore calls behind them cannot run
      in CI, but the half a typo actually breaks — the server's action name and the helper's
      `switch` agreeing — is exactly what runs. Still the highest
      blast-radius-to-effort ratio in this section.

## Input validation: what is left after the sweep

A validation sweep on 13 September 2026 compared every rule in the reference's `validators/`
directory against this server. Six crashes and one v1 break were fixed, five paged routes
that read a negative `limit` as "no limit" were clamped, and a nameless
`DELETE /backup/theme` stopped deleting every theme. `RequestValidation` then landed the
DECLARATIVE half wholesale (31 rule sets over 46 v1 routes, diffed field-for-field against
the reference's own validators), and the BESPOKE half followed: the recurrence rules, the
webhook event allowlist, `contact/query`'s `addresses`, the poll option lists, an
out-of-range `partIndex`, the chat filter's `category`, `?wait=true` on the update install,
and the one-to-one rename. Each carries the reference's own sentence where the reference
refuses the same input.

What is left is one thing, and it is deliberately last:

- [ ] **A v2 parameter-parity test exists; a v2 BEHAVIOUR one does not.**
      `V2ParameterParityTests` asks whether every input `docs/api/openapi.json` promises on a
      v2 route is NAMED in the handler that serves it, which is the check that would have
      caught every "accepted and ignored" defect in this entry. What it cannot ask is whether
      the value is APPLIED — `category` was named and clamped to `>= 0` for months. The v1
      side has the same limit and answers it with per-behaviour suites
      (`MessageCountParityTests`, `MessageFilterSQLTests`); the v2 routes that now validate
      have those, and the rest do not. Worth extending as each v2 route grows a behaviour
      worth pinning, not in one pass.

Two things deliberately NOT done. `?role=` falling back to the preferred image on an unknown
value is documented and intended (`StickerHandlers.swift:181-192`), and the `filePath` body on
the send routes is an authenticated arbitrary-file-send that MATCHES the reference; restricting
it is a product decision, not a validation gap.

## Shipping surface with no test at all

Not plan-claimed, just never written. Each is code a user reaches today.

- [ ] **`NtfyProvider`'s wire shape.** The `matches` filter and the push-not-webhook routing
      are covered now (`NtfySubscriptionTests`, `NotificationSinkTests`), while § Verification
      names ntfy explicitly and the deployment matrix makes webhook/ntfy-only one of the four
      configurations. What has nothing on it is what actually reaches the phone: the
      title/tags/priority mapping, the endpoint join and the bearer header.
- [ ] **`HelperEventDecoder`, everything except FaceTime.** The typing branch (which
      tolerates BOTH `started-typing` and `typing` for the same thing) and `aliases-removed`
      (which tolerates a list or a bare string) are exactly the tolerant branches worth
      pinning, and are the ones with nothing on them. The event names are a compatibility
      contract with a binary we do not build.
- [ ] **Log rotation's shift and its cap.** `tail()` is covered (`LogTailBoundsTests`,
      including the bounds that used to trap) and so is clearing a file with rotations beside
      it (`FileSinkFollowTests`). What nothing exercises is the rotation itself: the
      `.2→.3, .1→.2, current→.1` shift, and the 10 MB cap that triggers it
      (`Logging.swift:207`). A sink written past its cap, twice, is the whole test.
- [ ] **Backups.** `/backup/theme` and `/backup/settings`, four routes storing client blobs:
      no tests, and no fixtures either.
- [ ] **Tailscale, end to end on a real tailnet.** `TailscaleTests` covers the arguments,
      the status parsing and the coordinator's pending state, and `HomebrewBottleTests` the
      registry and install path against a stubbed registry. The install itself HAS been run
      for real: `TailscaleLiveInstallTests` (opt in with `BB_LIVE_TOOL_INSTALL=1`) fetches
      the recommended bottle from `ghcr.io`, checks the download against the digest pinned
      in `BuiltInTools.tailscale`, and runs both `tailscaled --version` and the `tailscale`
      companion; passed on Apple Silicon on 2026-09-08. What has NOT been run is the daemon
      signed in: the browser sign-in through the notification's link, an auth-key sign-in,
      `serve` and `funnel` against a tailnet with and without HTTPS certificates enabled,
      and a Funnel request from a phone with no Tailscale app. Those need a person with a
      tailnet at the Mac, and the Intel leg of the live test needs an Intel Mac.

## A suite that skips itself still reports success

`IMCoreSelectorTests` returns early when `frameworksLoaded` is false. That is deliberate and
explained in the file: the suite is meaningless without the frameworks, but nothing asserts
it ever RAN. On a machine or runner where `dlopen` fails, thirty selector pins go green having
checked nothing. It is also the suite the macOS-version item below is built on, so a silent
skip there would make that whole exercise report a pass.

- [ ] A floor: one test that fails if the frameworks did not load, skipped only where we have
      decided they legitimately cannot be.

## `Query.parse` is in the path of every read and has no test

`MessageInterface.Query.parse` and `ChatInterface.Query.parse` turn a client's request body
into a repository query: `with=` relation expansion, `limit`, `offset`, `sort`. The layer below
is covered hard (`MessageRepositoryTests`) and the layer above is too (`MessageSerializerTests`,
`WireFormatTests`); the translation between them is covered by nothing. A regression here
changes what every client receives while every unit test stays green. Replaying the corpus
(above) covers much of it, which is an argument for doing them together.

- [ ] Table-test both `parse` implementations directly: each relation name, unknown names,
      missing keys, `sort` casing, and the limit/offset defaults.

## Only one `chat.db` query has its plan asserted

§ Verification asks CI to run `EXPLAIN QUERY PLAN` over every `chat.db` query and fail any that
full-scans `message`. `ReadOnlyDatabase.explainQueryPlan` now has one caller: the change
detector's fingerprint query is asserted on both page shapes against the fixture, which carries
Apple's `message_idx_date` for the purpose. Every other repository query is still unasserted.
We cannot add indexes to `chat.db`, so a query that misses the ones Apple ships is a defect,
and it is the kind that only hurts on the old hardware § 10 is written for.

- [ ] Enumerate the rest of the repository's SQL and assert each plan the same way. The
      fixture will need whichever of Apple's indexes each query is meant to use.

## The schema-profile matrix is not exercised

Four `SchemaProfile` constructions across the whole suite, three of them fixtures. § 6 and
§ Verification ask for the full read surface across all three profiles, asserting that columns
absent from a profile produce ABSENT fields rather than nulls, including the case that bites
hardest, a table present in Sonoma and gone in Sequoia (`message_processing_task`).

- [ ] Parameterise the serializer and repository tests over the three profiles.

## `AppDatabase` migrations only ever run on an empty database

Every test goes through `inMemory()`, which runs the whole migrator at once, so the
append-only rule the file insists on is never actually exercised: nothing builds a database at
migration N with rows in it and migrates it forward. The Electron `config.db` migration is well
covered; our own upgrade path is not.

- [ ] Build a database at each released migration with representative rows, migrate forward,
      and assert the rows survive.

## `chat.db` is never written: asserted now, on a representative read

`ChatDatabaseSafetyTests` closed the two halves § Verification asked for, one of them in a
stronger form than the ask. A write through the real `ReadOnlyDatabase` comes back
`SQLITE_READONLY` (8) from SQLite itself for an `UPDATE`, a `CREATE TABLE` and a `DELETE`,
which is a better assertion than the compile-failure test this entry used to want: it survives
someone adding a write API. And a read leaves the database, its `-wal` and its `-shm`
unchanged in size and mtime. Which layer delivers the refusal (`configuration.readonly`
versus GRDB's per-block `query_only`) is deliberately NOT pinned, with the measurement in the
file: both satisfy the rule, and asserting one would fail on a GRDB release that changed the
other.

- [ ] The read it runs is representative — tables, columns, two row fetches, a change token —
      not the full read surface § Verification names (every repository method, every poller
      pass, a complete serialization cycle). Widening it is mechanical.

## Two statuses the reference's `ValidStatuses` does not contain

`PayloadTooLarge` sends 413 and `ServiceUnavailable` sends 503; the reference's union is
`200 | 201 | 400 | 401 | 403 | 404 | 500 | 504`. Both are better descriptions than what Node
sends: a body past the limit is the client's constraint to respect, and "a thing this server
needs is not available" is not "this server is broken", and both are, strictly, statuses no
shipped client has ever been given. `GET /fcm/client` was moved back to the reference's 404
because the corpus caught it; the other call sites were not audited.

- [ ] Enumerate what still answers 413 or 503 on a v1 route and decide each. Neither is visible
      to the replay today: no fixture provokes them.

## Contact ids are UUIDs where the reference gives integers: decided, and kept

Examined and closed on the evidence: the client stringifies whatever it gets
(`nativeContactId: (map['id'] ?? displayName).toString()`), never sends the id back, and its
own comment already expects UUIDs from us; and the reference itself returns bare Contacts
UUIDs for address-book contacts (`identifier ?? id` in `mapContacts`), so no client can assume
an integer from these routes. Changing ours would cost a schema change plus a re-download of
every cached avatar on every client, since the filename derives from this id. The replay
baseline carries the decision as `DECIDED` rather than `OPEN`, which is where it should be
read from; the `macos:` prefix is gone from the wire, and `ContactIndex.contact(id:)` resolves
either spelling so an id from `GET /contact` still round-trips to `PUT`, `DELETE` and
`/contact/:id/avatar`.

- [ ] One thing is still unverified against a reference recording: no fixture contains an
      `api`-source contact, so "the reference sends the bare identifier" is what `mapContacts`
      SAYS rather than something the corpus has seen. Record a contact list from a Node server
      with the address book populated.

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

## `CallHistoryRepositoryTests` works around a `#require` crash

`try #require(try await CallHistoryRepository(path:))` segfaults in `initializeWithCopy` inside
the macro expansion: reproducibly, only in a full parallel run, taking the whole test process
and two hundred unfinished tests with it. Awaiting the value into a local and requiring that
is fine. Every site in the file is written that way with a comment on the first; the pattern
elsewhere in the suite does not crash, and why this struct does was not investigated.

- [ ] On the next toolchain, put one site back to the direct form and run the full suite. If
      it passes, restore the others.

## The concurrent-run guard in `FirebaseSetupModel` has no observable consequence

`start(push:_:)` guards on `runTask == nil` so a second button press cannot begin a concurrent
run. Nothing can currently tell whether it works: `report(rejected:)` assigns the list rather than
appending, so one drop and two concurrent drops both leave exactly one entry, and `activity` ends
`.idle` either way. A test was written for it, passed, and then passed just as happily with the
guard deleted, so it was removed rather than shipped.

- [ ] Give the model something a test can count (a run counter, or make the transcript the
      observable) and then assert the guard. Not urgent: the guard is one line and obviously
      right by reading. What is not acceptable is a test claiming to cover it.

---

# 3. Designed but unbuilt

## Nothing stops the app running translocated

The download is a DMG (the reasons are under "Disk image, not installer package" in
`CONTRIBUTING.md`), so where the app runs from is the user's choice. Launched from the image
or from `~/Downloads` while still quarantined, macOS translocates it: the bundle runs from a
random read-only path that exists for that launch only. Everything the server records about
its own location then points nowhere next time: the login item `SMAppService` registers, the
helper library path the injector hands to Messages, the CLI path a launch daemon names. The
Electron build had the same hole and never guarded it. Nothing in `BlueBubblesApp` checks.

- [ ] At launch, before composition, detect a translocated bundle (`Bundle.main.bundleURL`
      under `/private/var/folders/…/AppTranslocation/`, or on a read-only or removable
      volume) and offer to move the app to `/Applications` and relaunch. Refuse to register
      the login item or write any self-referential path until the bundle is somewhere
      durable. Test the detection against a URL, not a real launch.

## New surface to move to v2

`/api/v1` is the Node server's table and nothing else; everything this server added lives under
`/api/v2`. Three things have nowhere to live yet:

- [ ] **`GET /chat/:guid/typing` has no route.** `checkTypingStatus` is implemented in the
      bridge and wired through the client, so it is dead code from a client's point of view.
      Node has only POST and DELETE on `:guid/typing`, so this belongs in `AdditiveRoutes`,
      alongside `chatPinning`, which is there for the same reason.
- [ ] **Permission state has nowhere to go.** § 17 wants it on `GET /server/info`, and the
      compatibility contract forbids adding a field there. An additive
      `GET /api/v2/server/permissions` is exactly what the split is for. Decide and build it,
      or write down that clients do not need it.
- [ ] **Advertise v2 to clients.** Nothing tells a client which versions this server speaks;
      it has to probe. `server/info` cannot carry it (the field set is frozen) so this is
      itself a v2 route, or a header, or both. Worth deciding before any client adopts v2.

## Socket replay stamps `seq` and can never be asked for it

The ring is maintained, `replay=1` is parsed, and a client that asks gets a `seq` on every
frame. What it cannot do is use it: `since` is parsed nowhere: `SocketClientOptions.parse`
reads `EIO`, `replay`, `transport` and `codecs` only, and `SocketServer.replay(since:)`
**has no caller**. The sequence number is already visible on the wire, so a client author could
reasonably build against a reconnect path that does not exist.

- [ ] Parse `since` at handshake, deliver the ring's tail before the live stream, and answer
      `resync-required` on overflow. Then test it: the only replay assertion today is that
      the opt-in parses.

## Per-device codec negotiation never reaches FCM

§ 4's negotiation table names `POST /api/v1/fcm/device`'s optional `supportedCodecs` /
`publicKey` as how an FCM device declares capability. The handler ignores both, and `PushSink`
resolves `negotiator.resolve(for: .legacy)` unconditionally with a comment saying so. So
`reference-v2` and `sealed-v2` are reachable over the socket and over enrollment and never over
push, which is the target they were designed for, since the whole point is that message
content stops transiting Google.

- [ ] Accept and store the two fields on device registration, and resolve per device in
      `PushSink`. Both codecs are default-off, so this is enabling a switch rather than
      flipping one.

## `new-findmy-location` has a rung-1 path and is still unwired

Established and not acted on. `EventObservation` still records "selectors matching
'location': NONE". Observe `__kIMFMFSessionLocationReceivedNotification` (object: an
`IMFindMyHandle`, userInfo: nil), read the position with `findMyLocationForFindMyHandle:`, and
push it through `FindMyFriendsCache`, whose merge rules already decide what counts as a change
worth emitting. `EventObservation` is where the observer goes: it reaches rung 2 for typing
and swizzles nothing, so this would be its second rung-1 tenant. The server side is ready:
`HelperEventDecoder` and `PrivateAPIGatedService` already forward `findMyLocationUpdated`.

- [ ] Wire it. The open decision is emission policy, not discovery: a position can update every
      few seconds, `CoalescingRateLimiter` exists for exactly this, and nobody has picked an
      interval.
- [ ] **`aliases-removed` deserves the same second look.**
      `__kIMAccountAliasesChangedNotification` IS in IMCore as a string literal. The earlier
      "not exported" finding was the wrong test: the identical false negative that stalled
      FindMy for a release. If it fires on removal as well as addition, the rung-3 swizzle of
      `IMAccount._registrationStatusChanged:` can go.

## Private API: still missing

- [ ] **`deny-nickname`.** Present upstream (`denyHandlesForNicknameSharing:`), absent from
      `BBPrivateAPIContract` entirely. The other two nickname actions are wired; this one was
      missed.

## The client audit that should shape the notification event list

`bluebubbles-app` references **11 of the 31** event types this server emits. The other 20 it
never mentions: not in `action_handler.dart`'s switch, not in the socket listeners, not in the
Android notification path:

    group-icon-changed        group-icon-removed        message-send-error
    server-update             server-update-downloading server-update-installing
    new-server                hello-world
    scheduled-message-{created,updated,deleted,sent,error}
    settings-backup-{created,updated,deleted}
    theme-backup-{created,updated,deleted}

All of them are the reference's events and all reach FCM today, so every one is a wake-up the
official client does nothing with. `message-send-error` is the interesting case: it looks
load-bearing and is not, because the client reads `message.error` off the ordinary
`new-message` / `updated-message` payloads instead.

Deliberately NOT acted on. `FirebaseProvider` and `NtfyProvider` ship with
`EventSubscription.all`, which is exactly today's behaviour, so the split changed no delivery.
Narrowing is a behaviour change for third-party clients too, and that is a judgement about
whose clients to break, not a refactor.

- [ ] Decide which of the 20 to drop from the default push subscription. The machinery is
      there: give the provider `.only([…])`. Worth checking a third-party client or two first
      (the audit above covers the official app only, and webhooks are unaffected either way
      since they route separately).

## Private API: design follow-ups

- [ ] **Consider routing text-only `sendMultipart` through IMCore.** It goes through ChatKit
      today for uniformity. ChatKit is the larger and less stable surface and text does not need
      it; narrowing the ChatKit dependency to attachments only would reduce the blast radius of
      a ChatKit change.
- [ ] **Fill in the event-observation ladder table (§ 15).** The rule is: resolve each inbound
      event to the highest non-swizzle rung that works. Only an exercised probe run on a real
      Mac fills this in, and it has not been run.
- [ ] **Decide whether FindMy DEVICE locations should refresh through IMCore too.** Devices come
      off the FindMy app's disk cache, so they are only as fresh as the last time that app ran:
      `open_findmy_on_startup` exists to paper over it. `IMFMFSession` has `activeDevice` and
      `makeThisDeviceActiveDevice` but no device-location read; that lives in FindMy's own
      frameworks, which Messages does not load. Probably a FindMy-hosted helper rather than
      anything the Messages helper can do: recorded as a conclusion rather than rediscovered.

## Scoped settings are handed out and only half used

`ScopedSettings` is constructed for every service and throws on an undeclared read, every
core read is now DECLARED on its manifest (the audit derived `watchedSettings` from those
declarations), and `ServiceSettingsBridge.validate` runs at startup. But only the connection
methods route their core reads through the scope; the other services still read
`context.settings` directly, so their entitlement lists are accurate documentation rather than
enforced limits.

- [ ] Mechanical to finish, and worth doing before any third-party loading exists so the pattern
      is uniform. The rule that matters: an undeclared read must THROW, not return nil:
      returning nil would recreate the "setting is silently inert" bug this exists to end.
- [ ] Note the honest limit: in-process code can read the database file directly, so the
      boundary is only real for the out-of-process plugins § 12 specifies. For first-party
      services it is a declaration that can be checked, not a sandbox.

## Plugin/service manifests: what is left

The model is enforced: `Service.manifest` is the single source of truth, `id`, `dependencies`
and `watchedSettings` derive from it, forms render, validation runs at startup, the five
connection methods are five services in an exclusive category, and every additive service has
an enable switch the registry honours. What remains:

- [ ] **A conflict found during composition cannot alert.** Validation runs before the alert
      centre exists, so an exclusive-category conflict is logged and not raised. Either move the
      centre earlier or re-validate once it is up (`SettingsPropagation` does not, despite a
      comment in `ServerComposition` that says it does).
- [ ] **`ngrok_protocol` migrates into a field that does not exist.** Deliberate: the value is
      meaningful to an existing install and dropping it silently would lose a choice the user
      made, so it is carried into the namespace and left unread. Either declare the field or
      decide the option is retired.
- [ ] **`.network(hosts:)` is declarative only.** Nothing restricts egress, so it is an honest
      label rather than a control. Real enforcement needs § 12's out-of-process design; until
      then do not describe it to users as a restriction.
- [ ] **No consent flow.** Entitlements are declared and user-facing strings exist
      (`Entitlement.userFacingDescription`, `isSensitive`), but nothing shows them or records a
      grant. Needed before any third-party loading: show the list before enabling, re-prompt
      when an update asks for MORE than was granted, and store the decision.
- [ ] **Uninstall is not implemented**, deliberately: there is nothing to uninstall until
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

- [ ] Only if a concrete consumer appears: a service that must intercept an outgoing message
      before dispatch is the obvious one. Two properties are non-negotiable if it happens: a
      subscriber must not be able to stall the poller, and interception must fail **open** so a
      hook that throws or times out is skipped and the send proceeds.

---

## Tunnel binaries

The four connection methods that wrap someone else's program — ngrok, cloudflared, zrok,
Tailscale — are managed by `BBTooling`: fetched on demand, verified, version-pinned, and, since
the discovery pass, taken from a copy already on the Mac when there is a usable one. Two
descriptor fields carry the version policy and they answer different questions.
`recommended` is the single build we download. `compatible` is the span of builds the code in
`Tunnels.swift`, `TailscaleOptions` and `TailscaleCLI` can actually drive, and it is what
decides whether a pre-existing copy is used. Both are measured against real downloads, never
read off a changelog: a floor fails closed and refuses a copy that works, a ceiling fails open
and adopts one that does not.

What is outstanding:

- [ ] **Port zrok to 2.x, then move its ceiling.** zrok 2 renamed the binary to `zrok2` and
      removed `zrok share reserved`, which `ZrokOptions.arguments` invokes; the recommendation
      is therefore pinned at 1.1.11 and `compatible` stops below 2.0.0, so a 2.x copy already
      on a Mac is found, named and refused. The port replaces `reserve` with
      `create`/`share public -n`. Done looks like: the new command set behind the same
      `ZrokEnvironment` surface, the pin and the ceiling moved together, and
      `BuiltInToolTests.zrokExcludesTheBreakingMajor` rewritten rather than deleted, since its
      job is to make raising that ceiling a deliberate act.
- [ ] **zrok's floor is the oldest version anyone CHECKED, not the oldest that works.** 1.1.11
      is where the subcommands and flags were confirmed present in help output. Lowering it is
      a measurement — fetch older releases, run them — and would let more existing installs be
      used.
- [ ] **cloudflared's floor, 2022.6.1, is the oldest release tested**, not a boundary anyone
      found: every flag this server emits is accepted from there through the current build.
      Nothing is claimed about older releases except that nobody ran them. Worth knowing when
      revisiting: `--protocol` is absent from `tunnel --help` on every build including the one
      we ship, so this has to be measured by trying the flag, with a deliberately invalid flag
      as a control.
- [ ] **ngrok's ceiling is a policy, not a measurement.** `<4.0.0` excludes a major nobody has
      run; there is no ngrok 4. It is the only tool whose source cannot address a version, so
      nothing else stands between an unseen major and a tunnel that will not start.
- [ ] **Keep the pins from going stale.** A stale `recommended` does not break an install — the
      resolver falls back to the current release and says so on the page — but it quietly hands
      users an untested build, which is what the pin exists to prevent. Bumping one means
      re-reading the digests off a real download. Tailscale is at 1.102.3 with 1.102.4
      published.
- [ ] **Nothing has yet adopted a copy on a real machine end to end.** The scan, the range
      checks and the refusals are covered by tests using the shipped descriptors, and a live
      run has only ever been exercised on a Mac with none of the four installed, where the
      correct answer is to find nothing. `brew install cloudflared` and a headless start is the
      check.

# 4. Private API features verified from the sender's side only

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

## Emoji reactions: what the first pass left out

`reaction: emoji` on `/message/react` sends through `IMTapbackSender` (`docs/PRIVATE_API_SURFACE.md`
§ Tapbacks). Verified on 26.5.2 from the sender's side.

- [ ] Nothing has looked at an emoji reaction on a receiving device.
- [ ] The read side reports `associatedMessageType: "2006"` (the reference's numeric
      fallback) plus our `associatedMessageEmoji`. A v2 read could spell the type `emoji`;
      v1 stays as it is.
- [ ] The Flutter client neither renders nor sends emoji reactions.
- [ ] Sticker tapbacks are built (`tapback: true` on the sticker route). Ours carry the
      placed-sticker geometry in `sticker_user_info` where Apple's carry almost none;
      harmless so far, but if one renders oddly on another device that is the difference.

## Stickers: what the first pass left out

`POST /api/v2/message/sticker` (additive, Private API) places a sticker on a message part
through the chain Messages itself runs; `docs/PRIVATE_API_SURFACE.md` § Stickers has the
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
- [ ] **A sticker can be added to recents but not to the saved drawer.** The only write
      `_STKMessagesObjCStoreFacade` exposes is a donation to recents; creating a saved
      sticker is a Stickers-extension UI flow. Worth another look at whether `stickersd` has
      an XPC interface that takes one, since "save this to my stickers" is the thing a user
      would actually ask for. See `docs/STICKER_LIBRARY.md` § 2.
- [ ] **Deleting a sticker is not exposed.** `_STKImageGlyphRecencyObjCFacade` has
      `resetRecentsWithCompletionHandler:`, which clears the WHOLE recents shelf: too blunt
      to put behind a route. There is no per-sticker delete on any facade found so far, so a
      test sticker added through `POST /api/v2/sticker` has to be removed from Messages'
      picker by hand.

## Send Later and polls: what is left

`POST /api/v2/message/send-later` schedules through Apple (`docs/PRIVATE_API_SURFACE.md`
§ Send Later); polls are researched only, in [`docs/POLLS.md`](docs/POLLS.md).

- [ ] **Polls: look at one on a participant's phone.** Created and voted from here and both
      render on this Mac's transcript (options, vote); neither row showed a delivery receipt
      after two minutes. `docs/POLLS.md` § 8 has the remaining differences from Apple's rows.
- [ ] Polls: an existing option's TEXT cannot be edited from here; adding one can
      (`POST /api/v2/message/poll/:guid/option`). Same type-2 re-send, `docs/POLLS.md` § 6.
- [ ] `GET /api/v2/message/send-later` lists rows with `schedule_state` 1 or 2: the two
      pending values observed. The states a DELIVERED scheduled message moves through were
      not observed (the test cancelled it); if one shows up in the list after delivery, that
      is the filter to widen.
- [ ] Send Later is untested for attachments and multipart: only `sendMessage` carries
      `scheduledFor`. The same composition trick should work on `sendMultipart`.
- [ ] `_supportsSendLater` / `_supportsPolls` on IMChat are not consulted. A conversation that
      cannot schedule (SMS) will fail at ChatKit's `canSend` instead of being refused up front.
- [ ] Nothing verifies a scheduled message actually ARRIVES at its time; every test cancelled it.

## Game Pigeon: what is left

`docs/GAME_PIGEON.md` § 7. Reading and sending both work and are measured; the gap is the
other end.

- [ ] **Nobody has opened one of our Game Pigeon messages on an iPhone.** The invite was
      delivered and reads back correctly, but whether the app treats it as a playable game is
      unverified. Needs a phone with Game Pigeon installed.
- [ ] Our archive omits the `ai` app-icon blob that Apple's carry.
- [ ] Some games send attachments alongside the payload; nothing reads those.

---

# 5. UI parity and cleanup

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

## Other app gaps

- [ ] **Alert actions are only reachable from the bell.** The remedy renders where the problem
      is reported, which is the § 17 requirement, but macOS notification banners carry no
      actions, so an alert raised while the app is in the background still needs the user to
      open the app and find it. `UNNotificationAction`s mapping to the same `AlertAction`
      cases would close it.
- [ ] **`GuidesView` reads its state once, on appear.** Everything it shows can change while the
      page is open (a tunnel reconnecting, the helper attaching, contacts finishing an index)
      so a user watching the page sees stale answers. Either poll it the way the Permissions
      page does, or drive it from the same observation the Home page uses.
- [ ] **The dock badge counts unread ALERTS, not messages.** The Electron server badged a
      notification count that meant roughly the same thing, but this is worth a decision rather
      than an assumption.
- [ ] **`start_minimized` miniaturises rather than hiding.** `NSApp.hide` would remove it from
      view entirely, which is not what someone who still wants it in the Dock asked for, but it
      is a judgement call, and a user who wants a truly invisible start probably wants
      `hide_dock_icon` too.

## Settings that are declared, invisible and unread: decide, then delete or build

Each has a `Setting` declaration under `Settings.Legacy` with no `presentation:` AND no
reader. Do not give them a row; decide whether they mean anything. (`tutorial_is_done` is the
exception with a user-visible consequence and is in § 1.)

- [ ] **`encrypt_coms`**: superseded by the `sealed-v2` codec. Delete.
- [ ] **`start_via_terminal`**: an Electron relaunch workaround. Delete.
- [ ] **`disable_gpu`**: Electron-only. Delete.
- [ ] **`private_api_mode`**: the Electron server's choice of injection mechanism. There is
      one here, so the row is carried and never read. Delete.
- [ ] **`headless`**: the SETTING is dead, but `--headless` works: `LaunchOptions` parses it
      into `ServerComposition.Options` directly. Remove the setting or have the launch path read
      it, but not both spellings.
- [ ] **`auto_install_updates`**: the only one of these with somewhere to go. There IS an
      installer path now (`UpdateInstalling`, Sparkle in the app, `POST /server/update/install`),
      and nothing reads this setting, so an update check never installs unattended whatever the
      user asked for. Wire it into the update check, or delete the row and say updates are
      always manual.

## Deliberate relocations, not gaps

The standalone Notifications page (now the toolbar bell); the Permissions and Security pages
(now settings tabs); ngrok/zrok settings pages (now manifest-driven Integrations pages).

---

# 6. Housekeeping

## `@unchecked Sendable` not re-audited, and the helper's statics

Six `nonisolated(unsafe)` statics remain: three in the injected helpers, each written once at
load before any listener exists and saying so, and three in the SERVER, which is the half this
entry used to claim was empty — `SecretStore`'s `entitlementIsMissing` latch (guarded, and
commented) and `MessagesScripts.serviceCache`. 30 `@unchecked Sendable` conformances remain in
`Sources`+`Helper`; the ones touched in the lock pass carry a precise comment, the rest were
not re-read. Done looks like: each `@unchecked` names the invariant that makes it safe, or
becomes an `OSAllocatedUnfairLock`, and the three server statics are re-read on purpose.

## Behaviour still living in the composition root

`BBBuiltIns` took the service declarations out of `BlueBubblesServerCore/Composition`; three
things there are still behaviour rather than wiring: `TLSProvisioning` (certificate lookup and
self-signed generation), the per-vendor option building in `Services/Proxy/*Method.swift`, and
`ServerAddressAnnouncer`. The first two belong beside the modules they drive (`BBSystem` and
`BBProxy`); the announcer is owned by `ServerLifecycle` now and can stay.

## `AppModel` still owns tool-status observation

`toolStatuses` and `toolsTask` stayed on the root model in the split (the observation itself
is `ToolActions.followTools` now); a `ToolsModel` following the `PermissionsModel` pattern is
the obvious next cut, and `ToolActions` is its only consumer.

## `_STKStickerObjCFacade` resolves on no release

A `class` line in `hosts.conf` that is absent on 14.6.1, 15.6.1 and 26.5.2 alike. Surfaced by
the load-failure audit in `docs/SONOMA_COMPATIBILITY.md` §0.

- [ ] Either chase where it went with
      `probe.sh --host "Messages stickers" classes Sticker`, or delete the line.

## Six error types do not conform to `BBError`

`SchemaContributionError`, `AppMessageError`, `TranscriptBackground.Absence`,
`FixtureCoverage.CoverageError`, `OpenAPIDocument.GenerationError` and `TimedOut`. Roughly forty
others do, so the protocol is near-universal and these are the exceptions. All six are internal or
tooling errors that no user path renders, which is why it has not mattered.

- [ ] Conform them, or record here that tooling errors are deliberately exempt. Either is fine; the
      current state does not say which it is.

## Small tasks

- [ ] **A test asserting every setting with a `presentation:` has a READER.** The existing
      `RenderableSettingsTests` catches the adjacent mistake: a presented setting missing from
      `renderable`. It cannot be a grep from inside the test process, but a build-time script
      over `Sources/` wired into CI is the same shape as the coverage check that already exists.
- [ ] **Say what an ad-hoc re-sign does to the Keychain, in `Tools/dev-bundle.sh`'s header.**
      It explains the TCC consequence and not the Keychain one: the login-Keychain ACL on
      `app.bluebubbles.server / password` is granted to a specific code identity, a rebuild
      changes that identity, and the read then fails on an item that is perfectly intact. The
      auth path names the Keychain distinctly now ("The server password could not be read from
      the Keychain", as against "No server password is configured"), so it is no longer silent
      — but the script is where somebody hits it.
- [ ] **Test group 481** ("Renamed By Swift Helper", `any;+;bcb9a1843dfc4b65bb47ce50afec8d32`)
      is left in the user's Messages with the user departed from it. Delete when convenient.
