# Testing the event-observation ladder

**Status:** investigation, not implementation. Nothing here ships. The output is a decision
about how Phase 5 obtains four inbound events, recorded in the table at the end of this file.

---

## Why this exists

Outbound actions — send, react, rename a group — are ordinary method calls into IMCore. They
port mechanically.

**Inbound events are the hard part.** The shipping helper obtains all four of them by
**swizzling methods inside Messages.app**. It contains no notification observers at all; the
one `addObserver:` in `BlueBubblesHelper.m` is commented out. So there is no rung-1 or rung-2
implementation to port — this is design work the rewrite does not inherit, and it has to be
settled empirically before Phase 5 writes the helper, not after.

The four events, and how they are obtained today:

| Event | Hooked method | Layer | Rung |
|---|---|---|---|
| `started-typing` / `stopped-typing` (pre-Tahoe) | `IMChat._handleIncomingItem:` | message | 3 |
| `aliases-removed` | `IMAccount._registrationStatusChanged:` | account | 3 |
| `new-findmy-location` | `FMFSessionDataManager.setLocations:` | FindMy | 3 |
| `started-typing` / `stopped-typing` (macOS 26+) | `CKConversationListStandardCell.setShowTypingIndicator:` | **UI** | 4 |

That last row walks `cell → conversation → chat → guid` through `NSSelectorFromString` inside
a `@try`, and fires only while that list cell exists. It is a stopgap that appeared because
the `IMChat` path broke on Tahoe — not a design anyone chose — and it is the clearest
argument for doing this investigation rather than transcribing what is there.

## The ladder

Each event gets resolved to the **highest rung that actually works**.

| Rung | Approach | Why it is better than the one below |
|---|---|---|
| **1** | Observe an IMCore-posted `NSNotification` | Non-invasive, survives selector renames, cannot crash the host |
| **2** | Register as an additional `IMDaemonListener` or delegate | A supported extension point; API-stable across releases |
| **3** | Swizzle a message-layer method | Works, but breaks whenever Apple renames or re-arities a private selector |
| **4** | Swizzle a UI-layer method | Fires only when the relevant view exists. A defect to be replaced |

Rungs 1 and 2 are dramatically less version-fragile than 3 and 4, which is precisely why this
subsystem needs per-release maintenance today. Every event moved up the ladder is one less
thing that silently breaks on the next macOS.

There is real reason to expect rung 1 or 2 to work:

- **Barcelona observes message-layer events without swizzling.** It runs standalone and
  *cannot* swizzle Messages.app, so it registers as an `IMDaemonListener` instead. That
  proves the protocol carries these events. What is unverified is whether a **second**
  listener can register inside a process that already has one — which is exactly what the
  probe tests.
- **FindMy has a documented delegate protocol.** `FMFSessionDelegate` declares
  `didReceiveLocation:`. The location updates currently obtained by swizzling
  `setLocations:` are something the framework already offers to hand you. This is the most
  likely rung-2 win, and the cheapest to confirm.
- **Plain notification observation was never attempted here.** Not ruled out — untried.

---

## What you need

|  | Required for |
|---|---|
| A Mac running the macOS you care about | everything |
| **SIP disabled** | rungs 1–4. Library validation otherwise refuses to load an unsigned dylib into Messages.app |
| **Library validation disabled** | rungs 1–4, on some configurations, in addition to SIP (see Troubleshooting) |
| A second device signed into the same Apple ID | generating typing indicators and read receipts |
| Xcode 16.3+ / Swift 6.1 | building the probe |

SIP is the only unusual requirement, and it is the same one the Private API has. Everything
else in the server works with SIP on.

### Two things that will waste your afternoon

Both produce the same symptom — a probe that appears to run and logs nothing — and neither
announces itself. `run-probe.sh` now handles both, but they are worth knowing because they
apply to the shipping helper too.

**The probe must be built for the slice Messages runs.** On Apple Silicon that is **arm64e**,
not arm64. dyld will not load an arm64 dylib into an arm64e process: it skips the inserted
library, prints one line to stderr, and lets Messages start normally. Nothing crashes and
nothing is logged. This is why the shipping `BlueBubblesHelper.dylib` is universal with an
arm64e slice, and `run-probe.sh` now builds `--arch arm64e` and asserts the result.

**The log is not where you would guess.** Messages.app is sandboxed, so inside it
`~/Library/Logs` resolves to its container. The probe's log is at:

```
~/Library/Containers/com.apple.MobileSMS/Data/Library/Logs/bluebubbles-server/observation-probe.log
```

`./run-probe.sh --log` prints that path, and the probe writes it into its own `ENVIRONMENT`
section. Writing to the real home instead is not an option — the sandbox denies it.

> **Only the probe needs a Mac.** Rungs 3 and 4 can be *pre-checked* from anywhere — see
> "Checking rungs 3 and 4 without a Mac" below.

---

## Running the probe

```sh
cd swift/Tools/observation-probe
./run-probe.sh
```

That builds the probe, quits Messages.app, relaunches it with the dylib injected, and tails
the log.

**What it does to your machine:** it observes. It installs no swizzles, mutates nothing,
sends nothing, and writes only to the log file named above (`./run-probe.sh --log`).
Quitting the instrumented Messages and reopening it normally undoes everything —
`./run-probe.sh --restore` does that for you. There is nothing to uninstall.

### The script's other modes

```sh
./run-probe.sh --build-only   # build without touching Messages
./run-probe.sh --summary      # make a running probe write its summary now (SIGUSR1)
./run-probe.sh --log          # print the path to the log
./run-probe.sh --restore      # quit the instrumented Messages, reopen it normally
```

The script verifies that the dylib is actually mapped into Messages before it claims success.
Do not skip that check if you run the injection by hand: **Messages launching proves nothing**,
because dyld carries on without a library it declined.

### Exercising the events

Once the probe reports `=== READY ===`, perform each action and **note the time**. The
probe cannot know which notification corresponds to which action; you correlate by
timestamp, which is why writing them down matters.

| # | Action | Event under test |
|---|---|---|
| 1 | Have someone start typing to you in an existing chat, wait ~10s, have them stop | `started-typing` / `stopped-typing` |
| 2 | Send yourself a message from the second device | baseline — confirms the probe sees message traffic at all |
| 3 | Mark a conversation read on the second device | read receipt path |
| 4 | If you use FindMy sharing, wait for a location update (or open FindMy on the phone) | `new-findmy-location` |
| 5 | *(optional, disruptive)* Remove an email alias from your Apple ID in System Settings | `aliases-removed` |

Step 5 is genuinely disruptive to a live Apple ID. **Skip it on your daily-driver account.**
Its outcome is the least important of the four: `aliases-removed` is rare and its current
rung-3 hook has been the most stable of the set.

Then:

```sh
./run-probe.sh --summary
open "$(./run-probe.sh --log)"
```

---

## Reading the output

The log has four sections.

### `ENVIRONMENT`

Sanity check. If `IMCore loaded: false`, injection did not work and nothing below means
anything.

### `RUNGS 3 and 4 — current swizzle targets`

Run this first on any new macOS, before anything else:

```
rung 3  PRESENT       IMChat _handleIncomingItem: — typing indicators (pre-Tahoe)
rung 3  SELECTOR GONE IMAccount _registrationStatusChanged: — aliases-removed
```

`SELECTOR GONE` or `CLASS GONE` means **the shipping helper has silently stopped delivering
that event on this OS**. The symptom users report is "typing indicators stopped working",
with nothing in any log — so this check is worth running on every macOS beta regardless of
what else you are investigating.

### `RUNG 2 — IMDaemonListener handler registration`

The decisive section. The line that matters:

```
AVAILABLE  -[listener addHandler:]
```

If `addHandler:` is available, **rung 2 is reachable** and a second observer can attach
alongside the one Messages.app already has — no swizzling. That is the outcome that lets the
Swift helper ship without inheriting the fragile parts.

Below it, the probe dumps every method on the listener class whose name mentions
typing/status/account/location. **That list is the most valuable artifact of the whole run**:
it names the callbacks rung 2 could deliver, which tells you whether all four events are
reachable or only some.

If `addHandler:` is absent, the probe dumps the controller's methods mentioning
`listen`/`handler`, so a renamed accessor is still visible rather than the run just failing.

### `RUNG 1 — summary`

Every notification posted in the process, by frequency. Deliberately unfiltered: we do not
know which notification carries a typing change — that is the question — so filtering to
names containing "typing" would only confirm that the obvious names do not exist.

Read it by correlating with your noted timestamps. Search the detail lines for the moment you
started typing and look at what fired in that second. A promising candidate:

- fires within ~1s of the action,
- has an `object` of a plausible class (`IMChat`, `IMAccount`, `IMHandle`),
- has `userInfo` keys naming the thing that changed.

High-frequency entries (hundreds of occurrences) are heartbeats and can be ignored.

---

## Checking rungs 3 and 4 without a Mac

You do not need to inject anything to know whether the current selectors still exist. The
helper's own vendored headers plus the framework binaries are enough:

```sh
# Are the classes and selectors still in the shipping frameworks?
nm -U /System/Library/PrivateFrameworks/IMCore.framework/Versions/A/IMCore \
  | grep -E '_handleIncomingItem|_registrationStatusChanged'

# What does the daemon listener actually expose? (needs class-dump or ktool)
class-dump -C IMDaemonListener /System/Library/PrivateFrameworks/IMCore.framework
```

This is a fast pre-check that narrows what the probe run needs to answer. It cannot tell you
whether a **second** listener can register — that is behavior, not symbols, and it is the one
thing the probe run genuinely has to establish.

---

## Troubleshooting

**The log has only the `# run started` banner and nothing after it.** The banner is written
by the shell script; everything below it is written by the probe. A banner with nothing under
it means the probe never ran, which means the dylib was not loaded. Check, in order:

```sh
# 1. Is the dylib actually mapped into Messages?
vmmap "$(pgrep -x Messages)" | grep ObservationProbe

# 2. Does its architecture match the slice Messages is running?
lipo -archs .build/arm64e-apple-macosx/release/libObservationProbe.dylib   # want: arm64e
lipo -archs /System/Applications/Messages.app/Contents/MacOS/Messages      # x86_64 arm64e
```

If the env var is present but the image is not mapped, dyld declined it. `run-probe.sh`
captures Messages' stderr to `.build/messages-stderr.log`; dyld's reason is there and nowhere
else. Never inject with `2>/dev/null` — that discards the only explanation you get.

**The probe is loaded but the log is empty.** You are reading the wrong file. See "The log is
not where you would guess" above, or run `./run-probe.sh --log`.

**Messages exits immediately on launch.** That is library validation, not architecture. SIP
must be disabled, and on some configurations you also need:

```sh
sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist \
  DisableLibraryValidation -bool true
```

---

## Recording the outcome

Fill this in and commit it. Phase 5 reads it as its specification.

### Established by probe run — macOS 26.5.2 (25F84), Apple Silicon

These come from the probe's static sections, which need no user actions and are settled:

| Finding | Result |
|---|---|
| `-[listener addHandler:]` | **AVAILABLE** — rung 2 is reachable |
| `IMDaemonController.sharedInstance` | `IMDistributingProxy` |
| its `listener` | `_IMLegacyDaemonListener`, exposes `addHandler:`, `removeHandler:`, `handlers` |
| `IMDaemonListener.sharedInstance` | absent — the class-level singleton is not the way in; go through the controller |
| `FMFSession` / `FMFSessionDataManager` | **CLASS GONE** |
| `IMFMFSession.sharedInstance` | present, but exposes no delegate accessor |
| `IMChat _handleIncomingItem:` | PRESENT |
| `IMChat _handleIncomingItem:updateReplyCounts:` | SELECTOR GONE |
| `IMAccount _registrationStatusChanged:` | PRESENT |
| `CKConversationListStandardCell setShowTypingIndicator:` | PRESENT (rung 4) |

Two of these change the plan:

1. **`addHandler:` exists.** A second observer can be offered to the listener that Messages
   already owns, without swizzling. Whether it is actually *called* alongside the existing
   one is behavior, not symbols, and still needs an exercised run — but the registration
   surface is there, which was the open question.

2. **`FMFSessionDataManager` no longer exists on macOS 26.5.2.** The shipping helper swizzles
   `FMFSessionDataManager.setLocations:` for `new-findmy-location`. That target is gone, so
   that event is already dead on this macOS — silently, which is exactly the failure mode
   this document was written to catch.

   **This was originally recorded as "no path at any rung". That reading was wrong**, and the
   way it was wrong is worth keeping: the probe looked for the classes the OBJECTIVE-C HELPER
   uses and, not finding them, concluded the capability was unreachable. The capability moved;
   it did not go away. IMCore posts `__kIMFMFSessionLocationReceivedNotification` and four
   siblings on the default center, which is **rung 1** — better than the swizzle it replaces.
   They are string literals inside IMCore rather than exported symbols, so the `dlsym` probe
   that dismissed them was asking the wrong question. Full table in
   `docs/headers/README.md`; the request/response half is implemented in
   `Helper/BlueBubblesHelper/FindMyBridge.swift`, and the notification observer is not wired
   yet.

Note the listener's method dump contains **no selector matching "typing"**. Typing changes
arrive some other way — most likely inside
`account:chat:style:chatProperties:messageReceived:` — which the exercised run below has to
confirm.

### Established by an injected run — macOS 26.5.2 (25F84), Apple Silicon

**Rung 2 registration works.** The open question this whole document existed to answer — can a
SECOND handler attach inside a process that already has one — is **yes**. Measured by injecting
the Swift helper into a real Messages.app: `addHandler:` accepted our handler, and the helper
reported `events: "daemon-listener"` in its registration handshake, which the server logged as
`inboundEvents=daemon-listener`.

`EventObservation.swift` implements it. Nothing is swizzled, Messages.app's own handler is
untouched, and removing ours restores the process exactly.

**One thing that made this harder than it should have been, worth recording:** `os_log` from an
injected dylib inside a sandboxed host **does not reliably reach `log show`**. Queries by
subsystem, by `senderImagePath` and by process all returned nothing while the helper was
demonstrably running and connected. That is why the observation rung is reported in the
registration handshake rather than logged — the socket is the only channel out of an injected
helper that is known to work.

### Still open — needs an exercised run

Record one row **per macOS version**, not one row per event. The supported range runs from
the **macOS 14 (Sonoma) floor** to the current release, and the range matters at both ends:
the floor is what lets the Swift helper drop the Objective-C helper's Mojave-era branches
entirely, while the top end is where IMCore surface keeps moving. `FMFSessionDataManager`
above is the proof — present on older systems, **gone on macOS 26.5.2**. A table with a
single "does this work" column would have recorded that as a flat failure instead of a
version boundary.

| macOS | Event | Rung reached | Mechanism | Evidence |
|---|---|---|---|---|
| 26.5.2 | `started-typing` / `stopped-typing` | **2** | `IMDaemonController.listener.addHandler:` + `account:chat:style:chatProperties:messageReceived:` | Registered on a live Messages.app; helper reported `inboundEvents=daemon-listener` on connect |
| 26.5.2 | `aliases-removed` | **1 available, not wired** | `__kIMAccountAliasesChangedNotification` | Present in IMCore's `__cstring` as a literal. The earlier "not exported (dlsym)" reading was a false negative — these names are `@"…"` literals, not symbols. Rung 3 (`IMAccount._registrationStatusChanged:`) still PRESENT |
| 26.5.2 | `new-findmy-location` | **1 available, not wired** | `__kIMFMFSessionLocationReceivedNotification` (object: `IMFindMyHandle`, userInfo: nil) | `FMFSessionDataManager` CLASS GONE, but IMCore posts five FindMy notifications; same literal-vs-symbol false negative. Table in `docs/headers/README.md` |
| 26.5.2 | read receipts | n/a | chat.db | Not an observation-ladder event — `ChangeDetector` reads them from the database |
| 14.x | `started-typing` / `stopped-typing` | | | |
| 14.x | `aliases-removed` | | | |
| 14.x | `new-findmy-location` | | | |
| 14.x | read receipts | | | |

Anything that differs between two rows for the same event is a version guard the helper has
to carry — `if #available(macOS 26, *)` plus a runtime `NSClassFromString` /
`respondsToSelector` check, since a class can vanish within a major version too.

**What remains for typing specifically:** registration is proven; DELIVERY is not. Confirming
that our handler is called alongside Messages' own needs an inbound message from another
device, which cannot be manufactured locally — an outgoing send does not fire
`messageReceived:`. Until someone types at an instrumented Mac, the correct statement is
"registered, delivery unverified".

A rung-1 candidate worth watching for `aliases-removed`:
`__kIMAccountAliasesChangedNotification` (object `IMAccount`, userInfo carries
`__kIMAccountAliasesAddedKey`) fires on the default center during account setup. If it also
fires on removal, `aliases-removed` is a rung-1 event and its swizzle can go.

**Do not check for a notification with `dlsym`.** IMCore builds these names from `@"…"`
literals rather than exporting them as symbols, so a symbol lookup reports absent for a
notification that is posted on every account change. Search IMCore's `__TEXT,__cstring`
instead — `swift/Tools/private-api/notifications.sh` is the mechanism. This exact false negative was recorded
as fact for both `aliases-removed` and `new-findmy-location`, and cost the FindMy port a
release.

For anything that lands on rung 3 or 4, record **which rung-1 and rung-2 attempts failed and
how**. The plan requires that to be a comment in the helper source next to the swizzle, so
the next person does not repeat the investigation — and so a future macOS that fixes the
underlying path can be noticed rather than worked around forever.

---

## Rules for whatever survives on rungs 3 and 4

1. **ZKSwizzle does not carry over.** It is Objective-C. Swift needs a runtime shim: an
   `@objc` replacement on an `NSObject` subclass plus a saved IMP.
2. **A crash here takes the user's Messages.app with it.** Every hook needs a
   `respondsToSelector` guard and must degrade to "this event stops firing" rather than
   trapping. An event that silently stops is a bug report; a Messages.app that crashes on
   launch is a user who uninstalls.
3. **Report unavailability distinctly.** `PrivateAPIError.unavailableOnThisOS` is not the
   same as "not ported yet", and conflating them makes a macOS regression look like an
   incomplete port.

---

## What this does *not* investigate

Whether injection reaches IMCore at all on macOS 26 — **that question is closed**. The
shipping helper carries working Tahoe support, so injection works. What erodes on new macOS
is not access but individual observation paths, which is the argument for climbing this
ladder rather than inheriting the bottom of it.
