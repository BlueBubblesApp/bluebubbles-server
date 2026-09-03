# Sequoia (macOS 15) compatibility — Private API gap analysis

**Status: measured on macOS 15.6.1 (24G90, arm64). Nothing here is inferred.**

Everything in the port's Private API surface was developed against **macOS 26.5.2 (Tahoe)**.
This document answers "what breaks on Sequoia" by cross-referencing every selector and class
the helpers dispatch against `docs/headers/macos-15.6.1/` and `docs/headers/macos-26.5.2/`.

Companion to [`SONOMA_COMPATIBILITY.md`](SONOMA_COMPATIBILITY.md); both feed
[`MACOS_COMPATIBILITY.md`](MACOS_COMPATIBILITY.md), which is the one to read first.

## 0. This document was rewritten, and the previous version should not be trusted

An earlier version of this file ran to about 37 KB and hedged nearly every row. It was built
on a **borrowed** class-dump of Sequoia, transcribed from a third-party site: read from the
Mach-O rather than the runtime, and taken from the **native** macOS frameworks rather than the
`/System/iOSSupport` copies Messages.app loads. ChatKit had no native copy at all, so the
entire send path was missing from it — 26 classes that "absent from 15.6" said nothing about.

`macos-15.6.1/` replaces it with a runtime dump from a Sequoia VM, Catalyst-built, 140 classes
— the same coverage as the Tahoe directory. What that changed:

| | borrowed 15.6 | measured 15.6.1 |
|---|---:|---:|
| Classes dumped | 63 | 140 |
| Selectors the comparison could reach | ~6 672 | 12 981 |
| Divergences across all three releases (`--matrix`) | 129 | **43** |
| `UNCOMPARABLE` — class dumped on one side only | many | **0** |

**Roughly two-thirds of the differences the old document reported were artefacts of the
dump.** Every conclusion below is from the new one. The load-failure check that guards these
claims was run on it: all six absent classes belong to frameworks that contributed other
classes to the dump, and no header is present-but-empty.

## 1. Scoreboard

```bash
./Tools/private-api/compare-releases.py docs/headers/macos-15.6.1 docs/headers/macos-26.5.2
```

| | Count |
|---|---:|
| Classes dumped · selectors indexed | 15.6.1: 140 · 12 981   26.5.2: 140 · 13 956 |
| Classes reported `NOT PRESENT` | 26.5.2: 1 · **15.6.1: 6** |
| Selectors the helpers dispatch | 338 |
| Present on **both** | 250 |
| **Present on 26.5.2, absent on Sequoia** | **16** |
| Present on Sequoia, absent on 26.5.2 | 2 — both already handled |
| `UNCOMPARABLE` | **0** |

For scale: Sonoma has 36 regressions and 13 absent classes. **Sequoia is much closer to Tahoe
than to Sonoma**, and the six classes it lacks are all features Apple shipped in 26.

The two that go the other way are the system working: `editMessageItem:…backwardCompatabilityText:`
is an older rung of a ladder that already exists, and `isIncomingTypingMessage` is a live
fallback ORed with `isTypingMessage` in `EventObservation.swift`.

## 2. Absent classes — six, and every one is a macOS 26 feature

| Class | What it is | Guard today |
|---|---|---|
| `IMPollHelper`, `IMPollOption` | Polls | `checkPollsSupported` — macOS 26+ ✓ |
| `_MSMessageCustomAcknowledgement` | poll votes | same gate ✓ |
| `IMChatInfo` | newer than Sequoia; unused by the helpers | — |
| `_STKImageGlyphRecencyObjCFacade` | Genmoji recency | unused on this path |
| `_STKStickerObjCFacade` | **absent on 26.5.2 as well** — a `hosts.conf` line that resolves nowhere | — |

Nothing here needs code. The Polls gate is now confirmed against real dumps of **both** older
releases rather than inferred from one.

What Sequoia **does** have, which the borrowed dump could not show and which settles four
open questions:

| Class | 14.6.1 | 15.6.1 | Consequence |
|---|:-:|:-:|---|
| `IMEmojiTapback` | absent | **present** | the emoji-reaction gate at macOS 15 is exactly right |
| `IMStickerTapback` | absent | **present** | sticker tapbacks work on Sequoia; the guard that said "macOS 26" was wrong and is fixed |
| `IMMutedChatList` | absent | **present** | the mute list path is taken on 15 and 26; only Sonoma falls back |
| `CKSendLaterPluginInfo` | absent | **present** | the Send Later gate at macOS 15 is exactly right |

And one selector, which was the open question in `IMTapbacks.canBuild(_:)`:
**`+[IMTapback tapbackWithAssociatedMessageType:]` arrived in 15.** Sonoma has only the
`…:messageSummaryInfo:` and `…:representation:` forms. So both reaction kinds take the
Messages path on 15 and 26, and only 14 uses the association fallback.

## 3. What actually breaks — four selectors, two features

Of the 16 regressions, ten are the absent-class features above plus Screen Unknown Senders
(`cachedIsKnownSender`, `inUnknownSendersFilter`, `markAsKnownAndSaveInContacts:completion:`),
chat backgrounds (`refetchLocalTranscriptBackgroundAssetIfNecessary`) and two `TUCall` fields
(`callerIDBlocked`, `conversationGroupUUID`) — all genuinely 26-only, all already refused or
read through `try?`. One more, `editMessageItem:…newPartTranslation:…`, is handled by a ladder.

That left four, and they were the same rows Sonoma has. **All four are now laddered:**

| Called | On Sequoia | Status |
|---|---|---|
| `-reportJunk` | `-reportJunkToCarrier` | ✓ laddered; the older call reports and relays together, so `toCarrier` is a floor rather than a choice on 14 and 15 |
| `-reportJunkToCarrierViaRelay:` | folded into the above | ✓ laddered |
| `-recoverFromJunkTo:` | `-recoverFromJunk` **then** `updateIsFiltered:` | ✓ laddered — the older path is two calls, and doing only the second was the bug |
| `-dialWithRequest:completionWithError:` | `-dialWithRequest:completion:` | ✓ laddered; the older block carries no error, which costs the reason clause in a failure message and nothing else |

**This was the finding that changed priority.** Junk reporting and outgoing FaceTime calls
were recorded as Sonoma problems; they were broken on **Sequoia too**, so one ladder each
fixed two of the three releases this server supports.

Plus one Sequoia-only row, which Sonoma cannot have because it has no Send Later at all:

| Called | On Sequoia | Effect |
|---|---|---|
| `-editScheduledMessageItem:atPartIndex:withNewPartText:newPartTranslation:` | `-editScheduledMessageItem:atPartIndex:withNewPartText:` | ✓ laddered; the older form drops the argument this already passes as `NSNull()` |

## 4. What Sequoia settled that Sonoma could not

Sonoma and Tahoe bracket Sequoia, and several things sat in the gap. Now measured:

- **`invalidateLink:deleteReason:completionHandler:` gained its middle argument in 15.** Only
  Sonoma needs that ladder rung.
- **`accessibilityName:` and `externalURI:` on the `IMSticker` calls both arrived in 15.**
  Sending a sticker is broken on Sonoma only; 15 and 26 take the same call.
- **`fetchUpdatedStatusForHandle:completion:` lost its underscore in 15.** Sonoma has
  `_fetchUpdatedStatusForHandle:completion:`; 15 and 26 have the unprefixed form.
- **`cancelScheduledMessageItem:cancelType:` is on 15 and 26.** Cancelling a scheduled message
  works wherever Send Later does.

## 5. What is left

Every selector ladder is done — nothing Sequoia supports is refused any more.

1. [ ] Consider a guard for chat backgrounds and Screen Unknown Senders (§2a of
   [`MACOS_COMPATIBILITY.md`](MACOS_COMPATIBILITY.md)) — the only two 26-only features a
   client cannot distinguish from a bug.
2. [ ] Exercise the ladders on the Sequoia VM. They are verified against the dump and by
   reading every call site, which is not the same as a message actually sending.

No new version gates are needed. Every gate this server already has is confirmed correct
against runtime dumps of all three supported releases.
