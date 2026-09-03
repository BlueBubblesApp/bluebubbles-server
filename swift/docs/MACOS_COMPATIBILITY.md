# macOS compatibility

What works on each macOS this server supports, and which private selector decides it.

## TL;DR — what works where

| | 14 Sonoma | 15 Sequoia | 26 Tahoe |
|---|:-:|:-:|:-:|
| Send, reply, edit, unsend, typing indicators | ✅ | ✅ | ✅ |
| Reactions — the six named ones | ✅ | ✅ | ✅ |
| Reactions — any emoji | ⛔️ | ✅ | ✅ |
| Reactions — stickers | ⛔️ | ✅ | ✅ |
| Send a sticker | ✅ | ✅ | ✅ |
| Mute and unmute a conversation | ✅ | ✅ | ✅ |
| Rename, pin, leave, manage a group | ✅ | ✅ | ✅ |
| Mark as spam | ✅ | ✅ | ✅ |
| Report junk to Apple / your carrier | ✅ † | ✅ † | ✅ |
| Schedule a message (Send Later) | ⛔️ | ✅ | ✅ |
| Edit a scheduled message | ⛔️ | ✅ | ✅ |
| Polls | ⛔️ | ⛔️ | ✅ |
| Chat backgrounds | ⛔️ | ⛔️ | ✅ |
| Screen Unknown Senders | ⛔️ | ⛔️ | ✅ |
| Shared contact cards (nicknames) | ✅ † | ✅ | ✅ |
| FaceTime — answer, end, join by link | ✅ | ✅ | ✅ |
| FaceTime — start a call | ✅ | ✅ | ✅ |
| FaceTime — revoke a link you made | ✅ | ✅ | ✅ |
| Find My — locations, friends, devices | ✅ | ✅ | ✅ |

✅ works &nbsp;·&nbsp; ⛔️ **your Mac cannot do this** — Apple added the feature in a later
macOS, and the server refuses it with a message naming the release rather than failing

**There is no third state left.** Everything this server can do on Tahoe, it now does on
Sonoma and Sequoia too, except where the ⛔️ says macOS itself does not have the feature —
and those refusals are deliberate, not crashes. Getting here took twelve selector ladders
(§3b); an earlier version of this table had six ⚠️ rows meaning "your Mac supports this and
we call the wrong selector", and they are all closed.

† On Sonoma the nickname itself works; whether the **avatar photo** resolves is the one thing
no dump has measured (§5). It is read through a `try?` and falls back to no photo, so the
worst case is a contact card without a picture.

† Junk reporting works on 14 and 15 through the older `-reportJunkToCarrier`, which reports
and relays to the carrier in one call. So on those releases "report, but not to my carrier"
cannot be honoured as a choice — the report happens either way. Reporting is the point, so it
is treated as a floor rather than a refusal.

---

**Every release here is now a runtime dump taken on a machine running it.** There is no
borrowed data left in this table and no inference in any cell — which is new, and is why
this document is much shorter than it used to be.

Three layers. **§4 is the one to read** — capabilities against releases. §3 says what needs
a version guard and what needs a selector ladder, which are different fixes. §6 is the
generated detail: every selector the helpers dispatch, one column per release, grouped by
the `hosts.conf` category it belongs to.

| | |
|---|---|
| Per-release gap analysis, Sonoma | [`SONOMA_COMPATIBILITY.md`](SONOMA_COMPATIBILITY.md) |
| Per-release gap analysis, Sequoia | [`SEQUOIA_COMPATIBILITY.md`](SEQUOIA_COMPATIBILITY.md) |
| Where the headers come from | [`headers/README.md`](headers/README.md) |
| What differs between releases, and why | [`private-api/macos-versions.md`](private-api/macos-versions.md) |

## 1. The executable half of this document

`Sources/BBCapabilities` carries the same facts as §3a, as code:
`PrivateAPICapability.all` declares each feature macOS itself gates, with the class or
selector that decides it. Three things read it and nothing repeats it — the version gates
take their number from it, the settings screen enumerates it, and a test re-derives every
minimum from `docs/headers/` and fails if a declaration disagrees with the dumps.

So a new capability is two lines there, and this document's §3a is the prose mirror rather
than a second source. **What is deliberately NOT in that catalog is anything the helper
ladders** — §3b. Those work on every supported release, so listing them as version-dependent
would advertise an upgrade that buys nothing.

## 2. The dumps

| Release | Build | Dumped | Messages.app | Absent classes |
|---|---|---|---|---:|
| **14.6.1** Sonoma | 23G93 | runtime, in a VM | Catalyst | 13 |
| **15.6.1** Sequoia | 24G90 | runtime, in a VM | Catalyst | 6 |
| **26.5.2** Tahoe | 25F84 | runtime, this project's target | Catalyst | 1 |

All three were read from the Objective-C **runtime**, out of a process built for the same
platform as each host app — `environment.txt` in each directory records
`com.apple.MobileSMS … catalyst`, so all three describe the IMCore that Messages actually
runs. Each was checked for the one failure that would invalidate it: a framework that fails
to load reports every one of its classes as absent, which is indistinguishable from a
removal. No framework failed on any of the three, and no header is present-but-empty.

Sequoia's directory replaces a borrowed third-party class-dump of the **native** frameworks,
which could not see ChatKit at all. Roughly two-thirds of the divergences this document used
to list were artefacts of that dump rather than real differences.

### Cell meanings

| | |
|---|---|
| `yes` | the selector is there, on a class that is there |
| **`no`** | the class is present and this selector is not — **fix with a ladder** |
| **`—`** | the class itself is not on this release — **fix with a version guard** |
| `?` | no header for that class in this dump. Not evidence of absence; nobody asked |

The distinction between **`no`** and **`—`** is the whole point, and §2 is built on it.

## 3. What needs a version guard, and what needs a ladder

Two different problems with two different fixes, and picking the wrong one is how a feature
that Apple merely renamed ends up refused on a release that supports it.

### 3a. Genuinely absent — these need a guard, and are what the catalog declares

The class does not exist. No selector will bring the feature back, so the request should be
refused before the helper is asked, with a sentence naming the release.

| Feature | Minimum | Guard today | Measured by |
|---|:-:|---|---|
| Emoji tapbacks | **15** | `checkEmojiReactionSupported` ✓ | `IMEmojiTapback` — absent 14, present 15 |
| Sticker tapbacks | **15** | class guard, names 15 ✓ | `IMStickerTapback` — absent 14, present 15 |
| Send Later | **15** | `MessageInterface.swift:953` ✓ | `CKSendLaterPluginInfo` — absent 14, present 15 |
| Polls | **26** | `checkPollsSupported` ✓ | `IMPollHelper`, `IMPollOption` — absent 14 **and 15** |
| Chat backgrounds | **26** | **none** — the call fails at the helper | `refetchLocalTranscriptBackgroundAssetIfNecessary` |
| Screen Unknown Senders | **26** | **none** — reads default to `false` | `markAsKnownAndSaveInContacts:completion:`, `cachedIsKnownSender` |

Every existing guard is now confirmed against real dumps of both older releases rather than
inferred. The two without one are not urgent — both degrade to a clear failure or a
defensible default — but they are the two places a client cannot tell "unsupported here"
from "broken".

### 3b. Renamed or re-signed — these need a ladder, and all twelve have one

The feature exists on every release; Apple changed the selector. A version guard here would
refuse a working feature, which is why these are laddered rather than gated.

| Feature | 14.6.1 | 15.6.1 | 26.5.2 | Ladder |
|---|---|---|---|:-:|
| Edit a message | `…withNewPartText:backwardCompatabilityText:` | same | `…newPartTranslation:…` | ✓ |
| Leave a group | `leaveiMessageGroup` | `leave` / `leaveConversation` | same | ✓ |
| Typing indicators | `isIncomingTypingMessage` | `isTypingMessage` | same | ✓ |
| Mute state | `-[IMChat setMuteUntilDate:]` | `IMMutedChatList` | same | ✓ |
| Named tapbacks | association initializer | `+tapbackWithAssociatedMessageType:` | same | ✓ |
| Report junk | `reportJunkToCarrier` | `reportJunkToCarrier` | `reportJunk`, `reportJunkToCarrierViaRelay:` | ✓ |
| Recover from Junk | `recoverFromJunk` + `updateIsFiltered:` | same | `recoverFromJunkTo:` | ✓ |
| Outgoing FaceTime call | `dialWithRequest:completion:` | same | `dialWithRequest:completionWithError:` | ✓ |
| Send a sticker | no `accessibilityName:`, no `externalURI:` | current | current | ✓ |
| Invalidate a FaceTime link | `invalidateLink:completionHandler:` | 3-argument | 3-argument | ✓ |
| Availability fetch | `_fetchUpdatedStatusForHandle:completion:` | unprefixed | unprefixed | ✓ |
| Edit a scheduled message | *(no Send Later)* | `…atPartIndex:withNewPartText:` | `…newPartTranslation:` | ✓ |

**All twelve are laddered.** Two of them — junk reporting and outgoing FaceTime calls — were
broken on *both* older releases, which is how the Sequoia dump changed their priority: 14 and
15 share the older spelling and only 26 has the new one, so one ladder fixed two releases each.

Every ✓ above was verified by reading its call site, not by reading the tool. See below for
why that distinction is not pedantic.

### Reading the tool's numbers

`compare-releases.py` reports how many dispatched selectors are **absent on the older
release**, and that number does not move when a ladder is added — a laddered call still names
the 26-only selector, it just asks `responds(to:)` first. So treat that count as a list of
**candidates to check**, never as a count of bugs. This table is the answer to which is which,
and it is maintained by hand because the distinction is a judgement about control flow that
no selector index can see.

That is not a hypothetical failure mode. The availability-fetch row above was written into
this table as missing a ladder, and into `../TODO.md` as work to do, on the strength of the
tool listing it absent on 14.6.1 — which it is. It had been laddered the whole time, at
`IMCoreObjects.swift:1413`. **Read the call site before believing a row here**, which is now
how every ✓ in this table was checked: each modern selector was confirmed to have its older
spelling present in `Helper/` outside a comment.

## 4. Capabilities

| Capability | 14 Sonoma | 15 Sequoia | 26 Tahoe | Decided by |
|---|:-:|:-:|:-:|---|
| Send, reply, edit, unsend | yes | yes | yes | `editMessage` ladders three generations |
| Typing indicators | yes | yes | yes | `isIncomingTypingMessage` ∥ `isTypingMessage` |
| Named tapbacks | via fallback | yes | yes | one-argument `IMTapback` constructor arrived in 15 |
| Emoji tapbacks | **—** | yes | yes | `IMEmojiTapback` |
| Sticker tapbacks | **—** | yes | yes | `IMStickerTapback` |
| Send a sticker | via fallback | yes | yes | `accessibilityName:` and `externalURI:` arrived in 15 |
| Mute / unmute a chat | via fallback | yes | yes | `IMMutedChatList` arrived in 15 |
| Pin conversations | yes | yes | yes | `IMPinnedConversationsController` |
| Leave a group | yes | yes | yes | three-rung ladder |
| Mark as spam | yes | yes | yes | `markAsSpam:isJunkReportedToCarrier:` on all three |
| Report junk | via fallback | via fallback | yes | `reportJunkToCarrier` on 14/15 reports and relays together |
| Recover from Junk | via fallback | via fallback | yes | `recoverFromJunk` then `updateIsFiltered:` — two calls, one on 26 |
| Screen Unknown Senders | **—** | **—** | yes | `markAsKnownAndSaveInContacts:completion:` |
| Send Later | **—** | yes | yes | `CKSendLaterPluginInfo` |
| Edit a scheduled message | **—** | via fallback | yes | `newPartTranslation:` is 26-only |
| Cancel a scheduled message | **—** | yes | yes | `cancelScheduledMessageItem:cancelType:` |
| Polls | **—** | **—** | yes | `IMPollHelper` |
| Chat backgrounds | **—** | **—** | yes | `refetchLocalTranscriptBackgroundAssetIfNecessary` |
| Nicknames | ? | yes | yes | `IMNickname` not yet dumped on 14 — §4 |
| Outgoing FaceTime call | via fallback | via fallback | yes | older block carries no error; the call is unaffected |
| Invalidate a FaceTime link | via fallback | yes | yes | `deleteReason:` arrived in 15 |
| Answer / end a FaceTime call | yes | yes | yes | `TUCallCenter` answer and disconnect paths |
| FaceTime caller-ID / group UUID fields | **—** | **—** | yes | `TUCall` properties, read through `try?` |
| FindMy locations | yes | yes | yes | `FMFSession` and friends, identical on all three |

Everything marked **broken** has an open entry in [`../TODO.md`](../TODO.md). Nothing marked
**—** needs code: those are §3a rows.

## 5. The one hole left, and it is now stuck

`IMNickname`, `IMNicknameAvatar` and `IMNicknameAvatarImage` were added to `hosts.conf`
*after* the Sonoma dump was taken, so they are in the 15.6.1 and 26.5.2 directories and not
in 14.6.1 — the three `?` cells in §5. **The Sonoma VM has since been deleted**, so this
cannot be closed by re-running the dump; it needs a macOS 14 machine to exist again.

How much that costs, precisely:

- **Three selectors, one feature, cosmetic.** `-avatar`, `-imageExists` and `-imageFilePath`,
  all read through `try?` at `IMCoreBridge.swift:1493`–`1496`. If they are absent on Sonoma
  the nickname still resolves and the avatar path comes back nil — a contact card without a
  photo, not an error.
- **`IMNicknameController` is present on Sonoma** with 87 methods, so nicknames exist there;
  it is only the avatar accessors that are unmeasured.
- **Nothing else is affected.** Every other row in this document is measured on all three
  releases, and the remaining Sonoma work in `../TODO.md` is readable off the headers we
  already have — the older spellings are all in `macos-14.6.1/`.

Two smaller things also wanted that VM and no longer have it, both listed in `../TODO.md`:
confirming that `-[IMChat setMuteUntilDate:]` on Sonoma writes where Messages reads, and
reading the shape of `+[IMTapback tapbackWithAssociatedMessageType:messageSummaryInfo:]` to
ladder the reaction path rather than fall back to the association initializer. Neither blocks
a fix; both would have raised confidence in one.

## 6. Every dispatched selector, by category

Generated — do not hand-edit. Categories are `hosts.conf` groups, which is the categorisation
this repository already maintains, so this document cannot drift into a second taxonomy.
Selectors present on every release are collapsed; the ones that differ are the tables.

```bash
./Tools/private-api/compare-releases.py --matrix
```

### Messages chat

49 selectors the helpers dispatch; **21** differ between releases.

| Selector | Class | 14.6.1 | 15.6.1 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `_messageToReportJunk` | `IMChat` | **no** | yes | yes |
| `cachedIsKnownSender` | `IMChat` | **no** | **no** | yes |
| `cancelScheduledMessageItem:cancelType:` | `IMChat` | **no** | yes | yes |
| `editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:` | `IMChat` | yes | yes | **no** |
| `editMessageItem:atPartIndex:withNewPartText:newPartTranslation:backwardCompatabilityText:` | `IMChat` | **no** | **no** | yes |
| `editScheduledMessageItem:atPartIndex:withNewPartText:newPartTranslation:` | `IMChat` | **no** | **no** | yes |
| `editScheduledMessageItem:scheduleType:deliveryTime:` | `IMChat` | **no** | yes | yes |
| `editScheduledMessageItems:scheduleType:deliveryTime:` | `IMChat` | **no** | yes | yes |
| `isMutedChat:` | `IMMutedChatList` | **—** | yes | yes |
| `leaveiMessageGroup` | `IMChat` | yes | **no** | **no** |
| `markAsKnownAndSaveInContacts:completion:` | `IMChat` | **no** | **no** | yes |
| `muteChat:untilDate:` | `IMMutedChatList` | **—** | yes | yes |
| `muteChat:untilDate:syncToPairedDevice:` | `IMMutedChatList` | **—** | yes | yes |
| `muteIdentifiersForChat:` | `IMMutedChatList` | **—** | yes | yes |
| `recoverFromJunkTo:` | `IMChat` | **no** | **no** | yes |
| `refetchLocalTranscriptBackgroundAssetIfNecessary` | `IMChat` | **no** | **no** | yes |
| `reportJunk` | `IMChat` | **no** | **no** | yes |
| `reportJunkToCarrierViaRelay:` | `IMChat` | **no** | **no** | yes |
| `sharedList` | `IMMutedChatList` | **—** | yes | yes |
| `unmuteChatWithMuteIdentifiers:syncToPairedDevice:` | `IMMutedChatList` | **—** | yes | yes |
| `unmuteDateForChat:` | `IMMutedChatList` | **—** | yes | yes |

<details><summary>28 present on every release</summary>

`_setDisplayName:` `_supportsEditMessage` `allMessagesToReportAsSpam` `canLeaveChat` `chatForIMHandles:` `chatIdentifier` `deleteAllHistory` `deleteChatItems:` `deleteIMMessageItems:` `downloadPurgedAttachments` `existingChatWithGUID:` `filterCategory` `guid` `isFiltered` `lastIncomingMessage` `lastSentMessage` `leave` `leaveConversation` `markAsSpam:` `markAsSpam:isJunkReportedToCarrier:` `markChatItemAsNotifyRecipient:` `muteUntilDate` `pinnedConversationIdentifierSet` `sendGroupPhotoUpdate:` `sendMessage:` `setMuteUntilDate:` `setPinnedChats:withUpdateReason:` `updateIsFiltered:`

</details>

### Messages send

67 selectors the helpers dispatch; **4** differ between releases.

| Selector | Class | 14.6.1 | 15.6.1 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `customAcknowledgementMessageWithPayloadData:associatedMessageGUID:balloonBundleID:messageSummaryInfo:threadIdentifier:` | `IMMessage` | **no** | **no** | yes |
| `inUnknownSendersFilter` | `CKConversation/IMChat` | **no** | **no** | yes |
| `isIncomingTypingMessage` | `IMMessage/IMMessageItem` | yes | yes | **no** |
| `setSendLaterPluginInfo:` | `CKComposition` | **no** | yes | yes |

<details><summary>63 present on every release</summary>

`_imMessageItem` `_newChatItems` `_persistentPathForTransfer:filename:highQuality:chatGUID:storeAtExternalPath:` `acceptTransfer:` `addRecipientHandles:` `aggregateAttachmentParts` `audioCompositionWithMediaObject:` `breadcrumbMessageWithText:associatedMessageGUID:balloonBundleID:fileTransferGUIDs:payloadData:threadIdentifier:` `canInsertMoreRecipients` `canSendComposition:error:` `compositionByAppendingMediaObject:` `compositionByAppendingText:` `compositionWithMSMessage:appExtensionIdentifier:` `conversationForExistingChatWithGUID:` `deleteConversation:` `displayName` `editMessageItem:partIndex:withNewComposition:` `guidForNewOutgoingTransferWithLocalURL:` `handles` `initWithConversation:` `initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:` `initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:` `initWithText:subject:` `isCancelTypingMessage` `isFromMe` `isIncoming` `isMuted` `isPending` `isPinned` `isTypingMessage` `loadMessageItemWithGUID:completionBlock:` `loadMessageWithGUID:completionBlock:` `localPath` `markAllMessagesAsRead` `markLastMessageAsUnread` `mediaObjectWithFileURL:filename:transcoderUserInfo:` `mediaObjectWithSticker:stickerUserInfo:` `messageWithComposition:` `messagesFromComposition:` `pinningIdentifier` `registerTransferWithDaemon:` `removeRecipientHandles:` `retargetTransfer:toPath:` `retractMessagePart:` `sendMessage:newComposition:` `setDelegate:` `setDisplayName:` `setExpressiveSendStyleID:` `setLocalURL:` `setLocalUserIsTyping:` `setThreadIdentifier:` `setThreadOriginator:` `sharedConversationList` `sharedInstance` `shelfPluginPayload` `stickerCompositionWithMediaObjects:` `superFormatText:` `text` `title` `transfer` `transferForGUID:` `transferState` `wasDetectedAsSMSSpam`

</details>

### Messages stickers

8 selectors the helpers dispatch; **4** differ between releases.

| Selector | Class | 14.6.1 | 15.6.1 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `initWithStickerID:stickerPackID:fileURL:accessibilityLabel:accessibilityName:moodCategory:stickerName:` | `IMSticker` | **no** | yes | yes |
| `initWithTransferGUID:isRemoved:` | `IMStickerTapback` | **—** | yes | yes |
| `tapbackWithAssociatedMessageType:` | `IMTapback` | **no** | yes | yes |
| `userInfoDictionaryWithLayoutIntent:parentPreviewWidth:xScalar:yScalar:scale:rotation:initialFrameIndex:stickerPositionVersion:externalURI:` | `IMSticker` | **no** | yes | yes |

<details><summary>4 present on every release</summary>

`conversation` `location` `setBallonBundleID:` `transferGUID`

</details>

### Messages tapbacks

7 selectors the helpers dispatch; **1** differ between releases.

| Selector | Class | 14.6.1 | 15.6.1 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `initWithEmoji:isRemoved:` | `IMEmojiTapback` | **—** | yes | yes |

<details><summary>6 present on every release</summary>

`initWithTapback:chat:messagePartChatItem:` `message` `messagePartRange` `send` `threadIdentifier` `threadOriginator`

</details>

### Messages sendlater

3 selectors the helpers dispatch; **2** differ between releases.

| Selector | Class | 14.6.1 | 15.6.1 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `initWithSelectedDate:` | `CKSendLaterPluginInfo` | **—** | yes | yes |
| `optionIdentifier` | `IMPollOption` | **—** | **—** | yes |

<details><summary>1 present on every release</summary>

`version`

</details>

### Messages apps

7 selectors the helpers dispatch; **2** differ between releases.

| Selector | Class | 14.6.1 | 15.6.1 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `_payloadDataFromAppName:adamID:` | `_MSMessageCustomAcknowledgement` | **—** | **—** | yes |
| `initWithSession:isFromMe:time:` | `_MSMessageCustomAcknowledgement` | **—** | **—** | yes |

<details><summary>5 present on every release</summary>

`initWithAlternateLayout:` `initWithSession:` `setCaption:` `setLayout:` `setSummaryText:`

</details>

### Messages stickerstore

3 selectors the helpers dispatch; **0** differ between releases.


<details><summary>3 present on every release</summary>

`donateStickerToRecentsWithIdentifier:representations:stickerEffectEnum:externalURI:name:accessibilityName:metadata:attributionInfo:error:` `initWithAdamID:bundleIdentifier:name:` `initWithData:type:size:role:`

</details>

### Messages accounts

27 selectors the helpers dispatch; **5** differ between releases.

| Selector | Class | 14.6.1 | 15.6.1 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `_fetchUpdatedStatusForHandle:completion:` | `IMHandleAvailabilityManager` | yes | **no** | **no** |
| `avatar` | `IMNickname` | ? | yes | yes |
| `fetchUpdatedStatusForHandle:completion:` | `IMHandleAvailabilityManager` | **no** | yes | yes |
| `imageExists` | `IMNicknameAvatarImage` | ? | yes | yes |
| `imageFilePath` | `IMNicknameAvatarImage` | ? | yes | yes |

<details><summary>22 present on every release</summary>

`activeAccounts` `activeIMessageAccount` `activeSMSAccount` `aliases` `allowHandlesForNicknameSharing:forChat:fromHandle:forceSend:` `allowHandlesForNicknameSharing:fromHandle:forceSend:` `availabilityForHandle:` `currentIDStatusForDestinations:service:listenerID:queue:completionBlock:` `firstName` `forceRefreshIDStatusForDestinations:service:listenerID:queue:completionBlock:` `imHandleWithID:` `isConnected` `lastName` `login` `loginIMHandle` `members` `nickname` `nicknameForHandleIDs:` `personalNickname` `shouldOfferNicknameSharingForChat:` `strippedLogin` `vettedAliases`

</details>

### Messages events

5 selectors the helpers dispatch; **0** differ between releases.


<details><summary>5 present on every release</summary>

`addHandler:` `connected` `listener` `removeHandler:` `sharedController`

</details>

### Messages findmy

27 selectors the helpers dispatch; **0** differ between releases.


<details><summary>27 present on every release</summary>

`activeDevice` `address` `altitude` `cachedFriendsFollowingMyLocation` `coarseAddressLabel` `disableLocationSharing` `findMyHandleIsFollowingMyLocation:` `findMyHandleIsSharingLocationWithMe:` `findMyHandlesSharingLocationWithMe` `findMyLocationForFindMyHandle:` `fmfLocation` `fmlLocation` `fmlSession` `handleWithIdentifier:` `imIsProvisionedForLocationSharing` `initWithIdentifier:` `latitude` `locationTypeDescription` `longitude` `restrictLocationSharing` `sendFriendshipInviteToHandle:isFromGroup:completion:` `session` `startRefreshingLocationForHandles:priority:isFromGroup:reverseGeocode:completion:` `startSharingWithChat:withDuration:` `startSharingWithHandle:inChat:withDuration:` `stopSharingWithChat:` `stopSharingWithHandle:inChat:`

</details>

### FaceTime

45 selectors the helpers dispatch; **4** differ between releases.

| Selector | Class | 14.6.1 | 15.6.1 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `callerIDBlocked` | `TUCall/TUProxyCall` | **no** | **no** | yes |
| `conversationGroupUUID` | `TUCall` | **no** | **no** | yes |
| `dialWithRequest:completionWithError:` | `TUCallCenter` | **no** | **no** | yes |
| `invalidateLink:deleteReason:completionHandler:` | `TUConversationManagerXPCClient` | **no** | yes | yes |

<details><summary>41 present on every release</summary>

`activatedConversationLinks` `activeConversationForCall:` `activeLightweightParticipants` `activeRemoteParticipants` `answerOrJoinCall:` `approvePendingMember:forConversation:` `callStatus` `callUUID` `callWithCallUUID:` `conversationsByGroupUUID` `currentCalls` `dataSource` `dateReceivedLetMeIn` `disconnectCall:` `expirationDate` `fetchInitialStateWithCompletionHandler:` `generateLinkForConversation:completionHandler:` `generateLinkWithInvitedMemberHandles:linkLifetimeScope:completionHandler:` `getActiveLinksWithCreatedOnly:completionHandler:` `groupUUID` `incomingPendingConversationsByGroupUUID` `initWithProvider:` `isLightweightMember` `isSendingVideo` `joinedFromLetMeIn` `lightweightMembers` `linkName` `localMember` `normalizedEmailAddressHandleForValue:` `normalizedGenericHandleForValue:` `normalizedHandleWithDestinationID:` `normalizedPhoneNumberHandleForValue:isoCountryCode:` `pendingMembers` `providerManager` `registerWithCompletionHandler:` `remoteMembers` `setIsSendingVideo:` `setMuted:` `setVideo:` `validityErrors` `value`

</details>

### FindMy

19 selectors the helpers dispatch; **0** differ between releases.


<details><summary>19 present on every release</summary>

`addHandles:` `deviceName` `forceRefresh` `formattedAddressLines` `getHandlesSharingLocationsWithMe` `handle` `horizontalAccuracy` `identifier` `isLocatingInProgress` `isThisDevice` `label` `locationType` `longAddress` `removeHandles:` `setHandle:` `setHandles:` `shortAddress` `streetAddress` `timestamp`

</details>

### Notes

3 selectors the helpers dispatch; **0** differ between releases.


<details><summary>3 present on every release</summary>

`URL` `participants` `setURL:`

</details>
