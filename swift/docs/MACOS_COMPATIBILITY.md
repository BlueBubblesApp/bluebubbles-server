# macOS compatibility

What works on each macOS this server supports, and which private selector decides it.

Two layers. **§2 is the one to read** — capabilities against releases, short enough to scan.
§4 is the generated detail behind it: every selector the helpers dispatch, one column per
release, grouped by the `hosts.conf` category it belongs to.

| | |
|---|---|
| Per-release gap analysis, Sonoma | [`SONOMA_COMPATIBILITY.md`](SONOMA_COMPATIBILITY.md) — measured |
| Per-release gap analysis, Sequoia | [`SEQUOIA_COMPATIBILITY.md`](SEQUOIA_COMPATIBILITY.md) — inferred, weaker |
| Where the headers come from | [`headers/README.md`](headers/README.md) |
| What differs between releases, and why | [`private-api/macos-versions.md`](private-api/macos-versions.md) |

## 1. The three dumps are not equally trustworthy

This is the first thing to know, because it explains why one whole column below is `?`.

| Release | Dump | Read from | Process | Trust |
|---|---|---|---|---|
| **14.6.1** Sonoma | runtime, in a VM | the Objective-C runtime | Catalyst, matching Messages.app | measured |
| **15.6** Sequoia | **borrowed** class-dump | the Mach-O in the shared cache | none — nothing was executed | inference |
| **26.5.2** Tahoe | runtime, this project's target | the Objective-C runtime | Catalyst, matching Messages.app | measured |

`macos-15.6/` came from a third-party class-dump of the **native** frameworks. Messages.app is
a Catalyst app and loads the `/System/iOSSupport` copies, which are not the same binaries — so
where 15.6 disagrees with its neighbours it may be describing the wrong copy. Worse for the
tables below, **ChatKit has no native copy at all**, so nothing from it could be transcribed:
the entire send path is missing from that column rather than absent from that release.

Sonoma and Tahoe bracket Sequoia. A selector present on **both** 14.6.1 and 26.5.2 is almost
certainly on 15 whatever its column says; that is the safest way to read a `?`.

### Cell meanings

| | |
|---|---|
| `yes` | the selector is there, on a class that is there |
| **`no`** | the class is present on this release and this selector is not — Apple changed the method |
| **`—`** | the class itself is not on this release — Apple removed or had not yet added the feature |
| `?` | no header for that class in this dump. **Not evidence of absence**; nobody asked |

The distinction between **`no`** and **`—`** is not cosmetic: one is fixed by laddering onto
the older spelling, the other by gating the feature or finding a different class entirely.

## 2. Capabilities

What a client can actually do. "via fallback" means the feature works by a different route
than on 26 — usually an older selector — and is not degraded from a user's point of view
unless the note says so.

| Capability | 14 Sonoma | 15 Sequoia | 26 Tahoe | Decided by |
|---|:-:|:-:|:-:|---|
| Send, reply, edit, unsend | yes | yes | yes | `editMessage` ladders three generations |
| Typing indicators | yes | yes | yes | `isIncomingTypingMessage` ∥ `isTypingMessage` |
| Named tapbacks (love, like, …) | via fallback | yes | yes | `+[IMTapback tapbackWithAssociatedMessageType:]` is 26-only, so 14 takes the association path |
| Emoji tapbacks | **—** | yes | yes | `IMEmojiTapback` |
| Sticker tapbacks | **—** | **—** | yes | `IMStickerTapback` |
| **Send a sticker** | **broken** | ? | yes | `initWithStickerID:…accessibilityName:…` — needs a ladder |
| Mute / unmute a chat | via fallback | yes | yes | `IMMutedChatList` is 26-only; 14 uses `-[IMChat setMuteUntilDate:]` |
| Pin conversations | yes | ? | yes | `IMPinnedConversationsController` |
| Leave a group | yes | yes | yes | ladders `leaveConversation` → `leave` → `leaveiMessageGroup` |
| Mark as spam | yes | yes | yes | `markAsSpam:isJunkReportedToCarrier:` on all three |
| **Report junk** | **broken** | **broken** | yes | `reportJunk` is 26-only; 14 has `reportJunkToCarrier` — needs a ladder |
| Recover from Junk | partial | partial | yes | `recoverFromJunkTo:` is 26-only; the fallback moves the filter but leaves junk state |
| Screen Unknown Senders | **—** | **—** | yes | `markAsKnownAndSaveInContacts:completion:`, `cachedIsKnownSender` |
| Send Later | **—** | yes | yes | `CKSendLaterPluginInfo` |
| Polls | **—** | **—** | yes | `IMPollHelper`, `_MSMessageCustomAcknowledgement` |
| Chat backgrounds | **—** | **—** | yes | `refetchLocalTranscriptBackgroundAssetIfNecessary` |
| Nicknames / shared contact cards | ? | ? | yes | `IMNickname` not yet dumped on 14 — see §3 |
| **Outgoing FaceTime call** | **broken** | ? | yes | `dialWithRequest:completionWithError:` is 26-only; 14 has `dialWithRequest:completion:` |
| Invalidate a FaceTime link | **broken** | yes | yes | `invalidateLink:deleteReason:completionHandler:` gained its middle argument in 15, so only 14 needs the ladder |
| Answer / end a FaceTime call | yes | yes | yes | `TUCallCenter` answer and disconnect paths |
| FindMy locations | yes | yes | yes | `FMFSession` and friends, identical method counts on 14 and 26 |

Everything marked **broken** has an open entry in [`../TODO.md`](../TODO.md). Nothing marked
**—** needs code: those are features the release genuinely does not have, and each is refused
by a version gate before the helper is asked.

## 3. Known holes in this table

- **The 15 column is mostly `?` for anything in ChatKit or IMSharedUtilities.** Only a runtime
  dump on a Sequoia machine fixes that. `dump-headers-sonoma.sh` in the VM-shared folder is
  the same procedure — point it at a Sequoia VM.
- **`IMNickname` is not yet dumped on 14.** It is in `hosts.conf` now and present in the 26
  directory; the Sonoma half needs one more VM run.
- **`_STKStickerObjCFacade` resolves on no release**, which means the `hosts.conf` line is
  wrong rather than the class being gone everywhere.

## 4. Every dispatched selector, by category

Generated — do not hand-edit. The categories are `hosts.conf` groups, which is the
categorisation this repository already maintains, so this document cannot drift into a second
taxonomy. Selectors present on every release are collapsed; the ones that differ are the
tables.

```bash
./Tools/private-api/compare-releases.py --matrix
```

### Messages chat

49 selectors the helpers dispatch; **23** differ between releases.

| Selector | Class | 14.6.1 | 15.6 | 26.5.2 |
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
| `pinnedConversationIdentifierSet` | `IMPinnedConversationsController` | yes | ? | yes |
| `recoverFromJunkTo:` | `IMChat` | **no** | **no** | yes |
| `refetchLocalTranscriptBackgroundAssetIfNecessary` | `IMChat` | **no** | **no** | yes |
| `reportJunk` | `IMChat` | **no** | **no** | yes |
| `reportJunkToCarrierViaRelay:` | `IMChat` | **no** | **no** | yes |
| `setPinnedChats:withUpdateReason:` | `IMPinnedConversationsController` | yes | ? | yes |
| `sharedList` | `IMMutedChatList` | **—** | yes | yes |
| `unmuteChatWithMuteIdentifiers:syncToPairedDevice:` | `IMMutedChatList` | **—** | yes | yes |
| `unmuteDateForChat:` | `IMMutedChatList` | **—** | yes | yes |

<details><summary>26 present on every release</summary>

`_setDisplayName:` `_supportsEditMessage` `allMessagesToReportAsSpam` `canLeaveChat` `chatForIMHandles:` `chatIdentifier` `deleteAllHistory` `deleteChatItems:` `deleteIMMessageItems:` `downloadPurgedAttachments` `existingChatWithGUID:` `filterCategory` `guid` `isFiltered` `lastIncomingMessage` `lastSentMessage` `leave` `leaveConversation` `markAsSpam:` `markAsSpam:isJunkReportedToCarrier:` `markChatItemAsNotifyRecipient:` `muteUntilDate` `sendGroupPhotoUpdate:` `sendMessage:` `setMuteUntilDate:` `updateIsFiltered:`

</details>

### Messages send

67 selectors the helpers dispatch; **49** differ between releases.

| Selector | Class | 14.6.1 | 15.6 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `_imMessageItem` | `IMMessage` | yes | ? | yes |
| `_newChatItems` | `IMMessageItem` | yes | ? | yes |
| `_persistentPathForTransfer:filename:highQuality:chatGUID:storeAtExternalPath:` | `IMDPersistentAttachmentController` | yes | ? | yes |
| `acceptTransfer:` | `CKConversation/IMFileTransferCenter` | yes | ? | yes |
| `addRecipientHandles:` | `CKConversation` | yes | ? | yes |
| `aggregateAttachmentParts` | `IMAggregateAttachmentMessagePartChatItem` | yes | ? | yes |
| `audioCompositionWithMediaObject:` | `CKComposition` | yes | ? | yes |
| `breadcrumbMessageWithText:associatedMessageGUID:balloonBundleID:fileTransferGUIDs:payloadData:threadIdentifier:` | `IMMessage` | yes | ? | yes |
| `canInsertMoreRecipients` | `CKConversation` | yes | ? | yes |
| `canSendComposition:error:` | `CKConversation` | yes | ? | yes |
| `compositionByAppendingMediaObject:` | `CKComposition` | yes | ? | yes |
| `compositionByAppendingText:` | `CKComposition` | yes | ? | yes |
| `compositionWithMSMessage:appExtensionIdentifier:` | `CKComposition` | yes | ? | yes |
| `conversationForExistingChatWithGUID:` | `CKConversationList` | yes | ? | yes |
| `customAcknowledgementMessageWithPayloadData:associatedMessageGUID:balloonBundleID:messageSummaryInfo:threadIdentifier:` | `IMMessage` | **no** | ? | yes |
| `deleteConversation:` | `CKConversationList` | yes | ? | yes |
| `editMessageItem:partIndex:withNewComposition:` | `CKConversation` | yes | ? | yes |
| `guidForNewOutgoingTransferWithLocalURL:` | `IMFileTransferCenter` | yes | ? | yes |
| `inUnknownSendersFilter` | `CKConversation/IMChat` | **no** | **no** | yes |
| `initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:` | `IMMessage` | yes | ? | yes |
| `initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:` | `IMMessage` | yes | ? | yes |
| `initWithText:subject:` | `CKComposition` | yes | ? | yes |
| `isCancelTypingMessage` | `IMMessage/IMMessageItem` | yes | ? | yes |
| `isIncomingTypingMessage` | `IMMessage/IMMessageItem` | yes | ? | **no** |
| `isTypingMessage` | `IMMessage/IMMessageItem` | yes | ? | yes |
| `loadMessageItemWithGUID:completionBlock:` | `IMChatHistoryController` | yes | ? | yes |
| `loadMessageWithGUID:completionBlock:` | `IMChatHistoryController` | yes | ? | yes |
| `localPath` | `IMFileTransfer` | yes | ? | yes |
| `mediaObjectWithFileURL:filename:transcoderUserInfo:` | `CKMediaObjectManager` | yes | ? | yes |
| `mediaObjectWithSticker:stickerUserInfo:` | `CKMediaObjectManager` | yes | ? | yes |
| `messageWithComposition:` | `CKConversation` | yes | ? | yes |
| `messagesFromComposition:` | `CKConversation` | yes | ? | yes |
| `registerTransferWithDaemon:` | `IMFileTransferCenter` | yes | ? | yes |
| `removeRecipientHandles:` | `CKConversation` | yes | ? | yes |
| `retargetTransfer:toPath:` | `IMFileTransferCenter` | yes | ? | yes |
| `sendMessage:newComposition:` | `CKConversation` | yes | ? | yes |
| `setExpressiveSendStyleID:` | `CKComposition/IMMessage/IMMessageItem` | yes | ? | yes |
| `setLocalURL:` | `IMFileTransfer` | yes | ? | yes |
| `setSendLaterPluginInfo:` | `CKComposition` | **no** | ? | yes |
| `setThreadIdentifier:` | `IMMessage/IMMessageItem` | yes | ? | yes |
| `setThreadOriginator:` | `IMMessage/IMMessageItem` | yes | ? | yes |
| `sharedConversationList` | `CKConversationList` | yes | ? | yes |
| `shelfPluginPayload` | `CKComposition` | yes | ? | yes |
| `stickerCompositionWithMediaObjects:` | `CKComposition` | yes | ? | yes |
| `superFormatText:` | `CKComposition` | yes | ? | yes |
| `text` | `CKComposition/IMMessage/IMMessagePartChatItem/IMPluginPayload` | yes | ? | yes |
| `transfer` | `CKMediaObject` | yes | ? | yes |
| `transferForGUID:` | `IMFileTransferCenter` | yes | ? | yes |
| `transferState` | `IMFileTransfer` | yes | ? | yes |

<details><summary>18 present on every release</summary>

`displayName` `handles` `initWithConversation:` `isFromMe` `isIncoming` `isMuted` `isPending` `isPinned` `markAllMessagesAsRead` `markLastMessageAsUnread` `pinningIdentifier` `retractMessagePart:` `setDelegate:` `setDisplayName:` `setLocalUserIsTyping:` `sharedInstance` `title` `wasDetectedAsSMSSpam`

</details>

### Messages stickers

8 selectors the helpers dispatch; **6** differ between releases.

| Selector | Class | 14.6.1 | 15.6 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `initWithStickerID:stickerPackID:fileURL:accessibilityLabel:accessibilityName:moodCategory:stickerName:` | `IMSticker` | **no** | ? | yes |
| `initWithTransferGUID:isRemoved:` | `IMStickerTapback` | **—** | ? | yes |
| `setBallonBundleID:` | `IMSticker` | yes | ? | yes |
| `tapbackWithAssociatedMessageType:` | `IMTapback` | **no** | ? | yes |
| `transferGUID` | `CKAssociatedStickerChatItem/CKMediaObject/IMAssociatedStickerChatItem` | yes | ? | yes |
| `userInfoDictionaryWithLayoutIntent:parentPreviewWidth:xScalar:yScalar:scale:rotation:initialFrameIndex:stickerPositionVersion:externalURI:` | `IMSticker` | **no** | ? | yes |

<details><summary>2 present on every release</summary>

`conversation` `location`

</details>

### Messages tapbacks

7 selectors the helpers dispatch; **6** differ between releases.

| Selector | Class | 14.6.1 | 15.6 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `initWithEmoji:isRemoved:` | `IMEmojiTapback` | **—** | ? | yes |
| `initWithTapback:chat:messagePartChatItem:` | `IMTapbackSender` | yes | ? | yes |
| `messagePartRange` | `CKMessagePartChatItem/IMMessagePartChatItem/IMTapbackSender` | yes | ? | yes |
| `send` | `IMTapbackSender` | yes | ? | yes |
| `threadIdentifier` | `CKMessagePartChatItem/IMMessage/IMMessageItem/IMMessagePartChatItem/IMPluginPayload/IMTapbackSender` | yes | ? | yes |
| `threadOriginator` | `CKMessagePartChatItem/IMMessage/IMMessageItem/IMMessagePartChatItem` | yes | ? | yes |

<details><summary>1 present on every release</summary>

`message`

</details>

### Messages sendlater

3 selectors the helpers dispatch; **2** differ between releases.

| Selector | Class | 14.6.1 | 15.6 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `initWithSelectedDate:` | `CKSendLaterPluginInfo` | **—** | ? | yes |
| `optionIdentifier` | `IMPollOption` | **—** | ? | yes |

<details><summary>1 present on every release</summary>

`version`

</details>

### Messages apps

7 selectors the helpers dispatch; **7** differ between releases.

| Selector | Class | 14.6.1 | 15.6 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `_payloadDataFromAppName:adamID:` | `_MSMessageCustomAcknowledgement` | **—** | ? | yes |
| `initWithAlternateLayout:` | `MSMessageLiveLayout` | yes | ? | yes |
| `initWithSession:` | `MSMessage` | yes | ? | yes |
| `initWithSession:isFromMe:time:` | `_MSMessageCustomAcknowledgement` | **—** | ? | yes |
| `setCaption:` | `MSMessageTemplateLayout` | yes | ? | yes |
| `setLayout:` | `MSMessage` | yes | ? | yes |
| `setSummaryText:` | `MSMessage` | yes | ? | yes |

### Messages stickerstore

3 selectors the helpers dispatch; **3** differ between releases.

| Selector | Class | 14.6.1 | 15.6 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `donateStickerToRecentsWithIdentifier:representations:stickerEffectEnum:externalURI:name:accessibilityName:metadata:attributionInfo:error:` | `_STKMessagesObjCStoreFacade` | yes | ? | yes |
| `initWithAdamID:bundleIdentifier:name:` | `_STKStickerAttributionInfo` | yes | ? | yes |
| `initWithData:type:size:role:` | `_STKStickerUIStickerRepresentation` | yes | ? | yes |

### Messages accounts

27 selectors the helpers dispatch; **25** differ between releases.

| Selector | Class | 14.6.1 | 15.6 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `_fetchUpdatedStatusForHandle:completion:` | `IMHandleAvailabilityManager` | yes | ? | **no** |
| `activeAccounts` | `IMAccountController` | yes | ? | yes |
| `activeIMessageAccount` | `IMAccountController` | yes | ? | yes |
| `activeSMSAccount` | `IMAccountController` | yes | ? | yes |
| `aliases` | `IMAccount` | yes | ? | yes |
| `allowHandlesForNicknameSharing:forChat:fromHandle:forceSend:` | `IMNicknameController` | yes | ? | yes |
| `allowHandlesForNicknameSharing:fromHandle:forceSend:` | `IMNicknameController` | yes | ? | yes |
| `availabilityForHandle:` | `IMHandleAvailabilityManager` | yes | ? | yes |
| `avatar` | `IMNickname` | ? | ? | yes |
| `currentIDStatusForDestinations:service:listenerID:queue:completionBlock:` | `IDSIDQueryController` | yes | ? | yes |
| `fetchUpdatedStatusForHandle:completion:` | `IMHandleAvailabilityManager` | **no** | ? | yes |
| `firstName` | `IMHandle` | yes | ? | yes |
| `forceRefreshIDStatusForDestinations:service:listenerID:queue:completionBlock:` | `IDSIDQueryController` | yes | ? | yes |
| `imHandleWithID:` | `IMAccount` | yes | ? | yes |
| `imageExists` | `IMNicknameAvatarImage` | ? | ? | yes |
| `imageFilePath` | `IMNicknameAvatarImage` | ? | ? | yes |
| `lastName` | `IMHandle` | yes | ? | yes |
| `login` | `IMAccount` | yes | ? | yes |
| `loginIMHandle` | `IMAccount` | yes | ? | yes |
| `members` | `IMAccount` | yes | ? | yes |
| `nicknameForHandleIDs:` | `IMNicknameController` | yes | ? | yes |
| `personalNickname` | `IMNicknameController` | yes | ? | yes |
| `shouldOfferNicknameSharingForChat:` | `IMNicknameController` | yes | ? | yes |
| `strippedLogin` | `IMAccount` | yes | ? | yes |
| `vettedAliases` | `IMAccount` | yes | ? | yes |

<details><summary>2 present on every release</summary>

`isConnected` `nickname`

</details>

### Messages events

5 selectors the helpers dispatch; **4** differ between releases.

| Selector | Class | 14.6.1 | 15.6 | 26.5.2 |
|---|---|:-:|:-:|:-:|
| `addHandler:` | `IMDaemonListener/_IMLegacyDaemonListener` | yes | ? | yes |
| `listener` | `IMDaemonController` | yes | ? | yes |
| `removeHandler:` | `IMDaemonListener/_IMLegacyDaemonListener` | yes | ? | yes |
| `sharedController` | `IMDaemonController` | yes | ? | yes |

<details><summary>1 present on every release</summary>

`connected`

</details>

### Messages findmy

27 selectors the helpers dispatch; **0** differ between releases.


<details><summary>27 present on every release</summary>

`activeDevice` `address` `altitude` `cachedFriendsFollowingMyLocation` `coarseAddressLabel` `disableLocationSharing` `findMyHandleIsFollowingMyLocation:` `findMyHandleIsSharingLocationWithMe:` `findMyHandlesSharingLocationWithMe` `findMyLocationForFindMyHandle:` `fmfLocation` `fmlLocation` `fmlSession` `handleWithIdentifier:` `imIsProvisionedForLocationSharing` `initWithIdentifier:` `latitude` `locationTypeDescription` `longitude` `restrictLocationSharing` `sendFriendshipInviteToHandle:isFromGroup:completion:` `session` `startRefreshingLocationForHandles:priority:isFromGroup:reverseGeocode:completion:` `startSharingWithChat:withDuration:` `startSharingWithHandle:inChat:withDuration:` `stopSharingWithChat:` `stopSharingWithHandle:inChat:`

</details>

### FaceTime

45 selectors the helpers dispatch; **4** differ between releases.

| Selector | Class | 14.6.1 | 15.6 | 26.5.2 |
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
