# Private framework headers

Headers for the private classes this port calls, one directory per macOS release. **Every
directory is read from the Objective-C runtime** on a machine running that release, out of a
process built for the same platform as the host app, so each one describes the framework
Messages.app actually loads, not a lookalike copy.

Regenerate with:

```bash
Tools/private-api/dump-headers.sh
```

That dumps the release THIS Mac runs, which is Tahoe. Sonoma and Sequoia are dumped in VMs and
come back through a shared folder:

```bash
Tools/private-api/vm-share.sh Sonoma Sequoia   # before the dump: the share holds a COPY
                                               #   of hosts.conf and goes stale
# in the VM: open the shared folder, then  bash dump-headers-vm.sh
Tools/private-api/import-dump.sh               # after: files it under the release its own
                                               #   environment.txt names, not the folder's
```

The tools, and the guide to send someone collecting a dump from a macOS release nobody here
runs, are documented in [`../private-api/`](../private-api/).

It writes `docs/headers/macos-<version>/`, named after `sw_vers -productVersion`. Run it on
each macOS we support and commit the result: the diff between two directories is the answer
to "what did Apple move this time", which is the question that costs the most time when a
Private API feature stops working.

## What is here

| Directory | Release | How it was produced |
|---|---|---|
| `macos-14.6.1/` | Sonoma, build 23G93, arm64 | runtime dump, in a VM |
| `macos-15.6.1/` | Sequoia, build 24G90, arm64 | runtime dump, in a VM |
| `macos-26.5.2/` | Tahoe, build 25F84, arm64 | runtime dump, the release this project develops against |

All three were re-dumped on 16 September 2026 from one `hosts.conf`, and carry **143 headers
each**. Equal counts are what makes a missing class a finding rather than an artefact of when a
VM last ran, and they stop being equal the moment a class is added to `hosts.conf` without every
release being re-dumped. `Tools/private-api/vm-share.sh --list` reports the counts.

Each carries an `environment.txt` recording the machine, the toolchain, whether each host app
was Catalyst or native, and the classes that release does not have. Read it first: the
`app … catalyst` lines are what decide which copy of a shared framework the dump describes.
Each was produced by `Tools/private-api/collect.sh`, and each records the toolchain that
built the dumper as well as the machine it ran on.

[`../MACOS_COMPATIBILITY.md`](../MACOS_COMPATIBILITY.md) is what these directories are FOR:
one capability-and-selector matrix across all three, generated from them by
`Tools/private-api/compare-releases.py --matrix`. No release has a page of its own any
more: every divergence 14 and 15 have is a row in that matrix's §3a or §3b, and the two ways
a reader can misread these directories are the section below.

## All three are runtime dumps

There used to be a long section here explaining why `macos-15.6/` had to be read differently
from its neighbours: it was a third-party class-dump transcribed from
[developer.limneos.net](https://developer.limneos.net/), read from the Mach-O rather than the
runtime, and taken from the **native** macOS frameworks rather than the `/System/iOSSupport`
copies Messages.app actually loads. ChatKit has no native copy at all, so the entire send
path was simply missing from it.

**It is gone.** `macos-15.6.1/` is a runtime dump from a Sequoia VM, Catalyst-built, 140
classes: the same coverage as 26.5.2. Nothing in this directory is borrowed any more, and
no conclusion about Sequoia needs hedging.

Two things are worth keeping from that episode:

- **Roughly two-thirds of the "differences" the borrowed dump showed were artefacts of the
  dump.** `compare-releases.py --matrix` listed 129 divergent selectors across the three
  releases before, and 43 after. Every one of the 86 that disappeared was a `?` that read
  like a finding.
- **`Tools/private-api/limneos-scrape.js` and `import-limneos.mjs` built that dump.** They
  are kept for the next release nobody has hardware for, and they carry the same caveat they
  always did: what they produce is evidence, not measurement, and it should be labelled as
  such in the directory it lands in.

The one rule that outlived it is in `dump-headers.m` and in every `environment.txt`: **a dump
is only about the platform it was taken on.** `app com.apple.MobileSMS … catalyst` is the
line that says which copy of each shared framework a directory describes, and it is the first
thing to read when two directories disagree.

## Two ways to read these and be confidently wrong

Both have happened here, both produce findings rather than errors, and both point in the
same direction: they manufacture absences. Anything concluded from these directories has to
survive them.

### A multi-argument selector never appears as a string in a header

A declaration interleaves the argument types between the keywords:

```objc
- (unsigned long long)markAsSpam:(unsigned long long)arg0 isJunkReportedToCarrier:(bool)arg1;
```

The string `markAsSpam:isJunkReportedToCarrier:` does not occur in that line. So grepping a
header for a selector reports **every multi-argument selector on the machine as missing**,
silently. An earlier gap analysis concluded on exactly this evidence that
`-markAsSpam:isJunkReportedToCarrier:` existed on no release and that the preferred branch of
`markAsSpam(count:reportToCarrier:)` was dead code. It is on `IMChat` in all three
directories, and the branch fires everywhere.

`Tools/private-api/compare-releases.py` reconstructs selectors from the declarations instead,
which is what it is for. Use it rather than `grep` for any question of the form "does this
release have this selector", and treat a bare `grep` hit as a lower bound only — it is
reliable for a no-argument selector and for nothing else.

### A framework that fails to load reports every one of its classes absent

`NOT PRESENT` is written for a class the runtime does not answer for, and a `dlopen` that
failed is indistinguishable from Apple having removed the class. A missing *selector* cannot
be caused by this — a class carrying 900 other methods plainly loaded — so only whole-class
absences are at risk.

The test is whether **other classes from the same framework** dumped in that directory. If
they did, the framework loaded and the absence is real; if a framework contributed nothing
at all, nothing may be concluded about any of its classes. Two checks corroborate it: no
header should be present-but-empty, which is what a truncated dump looks like, and method
counts for classes that ARE present should match their counterparts on the other releases.

The `// Image:` line is the third check and answers a different question — whether two
directories are describing the same binary. `app com.apple.MobileSMS … catalyst` in
`environment.txt` says which copy of each shared framework a directory describes, and a
comparison across two dumps of *different* copies is not a comparison at all.

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
Messages.app. It is not; see below.

`class_copyMethodList` reports what the runtime will actually dispatch, so there is no fidelity
lost against parsing a binary, and the tool runs anywhere without extracting the dyld shared
cache.

## What is reachable from inside Messages.app

`IMFMFSession` is an **IMCore** class, so it is already in Messages.app's address space:
nothing has to be loaded for it. Verified on macOS 26.5.2:

```
PRESENT  IMFMFSession        /System/Library/PrivateFrameworks/IMCore.framework/…/IMCore
PRESENT  IMFindMyHandle      …/IMCore
PRESENT  IMFindMyLocation    …/IMCore
PRESENT  IMFindMyDevice      …/IMCore
```

`FindMyLocateSession`, `FMLHandle`, `FMLLocation`, `FMLFriend`, `FMLDevice` and `FMLPlaceMark`
live in `FindMyLocateObjCWrapper.framework`, which is **not** loaded at process start:
`IMFMFSession` dlopens it itself through `__FMLSessionClass`. That is why a naive
`NSClassFromString("FindMyLocateSession")` at launch reports the class as missing.

`-[IMFMFSession _initializeFindMySessionIfInAllowedProcess]` gates on
`IMIsRunningInImagent() || IMIsRunningInMessagesUIProcess()`. Messages.app satisfies the
second, so an injected helper gets a live session.

### There is no OS-version fork any more

The shipping Objective-C helper branches on `operatingSystemVersion.majorVersion > 13` to
choose between `FindMyLocateSession` and the legacy `FMFSession`. **Do not carry that
forward.** IMCore now makes the same choice itself, off an internal feature flag:
`-[IMFMFSession findMyHandlesSharingLocationWithMe]` reads `isFindMyLocateSessionEnabled` and
dispatches to `cachedFriendsSharingLocationsWithMe` or `getHandlesSharingLocationsWithMe`
accordingly, returning `IMFindMyHandle` either way.

Prefer the `IMFMFSession` wrapper API for anything it covers: it absorbs the fork, and it is
the layer Messages itself calls.

## Notifications (rung 1)

IMCore posts these on `NSNotificationCenter.default`. They are plain string literals in
IMCore's `__cstring`, **not exported symbols**: a `dlsym` lookup for them fails, which is a
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
which is dead on macOS 26: the class it swizzles is gone, so the shipping helper simply stops
delivering location events there without reporting it.

The same false negative applies to `__kIMAccountAliasesChangedNotification`: it is present in
IMCore as a string literal, so the `aliases-removed` swizzle is replaceable the same way. Not
done yet; see TODO.md.

## There is no API to SET your own location

Asked and answered, so nobody has to search again. Swept every class in IMCore,
`FindMyLocateObjCWrapper`, `FindMyLocate`, `FMF`, `FMFCore`, `FMCore`, `FindMyCore` and
`FindMyDevice` for any selector matching `setLocation`, `publishLocation`, `reportLocation`,
`sendLocation`, `myLocation`, `spoof`, `simulat` or `override`: **zero hits.**

`FMLLocation`'s full set of setters is a red herring. That object is a decoded model of a
location we RECEIVED: mutating one changes what this process believes about where a friend
is, and transmits nothing. Likewise `FMFSession.setLocations:` and
`FMFSessionDataManager.setLocations:` are inbound: the daemon pushing received locations into
the client, which is exactly why the Objective-C helper swizzled the latter to *observe*.

That matches the architecture. A FindMy client session is a view; the position originates in
`locationd` and is published by FindMy's own daemon, not by any client. `IMFMFSession` can
choose WHICH of your devices broadcasts (`makeThisDeviceActiveDevice`, `setActiveDevice:`)
but never what coordinates it broadcasts.

The only override surface on the system is CoreLocation's private `CLSimulationManager`
(`appendSimulatedLocation:`, `startLocationSimulation`), gated on the
`com.apple.locationd.simulation` entitlement. It is **not reachable from this helper**:
injected code inherits Messages.app's entitlements, and Messages has
`com.apple.findmy.findmylocate.locationservice`, `com.apple.locationd.desktop.registration`
and `.desktop.synchronous`: permission to read location and to use the FindMy locate
service, but not `.simulation`. Verified with `codesign -d --entitlements` on macOS 26.5.2.

It would also be the wrong tool. `CLSimulationManager` overrides location for the WHOLE
MACHINE (Maps, Weather, Safari, Find My, everything) which is not a side effect a chat
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
| anything else | `nil`: shared indefinitely |

`BBPrivateAPIContract.FindMyShareDuration` encodes exactly these three and nothing else.
