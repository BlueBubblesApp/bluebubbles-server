# Private framework headers

Headers for the private classes this port calls, one directory per macOS release. Every
directory but one is read from the Objective-C **runtime** on a machine running that release;
`macos-15.6/` is borrowed, and says so on every file — see below.

Regenerate with:

```bash
Tools/private-api/dump-headers.sh
```

The tools, and the guide to send someone collecting a dump from a macOS release nobody here
runs, are documented in [`../private-api/`](../private-api/).

It writes `docs/headers/macos-<version>/`, named after `sw_vers -productVersion`. Run it on
each macOS we support and commit the result — the diff between two directories is the answer
to "what did Apple move this time", which is the question that costs the most time when a
Private API feature stops working.

## What is here

| Directory | Release | How it was produced |
|---|---|---|
| `macos-14.6.1/` | Sonoma, build 23G93, arm64 | runtime dump, in a VM |
| `macos-15.6/` | Sequoia, build 24G84, arm64e | **borrowed** third-party class-dump — see below |
| `macos-26.5.2/` | Tahoe, build 25F84, arm64 | runtime dump, the release this project develops against |

Each carries an `environment.txt` recording the machine, the toolchain, whether each host app
was Catalyst or native, and the classes that release does not have. Read it first: the
`app … catalyst` lines are what decide which copy of a shared framework the dump describes.
`macos-15.6/environment.txt` is the exception and says so on its first line — nothing was
executed to produce that directory.

The Sonoma dump is analysed against the helper code in
[`../SONOMA_COMPATIBILITY.md`](../SONOMA_COMPATIBILITY.md), which is the more reliable of the
two compatibility documents for exactly the reason the next section gives.

## macOS 15.6 is a borrowed dump

`macos-26.5.2/` is a runtime dump. `macos-15.6/` is **not**, and must not be read as one. Its
63 files were transcribed from a third-party class-dump published at
[developer.limneos.net](https://developer.limneos.net/index.php?ios=macos_15.6)
(classdump-dyld 3.0, arm64e Macmini9,1, build 24G84). Two differences change how they read:

- **Read from the Mach-O in the dyld shared cache, not from the runtime.** So the caveat at
  the top of the next section applies in reverse here: this describes what is *in the binary*,
  which is not always what the runtime will dispatch. Categories loaded at runtime by another
  framework do not appear.
- **The native macOS framework, not the Catalyst copy.** `hosts.conf` dumps the Messages
  groups out of `com.apple.MobileSMS`, which is Catalyst, so `macos-26.5.2/IMChat.h` records
  `/System/iOSSupport/System/Library/…/IMCore`. The 15.6 files record
  `/System/Library/PrivateFrameworks/…/IMCore` instead. The two copies are not guaranteed
  identical, and where they differ this directory is describing the wrong one.

So it is evidence about Sequoia, not ground truth. `dump-headers.sh` run on a Sequoia machine
overwrites the directory in place and supersedes it. Until then, confirm anything load-bearing
with `Tools/private-api/probe.sh` on that release before shipping a behaviour change that
depends on it.

limneos publishes no macOS 14 dump, so Sonoma could only ever be covered by running
`dump-headers.sh` on it. **That has now been done** — `macos-14.6.1/` is a runtime dump out of
a Catalyst process on real hardware, and it carries none of the doubt this section describes.
Where the two disagree about Sequoia, 14.6.1 plus 26.5.2 bracket it and 15.6 does not settle
it.

### What the 15.6 diff shows

**The two directories no longer line up file-for-file.** `macos-26.5.2/` carries 89 headers;
`macos-15.6/` carries the original 63. The extra twenty-six are classes the helpers message
that `hosts.conf` never dumped — fifteen found by
[`SEQUOIA_COMPATIBILITY.md`](../SEQUOIA_COMPATIBILITY.md) §3, eleven more by §5.4, which are
reached only as return values and so never appear as a class name in `Helper/` at all. None
has a 15.6 counterpart, because limneos is the only source for that release and it was
scraped before the list grew.

`Tools/private-api/limneos-scrape.js` collects the twenty of them that limneos can supply.
**The six ChatKit classes are not among them and cannot be**: ChatKit has no native macOS
copy — it exists only under `/System/iOSSupport` — so it is not in the native dyld shared
cache limneos publishes, and `ChatKit.framework` is absent from the 15.6 index. That is the
whole send path, and only `dump-headers.sh` on a Sequoia machine will cover it.

So for these classes, "absent from `macos-15.6/`" means *not dumped*, never *not present*.
Do not read the missing file as evidence. They are:

`CKChatController` `CKComposition` `CKConversationList` `CKMediaObjectManager`
`CKConversation` `CKMediaObject` `IMMessage` `IMMessageItem` `IMChatHistoryController`
`IMFileTransferCenter` `IMFileTransfer` `IMDPersistentAttachmentController`
`IMAggregateAttachmentMessagePartChatItem` `IMAccountController` `IMAccount` `IMHandle`
`IMNicknameController` `IMHandleAvailabilityManager` `IDSIDQueryController`
`IMPinnedConversationsController` `IMDaemonController` `IMDaemonListener`
`_IMLegacyDaemonListener` `IMDaemonProtocol` `IMDaemonListenerProtocol` `IMDaemonAnyProtocol`

The comparison below concerns the 63 names both directories share. Four are `NOT PRESENT` on
15.6:

| Missing on 15.6 | Notes |
|---|---|
| `IMChatInfo` | Not in IMCore, and not anywhere else in the 15.6 index. Newer than Sequoia. |
| `FindMyLocate.FenceServiceDaemonXPC` | 15.6 has `FindMyLocate.FenceServiceClientXPC` — the client half, not the daemon half. |
| `FindMyLocate.FriendshipServiceClientXPC` | 15.6 exposes only the mangled Swift `_TtCC12FindMyLocate7Session20FriendshipConnection`. |
| `FindMyLocate.LocationServiceClientXPC` | 15.6 exposes only the mangled Swift `_TtCC12FindMyLocate7Session18LocationConnection`. |

`ChatKit.framework` is also absent from the 15.6 index. Harmless — `hosts.conf` only `load`s
it and dumps nothing out of it.

Selector counts:

| Class | 26.5.2 | 15.6 | Gone on Sequoia |
|---|---:|---:|---|
| `IMFMFSession` | 78 | 78 | *nothing* |
| `FindMyLocateSession` | 31 | 28 | the three `*UpdateCallback` properties |
| `IMChat` | 915 | 760 | incl. the `__ck_*` watermark/read-receipt family |
| `TUCallCenter` | 230 | 211 | incl. `performTranslationRequest`, `performSmartHoldingRequest` |
| `TUConversation` | 187 | 175 | incl. `isNearbySession`, `localParticipantCluster` |
| `TUConversationManager` | 152 | 142 | incl. `approveExternalParticipants`, `activeAdvertisements` |

### Selectors this port calls that Sequoia does not have

Of the selector literals in `Helper/` and `Sources/BBPrivateAPI/`, four are present on 26.5.2
and absent on 15.6, all on `IMChat`:

| Called as | On 15.6 | Call site |
|---|---|---|
| `reportJunkToCarrierViaRelay:` | `reportJunkToCarrier` (no argument) | [`IMCoreObjects.swift:211`](../../Helper/BlueBubblesHelper/IMCoreObjects.swift) |
| `recoverFromJunkTo:` | `recoverFromJunk` (no argument) | [`IMCoreObjects.swift:223`](../../Helper/BlueBubblesHelper/IMCoreObjects.swift) |
| `markAsKnownAndSaveInContacts:completion:` | **absent entirely** | [`IMCoreBridge.swift:1441`](../../Helper/BlueBubblesHelper/IMCoreBridge.swift) |
| `setTranscriptBackgroundAndSendToChat:…` | **absent entirely** (both arities) | [`IMCoreBridge.swift:897`](../../Helper/BlueBubblesHelper/IMCoreBridge.swift), [`:1006`](../../Helper/BlueBubblesHelper/IMCoreBridge.swift) |

The two junk selectors are `responds(to:)`-guarded, so they do not crash on Sequoia — but they
fall back *silently* and not to an equivalent: the carrier report is skipped outright, and
recovery falls through to `updateIsFiltered:`, which moves the chat between filters without
undoing the junk state. The no-argument Sequoia spellings exist and are not tried.

The other two are unguarded, and `IMCoreRuntime.invoke` throws on a selector the target does
not implement, so chat backgrounds and accept-unknown-sender raise on 15.6 rather than
degrading. Neither has a 15.6 spelling under any arity, so there is nothing to fall back to;
the handling for those is to detect the release and report unsupported.

**`IMFMFSession` is selector-identical across the two releases**, including
`_dateFromShareDuration:` and `_initializeFindMySessionIfInAllowedProcess`, both documented
below off the 26.5.2 disassembly. That surface needs no version fork.

## Why these are read from the runtime

The FindMy headers this project previously worked from live in the Objective-C helper repo
(`bluebubbles-helper/Messages/MacOS-11+/BlueBubblesHelper/FM*.h`) and are `ktool` dumps of an
**iOS 16** SDK. They had drifted far enough to be actively misleading:

- They describe `FMFSessionDataManager`, `FMFSession`, `FMFHandle` and `FMFLocation`. On
  macOS 26.5.2 **none of those classes exist**.
- They omit `IMFindMyHandle`, `IMFindMyLocation` and `IMFindMyDevice`, which do exist and are
  the types IMCore actually hands out today.

Reading a header that disagrees with the running system is worse than having no header,
because it gets treated as authoritative. That is exactly what happened here: a probe looked
for `FMFSessionDataManager`, did not find it, and concluded FindMy was unreachable from inside
Messages.app. It is not — see below.

`class_copyMethodList` reports what the runtime will actually dispatch, so there is no fidelity
lost against parsing a binary, and the tool runs anywhere without extracting the dyld shared
cache.

## What is reachable from inside Messages.app

`IMFMFSession` is an **IMCore** class, so it is already in Messages.app's address space —
nothing has to be loaded for it. Verified on macOS 26.5.2:

```
PRESENT  IMFMFSession        /System/Library/PrivateFrameworks/IMCore.framework/…/IMCore
PRESENT  IMFindMyHandle      …/IMCore
PRESENT  IMFindMyLocation    …/IMCore
PRESENT  IMFindMyDevice      …/IMCore
```

`FindMyLocateSession`, `FMLHandle`, `FMLLocation`, `FMLFriend`, `FMLDevice` and `FMLPlaceMark`
live in `FindMyLocateObjCWrapper.framework`, which is **not** loaded at process start —
`IMFMFSession` dlopens it itself through `__FMLSessionClass`. That is why a naive
`NSClassFromString("FindMyLocateSession")` at launch reports the class as missing.

`-[IMFMFSession _initializeFindMySessionIfInAllowedProcess]` gates on
`IMIsRunningInImagent() || IMIsRunningInMessagesUIProcess()`. Messages.app satisfies the
second, so an injected helper gets a live session.

### There is no OS-version fork any more

The shipping Objective-C helper branches on `operatingSystemVersion.majorVersion > 13` to
choose between `FindMyLocateSession` and the legacy `FMFSession`. **Do not carry that
forward.** IMCore now makes the same choice itself, off an internal feature flag —
`-[IMFMFSession findMyHandlesSharingLocationWithMe]` reads `isFindMyLocateSessionEnabled` and
dispatches to `cachedFriendsSharingLocationsWithMe` or `getHandlesSharingLocationsWithMe`
accordingly, returning `IMFindMyHandle` either way.

Prefer the `IMFMFSession` wrapper API for anything it covers: it absorbs the fork, and it is
the layer Messages itself calls.

## Notifications (rung 1)

IMCore posts these on `NSNotificationCenter.default`. They are plain string literals in
IMCore's `__cstring`, **not exported symbols** — a `dlsym` lookup for them fails, which is a
false negative that has misled this port before. Observe them by name.

| Name | Posted from | `object` | `userInfo` |
|---|---|---|---|
| `__kIMFMFSessionLocationReceivedNotification` | `didReceiveLocationForHandle:` | `IMFindMyHandle` | nil |
| `__kIMFMFSessionHandleLocationRefreshedNotification` | `refreshLocationForHandle:inChat:` | handle | nil |
| `__kIMFMFSessionChatLocationRefreshedNotification` | `refreshLocationForChat:` | chat | nil |
| `__kIMFMFSessionRelationshipStatusDidChangeNotification` | start/stop sharing, start/stop ability-to-locate, friendship added/removed | `IMFindMyHandle` | nil |
| `__kIMFMFSessionActiveDeviceChangedNotification` | `_updateActiveDevice` | device | nil |

The payload is the `object`; there is no `userInfo` on any of them.

This replaces the `FMFSessionDataManager.setLocations:` swizzle the Objective-C helper uses,
which is dead on macOS 26 — the class it swizzles is gone, so the shipping helper simply stops
delivering location events there without reporting it.

The same false negative applies to `__kIMAccountAliasesChangedNotification`: it is present in
IMCore as a string literal, so the `aliases-removed` swizzle is replaceable the same way. Not
done yet — see TODO.md.

## There is no API to SET your own location

Asked and answered, so nobody has to search again. Swept every class in IMCore,
`FindMyLocateObjCWrapper`, `FindMyLocate`, `FMF`, `FMFCore`, `FMCore`, `FindMyCore` and
`FindMyDevice` for any selector matching `setLocation`, `publishLocation`, `reportLocation`,
`sendLocation`, `myLocation`, `spoof`, `simulat` or `override`: **zero hits.**

`FMLLocation`'s full set of setters is a red herring. That object is a decoded model of a
location we RECEIVED — mutating one changes what this process believes about where a friend
is, and transmits nothing. Likewise `FMFSession.setLocations:` and
`FMFSessionDataManager.setLocations:` are inbound: the daemon pushing received locations into
the client, which is exactly why the Objective-C helper swizzled the latter to *observe*.

That matches the architecture. A FindMy client session is a view; the position originates in
`locationd` and is published by FindMy's own daemon, not by any client. `IMFMFSession` can
choose WHICH of your devices broadcasts — `makeThisDeviceActiveDevice`, `setActiveDevice:` —
but never what coordinates it broadcasts.

The only override surface on the system is CoreLocation's private `CLSimulationManager`
(`appendSimulatedLocation:`, `startLocationSimulation`), gated on the
`com.apple.locationd.simulation` entitlement. It is **not reachable from this helper**:
injected code inherits Messages.app's entitlements, and Messages has
`com.apple.findmy.findmylocate.locationservice`, `com.apple.locationd.desktop.registration`
and `.desktop.synchronous` — permission to read location and to use the FindMy locate
service — but not `.simulation`. Verified with `codesign -d --entitlements` on macOS 26.5.2.

It would also be the wrong tool. `CLSimulationManager` overrides location for the WHOLE
MACHINE — Maps, Weather, Safari, Find My, everything — which is not a side effect a chat
server should have.

So `startSharingFindMyLocation` shares the Mac's real position and cannot be made to share
anything else. That is the whole reason `feature_findmy_location_sharing` ships disabled, and
why its rationale says so in as many words rather than promising a fix.

## Share durations

`-[IMFMFSession _dateFromShareDuration:]`, read from the disassembly on macOS 26.5.2:

| Value | Expiry |
|---|---|
| `0` | one hour (`+[NSDate dateWithTimeIntervalSinceNow:3600]`) |
| `1` | end of the current day, by calendar |
| anything else | `nil` — shared indefinitely |

`BBPrivateAPIContract.FindMyShareDuration` encodes exactly these three and nothing else.
