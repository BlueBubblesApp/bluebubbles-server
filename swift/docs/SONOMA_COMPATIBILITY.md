# Sonoma (macOS 14) compatibility — Private API gap analysis

**Status: §2 and the four ladders in §3 are fixed. The rest is evaluation only.**

Everything in the port's Private API surface was developed against **macOS 26.5.2 (Tahoe)**.
This document answers "what breaks on Sonoma" by cross-referencing every selector and class
the helpers dispatch against `docs/headers/macos-14.6.1/` and `docs/headers/macos-26.5.2/`.

It is the companion to [`SEQUOIA_COMPATIBILITY.md`](SEQUOIA_COMPATIBILITY.md); both feed
[`MACOS_COMPATIBILITY.md`](MACOS_COMPATIBILITY.md), which is the one to read first.

## 0. Why this can be trusted

`macos-14.6.1/` was produced by `Tools/private-api/collect.sh` on a
real macOS 14.6.1 (23G93, arm64) machine, read from the Objective-C **runtime**, out of a
process built for the **same platform as each host app** — `environment.txt` records
`com.apple.MobileSMS … catalyst`, so `IMChat.h` here is the same IMCore the helper is
injected into.

So on this comparison, **"absent" means absent.** The rows below are findings, not
suspicions. The two caveats that remain are narrow and named where they apply:

- **§6 is a dump gap, not a result.** `IMNickname` is not in `hosts.conf`, so it was dumped
  on neither release, and "absent on 14.6.1" there means *never asked*.
- The one absence that could have been a load failure was checked and is not.
  `_MSMessageCustomAcknowledgement` comes from `Messages.framework`, which the helper
  `dlopen`s lazily — a framework that failed to load would report every one of its classes
  absent, which is indistinguishable from a removal. The 14.6.1 dump carries six other
  `Messages.framework` classes (`MSMessage`, `MSSession`, `MSConversation`, and the three
  layouts), so the framework loaded and the absence is real.

No class in either directory was read out of a *different* framework than its counterpart —
checked by comparing every `// Image:` line — so no row below is a case of two dumps
describing two different binaries.

### The load-failure check, in full

`docs/headers/README.md` names the one way this whole exercise can produce a confident wrong
answer: **a framework that fails to `dlopen` reports every one of its classes as
`NOT PRESENT`**, which is indistinguishable from Apple having removed them. It is worth being
explicit that this was checked rather than assumed, because every §2–§5 row rests on it.

A missing *selector* cannot be caused by it — `IMChat` carries 900+ methods in the 14.6.1
dump, so that class plainly loaded. Only whole-class absences are at risk, and there are
thirteen. For each, the test is whether **other** classes from the same framework did dump on
14.6.1:

| Absent on 14.6.1 | Framework | Other classes it dumped on 14.6.1 |
|---|---|---:|
| `CKSendLaterPluginInfo` | ChatKit | 15 |
| `IMChatInfo`, `IMPollHelper`, `IMPollOption`, `IMScheduledSectionDateChatItem` | IMCore | 27 |
| `IMEmojiTapback`, `IMMutedChatList`, `IMStickerTapback` | IMSharedUtilities | 6 |
| `_MSMessageCustomAcknowledgement` | Messages | 6 |
| `_STKImageGlyphRecencyObjCFacade` | Stickers | 12 |
| `FMDSharedConfiguration` | FindMyDevice | 1 |
| `FindMyLocate.FenceServiceDaemonXPC` | FindMyLocate (a **protocol**, so no `// Image:` line) | 14 of 16 in the group |
| `_STKStickerObjCFacade` | — absent on **26.5.2 as well**, so not a Sonoma finding at all | — |

Every framework contributed. Two further checks agree: **no header in either directory is
present-but-empty**, which is what a truncated or partial dump would look like, and the FindMy
classes that *are* present come back with method counts identical to 26.5.2 (`FMFFence` 99,
`FMFSession` 190, `FMFLocation` 111), which a half-loaded framework would not produce.

The positive control is §5's edit ladder: the comparison correctly reports the five-argument
`editMessageItem:…newPartTranslation:backwardCompatabilityText:` absent on 14.6.1 **and** the
four-argument form present, which is the documented macOS 14 spelling. A method that lost an
argument is the hardest case for this kind of comparison, and it is read correctly.

One thing this check did surface: **`_STKStickerObjCFacade` is in `hosts.conf` and exists on
neither release.** Not a Sonoma issue — an entry that has never resolved on anything, which
is worth chasing separately.

## 1. Scoreboard

Every number below is `Tools/private-api/compare-releases.py`, which is checked in so this can
be re-run rather than reconstructed — and which must be used rather than a hand-rolled scan,
for the reason §7 gives.

```bash
./Tools/private-api/compare-releases.py docs/headers/macos-14.6.1 docs/headers/macos-26.5.2
```

| | Count |
|---|---:|
| Classes dumped · selectors indexed | 14.6.1: 137 · 11 831   26.5.2: 140 · 13 956 |
| Classes reported `NOT PRESENT` | 26.5.2: 1 · **14.6.1: 13** |
| Selectors the helpers dispatch | 338 |
| Present on **both** releases | 227 |
| **Present on 26.5.2, absent on Sonoma** | **36** — the regressions |
| Present on Sonoma, absent on 26.5.2 | 4 — three are ladder rungs, one is a live fallback |
| `UNCOMPARABLE` — class dumped on one side only | 3 (the `IMNickname` trio, §6) |
| `UNRESOLVED` — no dumped class on either side declares it | 68 |

The four that go the *other* way are worth naming, because three of them are the system
working as designed: `editMessageItem:…backwardCompatabilityText:` and `leaveiMessageGroup`
are older rungs of ladders that already exist, `_fetchUpdatedStatusForHandle:completion:` is
the Sonoma spelling of a §3 row — and `isIncomingTypingMessage` is a live fallback, ORed with
`isTypingMessage` in `EventObservation.swift` after this same tool caught typing indicators
half-working. That is what a correctly handled divergence looks like.

The 36 regressions land in six groups, and the ordering matters: the first two were bugs in
**our** fallback logic, not in Apple's API surface.

---

## 2. Broken on Sonoma even though a working path exists — the fallback is unreachable

The two most valuable findings. In both, the code already contains the older path; a guard
placed one level too high means Sonoma never reaches it.

### 2.1 Every reaction fails on Sonoma, including the six named ones

`IMCoreBridge.react(_:)` branches on `IMTapbacks.senderAvailable`, which asks only whether
`IMTapbackSender` exists and responds to `initWithTapback:chat:messagePartChatItem:`.

**Both are present on Sonoma.** So `senderAvailable` is `true`, the modern branch is taken —
and then `IMTapbacks.tapback(_:emoji:)` calls `+[IMTapback tapbackWithAssociatedMessageType:]`,
which is **not**:

| | 14.6.1 | 26.5.2 |
|---|---|---|
| `IMTapbackSender` | present | present |
| `-initWithTapback:chat:messagePartChatItem:` | present | present |
| `+tapbackWithAssociatedMessageType:` | **absent** | present |
| `+tapbackWithAssociatedMessageType:messageSummaryInfo:` | present | absent |
| `+tapbackWithAssociatedMessageType:representation:` | present | absent |

Apple did not remove the constructor; it *narrowed* it. Sonoma requires the summary-info or
representation argument that 26 dropped.

The association-initializer fallback below the branch would send all six named tapbacks
correctly on Sonoma, and was never reached.

**FIXED.** `IMTapbacks.canBuild(_:)` now asks, per reaction kind, whether the tapback object
can actually be constructed — `IMEmojiTapback`'s initializer for an emoji, `IMTapback`'s
one-argument constructor for a named one — and `react(_:)` takes the Messages path only when
that *and* `senderAvailable` agree. Sonoma therefore reaches the association fallback and
sends all six named tapbacks.

Asking per kind rather than once was deliberate, and the Sequoia dump has since settled what
it was hedging: **the one-argument constructor arrived in macOS 15**, alongside
`IMEmojiTapback`. So both kinds take the Messages path on 15 and 26, and only 14 falls back.
The question stays asked per kind, because that is what makes the next release's answer a
measurement rather than an assumption.

Still open, and a real improvement rather than a fix: **ladder the constructor** the way
`editMessage` is laddered — `tapbackWithAssociatedMessageType:` → `…:messageSummaryInfo:` →
`…:representation:` — which would keep Sonoma on the modern send path and its better part
ranges. That needs the shape of `messageSummaryInfo:` read off the Sonoma binary first
(`probe.sh`, `trace.sh` on the VM), which is why it is not in this change.

`Helper/BlueBubblesHelper/IMCoreObjects.swift`, `IMCoreBridge.swift:309`.

### 2.2 Mute, unmute and "is muted" all fail on Sonoma

`IMMutedChatList` **does not exist on Sonoma** — the whole class. Every entry point in
`IMMutedChats` opens with `try list()`, which throws `classMissing` before anything else runs.

`mute(_:until:sync:)` and `unmute(_:sync:)` each end with an `IMChat -setMuteUntilDate:` last
resort, described in a comment as the path for a macOS without the list. **It is dead code:**
`try list()` on the first line throws first. `isMuted(_:)` has no fallback at all.

What Sonoma does have — measured, on `IMChat` itself, and present on 26.5.2 too:

| Selector | 14.6.1 | 26.5.2 |
|---|---|---|
| `-isMuted` | present | present |
| `-muteUntilDate` | present | present |
| `-setMuteUntilDate:` | present | present |
| `IMMutedChatList` (whole class) | **absent** | present |

**FIXED.** `list()` returns an optional instead of throwing, and each of `unmuteDate`,
`isMuted`, `mute` and `unmute` is written twice — the list where it exists, the `IMChat`
property where it does not. The list is still preferred wherever present, and not out of
habit: it carries `syncToPairedDevice:`, and it is where Messages itself reads on 26.

The signature change is the actual fix. A `throws` return is what made every caller open with
`try list()`, and that one line is what stranded the fallback: an optional cannot be
dereferenced without handling the nil case, so the compiler now enforces what the comment
used to merely claim.

**Still to verify on the VM**, because it is the reason the list was preferred:
`CHAT_CONTROLS_PLAN.md` §0 measured that on 26 the real store is the
`com.apple.MobileSMS.CKDNDList` defaults domain and that Messages ignores the chat's own
`ignoreAlertsFlag`. **That is a Tahoe measurement.** Whether `setMuteUntilDate:` on Sonoma
writes somewhere Messages consults is what `trace.sh` on the VM answers — the code is right
either way, but "mute reports success and Messages still notifies" would be a bad surprise.

`Helper/BlueBubblesHelper/IMCoreObjects.swift:411`–`545`.

---

## 3. Broken on Sonoma, with an older spelling to ladder onto

Same shape as the three-generation `editMessage` ladder, which is already correct — Sonoma
has generation 2 (`editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:`)
and the ladder finds it. These five need the same treatment.

| Feature | Called | On Sonoma instead | Site |
|---|---|---|---|
| Report junk | `-reportJunk` | `-reportJunkToCarrier` | `IMCoreObjects.swift:237` |
| Report to carrier | `-reportJunkToCarrierViaRelay:` | `-reportJunkToCarrier` | `IMCoreObjects.swift:240` |
| Leave Junk | `-recoverFromJunkTo:` | `-recoverFromJunk` (no argument) | `IMCoreObjects.swift:254` |
| FaceTime dial | `-dialWithRequest:completionWithError:` | `-dialWithRequest:completion:` | `FaceTimeBridge.swift:355` |
| Invalidate link | `-invalidateLink:deleteReason:completionHandler:` | `-invalidateLink:completionHandler:` | `FaceTimeBridge.swift:754` |
| Availability fetch | `-fetchUpdatedStatusForHandle:completion:` | `-_fetchUpdatedStatusForHandle:completion:` | `IMCoreObjects.swift:1337` |

Two need more than a rename:

- **`recoverFromJunkTo:`** already has a guard, and its `else` falls through to
  `updateIsFiltered:`. That moves the chat between filters **without undoing the junk state**,
  which is the whole difference the comment at `IMCoreObjects.swift:250` calls out. On Sonoma
  it silently does half the job. `-recoverFromJunk` is the other half.
- **`dialWithRequest:completion:`** exists on *both* releases; only the `…completionWithError:`
  variant is 26-only. The completion signature differs — the error-carrying block is what 26
  added — so the Sonoma branch needs `callAwaitingCompletion` rather than
  `callAwaitingCompletion2`, and loses the error text, not the call.

### Sending a sticker fails on Sonoma, in two places

Found by `compare-releases.py`, not by the first pass over this data, because both selectors
are built by concatenating string literals across source lines and a literal-by-literal read
sees four fragments rather than one selector. The tool joins them first; anything hand-rolled
should too.

Apple added a keyword to the middle of each:

| | 14.6.1 | 26.5.2 (what the code calls) |
|---|---|---|
| `IMStickers.sticker(path:)` | `initWithStickerID:stickerPackID:fileURL:accessibilityLabel:` **`moodCategory:stickerName:`** | `…accessibilityLabel:` **`accessibilityName:`** `moodCategory:stickerName:` |
| `IMStickers.userInfo(placement:)` | `userInfoDictionaryWithLayoutIntent:…initialFrameIndex:` **`stickerPositionVersion:`** | `…initialFrameIndex:stickerPositionVersion:` **`externalURI:`** |

Neither call has a ladder — each is a single `invoke` of the 26 spelling — so both throw
`selectorMissing` on Sonoma. Sonoma's forms take one fewer argument in each case
(no `accessibilityName`, no `externalURI`), so the ladder is mechanical: drop the argument
with the keyword.

**FIXED.** Both calls now ladder: the newer spelling is tried first and Sonoma's shorter form
second. Every argument the older form drops is one this code passes as `NSNull` or `""`
anyway, so the sticker it builds on Sonoma is the same sticker minus a `suri` key that is
empty on 26 too.

The other three §3 rows — junk reporting, leaving Junk, and the FaceTime dial — are laddered
as well. What remains from this section is the FaceTime link revoke and the availability
refresh, both Sonoma-only and both failing cleanly with `unavailableOnThisOS`.

---

## 4. Degrades quietly, and reports a wrong answer

`IMChat.filterState()` reads six flags through `try?` and defaults each to `false` — a
deliberate choice, and the right one. On Sonoma four of the six are absent, so the defaults
are what a client sees:

| Field | Selector | 14.6.1 |
|---|---|---|
| `isFiltered` | `-isFiltered` | present |
| `filterCategory` | `-filterCategory` | present |
| `isKnownSender` | `-cachedIsKnownSender` | absent → `false` |
| `isInUnknownSendersFilter` | `-inUnknownSendersFilter` | absent → `false` |
| `wasDetectedAsSMSSpam` | `-wasDetectedAsSMSSpam` | absent → `false` |
| `canReportJunk` | `-_messageToReportJunk` | absent → `false` |

Three of those are Screen-Unknown-Senders fields that Sonoma genuinely lacks; `false` is the
honest answer. **`canReportJunk` is not.** Sonoma has `-allMessagesToReportAsSpam` — the same
selector `messagesToReportAsSpamCount()` already uses two methods below — so reporting *is*
possible while the flag says it is not. A client that hides the button on `canReportJunk`
hides a working feature. Fall back to `allMessagesToReportAsSpam` being non-empty.

FaceTime loses two event fields the same way: `TUCall -callerIDBlocked` and
`-conversationGroupUUID` are both 26-only (`FaceTimeBridge.swift:865`, `:877`). Both are
already read through `try?`; the call itself is unaffected.

---

## 5. Genuinely absent features — the existing gates are correct

Each of these is a Messages feature Apple shipped after Sonoma. The dump confirms the gate
rather than contradicting it, which is the outcome worth recording.

| Feature | Gate | Confirmed by |
|---|---|---|
| Polls | `PollInterface.checkPollsSupported` — macOS 26+ | `IMPollHelper`, `IMPollOption`, `_MSMessageCustomAcknowledgement` all absent |
| Emoji reactions | `MessageInterface.checkEmojiReactionSupported` — 15+ | `IMEmojiTapback` absent |
| Send Later | `MessageInterface.swift:953` — 15+ | `CKSendLaterPluginInfo` absent; `cancelScheduledMessageItem:cancelType:`, `editScheduledMessageItem:…`, `setSendLaterPluginInfo:` all absent |
| Sticker tapbacks | `senderAvailable` guard, `IMCoreBridge.swift:392` | `IMStickerTapback` absent |
| Chat backgrounds | none needed — call fails | `-refetchLocalTranscriptBackgroundAssetIfNecessary` absent |
| Screen Unknown Senders | none needed | `-markAsKnownAndSaveInContacts:completion:` absent |

Three corrections this raises:

1. **`MessageInterface.swift:1013` is half wrong.** It reads "Sonoma has neither
   `IMEmojiTapback` nor `IMTapbackSender`". `IMTapbackSender` **is present on Sonoma**, with
   the initializer the code checks for. The gate's *conclusion* is right — Sonoma cannot send
   an emoji reaction — but the stated reason is the thing that made §2.1 invisible.
2. **`macos-versions.md` can promote a row.** Chat backgrounds were listed as
   *"unverified — expected absent on 14 and 15"*. Verified absent on both.
3. **The Send Later gate is now verified at both edges.** Sonoma lacks `CKSendLaterPluginInfo`
   and Sequoia has it, so `>= 15` is exactly right — measured on
   `docs/headers/macos-15.6.1/`, which replaced the borrowed dump that could not answer it.

---

## 6. Not measured — a hole in `hosts.conf`, now half closed

`IMNickname` was not a `class` line in `hosts.conf`, so it was dumped on neither release and
the three selectors the nickname bridge reads came back "absent on Sonoma" when the truth was
**nobody asked**: `-avatar`, `-imageExists`, `-imageFilePath`
(`IMCoreBridge.swift:1493`–`1496`).

`IMNickname`, `IMNicknameAvatar` and `IMNicknameAvatarImage` are now in `hosts.conf`, and
`macos-26.5.2/` carries all three as runtime dumps — replacing the hand-written
`IMNickname.h`, which was the only file in that directory not produced by the tools. The
generated set is a strict superset of it, and it settles the shape the bridge assumes:
`-avatar` is an `IMNickname` property returning an **`IMNicknameAvatarImage`**, and
`imageExists` / `imageFilePath` are that class's, not `IMNickname`'s — matching
`PRIVATE_API_SURFACE.md` §3b.

**Sonoma is still unmeasured, and the VM has since been deleted**, so this now waits on a
macOS 14 machine existing again rather than on a command. `IMNicknameController` *is* dumped
and is present on Sonoma with 87 methods, so nicknames exist there in some form, and all three
call sites are wrapped in `try?` and degrade to a nil avatar path — the exposure is a contact
card without a photo, not an error.

---

## 7. A correction, and why the tool exists

An earlier draft of this document claimed `-markAsSpam:isJunkReportedToCarrier:` existed on
neither release and that the preferred branch of `markAsSpam(count:reportToCarrier:)` was dead
code. **That was wrong.** It is on `IMChat` in both directories, at `macos-14.6.1/IMChat.h:551`
and `macos-26.5.2/IMChat.h:805`. The branch fires, on every supported release.

The mistake is worth keeping in writing, because it is the one anybody re-deriving this by
hand will make. Grepping a header for the SELECTOR does not work — a declaration interleaves
the argument types between the keywords:

```objc
- (unsigned long long)markAsSpam:(unsigned long long)arg0 isJunkReportedToCarrier:(bool)arg1;
```

The string `markAsSpam:isJunkReportedToCarrier:` does not occur in that line. `grep` for it
and every multi-argument selector on the machine reports as missing — silently, and in the
direction that manufactures findings.

`Tools/private-api/compare-releases.py` reconstructs selectors from the declarations instead,
and it is what every number in this document now comes from. Two rows here exist only because
of it: the sticker initializers in §3, whose selectors are built by concatenating literals
across three source lines and which a literal-by-literal scan reads as unrelated fragments.
Re-derive with:

```bash
./Tools/private-api/compare-releases.py docs/headers/macos-14.6.1 docs/headers/macos-26.5.2
./Tools/private-api/compare-releases.py --matrix        # all releases, by category
```

---

## 8. What to do, in order

1. ~~**§2.1 reactions** and **§2.2 mute**~~ — done. Confirming §2.2's store on the VM is
   still outstanding.
2. **§3 FaceTime dial and link invalidation** — a whole feature each.
3. **§3 junk ladder** and **§4 `canReportJunk`** — one file, four small changes.
4. **§6** — `hosts.conf` is done. The Sonoma half waits on a macOS 14 machine; the VM is
   gone. Cosmetic either way.
5. **§5 corrections** — the comment at `MessageInterface.swift:1013` and the
   `macos-versions.md` row.

Nothing here needs a new version gate. Every fix is a selector ladder or an unreachable
fallback, which is what `IMCoreRuntime` was built for: a moved selector should cost one
feature a clear `unavailableOnThisOS`, never a whole helper.
