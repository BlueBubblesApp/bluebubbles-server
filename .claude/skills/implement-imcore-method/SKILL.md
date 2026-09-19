---
name: implement-imcore-method
description: Implement a Private API method in the injected Swift helper, or add/fix an IMCore call, selector, swizzle or inbound event in Helper/. Use when filling in a notImplemented stub, adding a PrivateAPI contract method, chasing a selector that vanished on a new macOS, or debugging a helper that will not connect. Covers the contract-first order, how to find a selector and dump the header that proves it, IMCoreRuntime safety rules, the observation ladder, and arm64e verification.
---

# Implementing an IMCore method

Read [`.claude/docs/private-api.md`](../../docs/private-api.md) first.
**Then `docs/MACOS_COMPATIBILITY.md`, which is the start-here page for anything
version-shaped**: it carries the capability matrix, the per-release dumps and, in §3, the
distinction the rest of this file turns on — genuinely absent (a guard) against renamed
(a ladder).
Selector-level reference: `docs/PRIVATE_API_SURFACE.md`, `docs/OBSERVATION_LADDER.md`,
`docs/SONOMA_COMPATIBILITY.md`, `docs/SEQUOIA_COMPATIBILITY.md`, and the header dumps in
`docs/headers/<macos-version>/`.

**The stakes here are different from the rest of the repo: a mistake crashes the user's
Messages.app, not the server.**

## Step 0: find the selectors

An unimplemented method in `IMCoreBridge` throws `.notImplemented`. Find what it needs to call, in
this order:

1. `docs/PRIVATE_API_SURFACE.md`: whether the selectors are already recorded.
2. `docs/headers/<macos-version>/`: the committed header dumps. **A class with no header there
   is not a class that does not exist** — it is a class nobody asked about. `?` and `-` are
   different answers and §2 of `docs/MACOS_COMPATIBILITY.md` is built on the difference.
3. [Barcelona](https://github.com/beeper/barcelona): Apache-2.0, same licence, already Swift, and
   the best available answer to "which IMCore classes and selectors do I call". **Take the IMCore
   layer, not the architecture** (it runs standalone on an AMFI-disabled machine); expect Big Sur /
   Monterey-era drift; vendor selectively with a `NOTICE` entry rather than depending on the
   framework.

### Dumping a class the repo has not recorded

Never hand-roll this. `Tools/private-api/hosts.conf` is the list of classes to dump, one
`class <Name>` line under the right `group`; adding a name is a one-line change and needs no
shell. A class that does not exist on your macOS is not an error, it is the answer, and it is
written into the header as a `NOT PRESENT` comment.

```bash
cd Tools/private-api
./collect.sh                          # this Mac: dump, describe the machine, produce an archive
./vm-share.sh Sonoma Sequoia          # the releases this Mac is not running
# in each VM: open the shared folder, then  bash dump-headers-vm.sh
./import-dump.sh                      # file what the VMs produced under docs/headers/
```

Two traps, both of which produce a dump that looks fine and is not:

- **`vm-share.sh` is not housekeeping.** The share holds a COPY of `hosts.conf`, so a share
  that predates the class you just added dumps the old list: your class comes back with no
  header, which is indistinguishable from a release that does not have it. Re-run it before
  every dump.
- **A dump is filed by what it says it is**, never by the folder it arrived in. A dump taken on
  this Mac and filed as Sonoma is worse than no dump at all, which is why `dump-headers-vm.sh`
  refuses to run on a machine that is not the one its folder names and `import-dump.sh` reads
  the release from the dump's own `environment.txt`.

Also check the dump for the one failure that invalidates it: **a framework that fails to load
reports every one of its classes as absent**, which reads exactly like a removal.

If you had to hunt for selectors, **commit what you found**: the header dump, and an entry in
`PRIVATE_API_SURFACE.md`. The next person should not repeat it.

## Step 1: contract first, always

`Helper/BBPrivateAPIContract/` defines the surface once and is imported by **both** sides, so
there is no hand-maintained schema and no drift.

```swift
func setDisplayName(chat: ChatIdentifier, to name: String) async throws
```

Fully typed. **No `[String: Any]` payloads.**

Two files, not one. The METHOD goes on the role protocol it belongs to in `PrivateAPI.swift`;
any payload TYPE it takes or returns goes in the topic file beside it — `Messages.swift`,
`ChatState.swift`, `Polls.swift`, `Account.swift`, `TextFormatting.swift`, `Events.swift`,
`Identifiers.swift`, or `FaceTime.swift` / `FindMy.swift`, which were always separate. A type
that fits none of them is a new file, not an addition to `PrivateAPI.swift`: that file is the
contract, and the payloads were split out of it precisely because the two kept growing into
each other.

The server compiles against the contract, so each method lands independently and an unimplemented
one reports as unavailable rather than breaking the build. Do not batch several methods into one
change.

## Step 2: implement against `IMCoreRuntime`, never IMCore directly

IMCore ships no headers. Linking against a hand-maintained dump makes a moved selector a **link
error**, and a link error is a helper that never loads, and **dyld reports nothing when it
declines an insert**, so Messages just starts without it. One moved selector silently costs every
Private API feature at once. Runtime lookup degrades one feature loudly instead.

`IMCoreRuntime` refuses two call shapes that would otherwise crash Messages. Both look fine at the
call site:

| Mistake | What happens |
|---|---|
| Sending a selector the object does not have | ObjC exception → the user's Messages terminates |
| Right selector, wrong argument count (`responds(to:)` says yes for `sortedArrayUsingSelector:`; calling it with none passes garbage as a `SEL`) | abort |

## Step 3: guard the top of the version range, not the bottom

The helper targets **macOS 14 (Sonoma) and newer**, matching the package floor. Nothing below it
needs a branch, a header or a guard, and reference material written for older releases is not a
specification: a check reading "if macOS ≥ 11 do X else Y" collapses to X.

- **Guards belong at the other end.** macOS 26 adds IMCore surface Sonoma lacks and removes surface
  Sonoma has. Use `if #available(macOS 26, *)` **plus** a runtime `NSClassFromString` /
  `respondsToSelector` check: a class can disappear *within* a major version.
- **A nil from `NSClassFromString` inside a sandboxed host means "not loaded HERE", not "not on
  this Mac"**, and it must be cross-checked against the committed dumps before anything is
  concluded. The worked case: `docs/headers/macos-26.5.2/FMFSessionDataManager.h` carries
  `setLocations:`, byte-identical to the Sonoma dump, while the probe reports the class absent
  — because the probe runs inside Messages.app, where `FMF.framework` is not loaded. A guard
  written on that nil refuses a feature the release supports. `OBSERVATION_LADDER.md` holds the
  record and the correction.
- **Guard or ladder is a decision, and picking the wrong one costs a working feature.** The
  class is absent → a version guard. The class is present and the selector is not → a ladder
  onto the older spelling, and no catalog entry at all, because the feature works everywhere.
  `docs/MACOS_COMPATIBILITY.md` §3 sorts every one of ours into the two piles.
- **A vanished symbol degrades to `PrivateAPIError.unavailableOnThisOS`, never a crash.** That is
  reported distinctly from a method with no implementation, and clients rely on the distinction.

## Step 4: if it is an inbound event, climb the ladder

Outbound actions are ordinary method calls. Inbound events are the hard part, and swizzling is the
last resort rather than the default. Resolve each to the **highest rung that actually works**:

| Rung | Approach | |
|---|---|---|
| 1 | Observe an IMCore-posted `NSNotification` | **Try this first, every time.** Survives selector churn |
| 2 | Register as an additional `IMDaemonListener` | The protocol carries these events; whether a *second* listener can register inside a process that already has one is unverified |
| 3 | Swizzle a message-layer method | Fallback. **Record the rung-1 and rung-2 attempts that failed, in code** |
| 4 | Swizzle a UI-layer method | Last resort. **A defect to be replaced, not a solution** |

There is **no rung-1 or rung-2 implementation to copy from** for the existing events: reaching
those rungs is investigation work. Budget for it: rungs 1 and 2 are dramatically less
version-fragile than 3 and 4, which is why this subsystem needs per-release maintenance at all.

Where you do swizzle:

- **Swizzling means a runtime shim**: an `@objc` replacement on an `NSObject` subclass with a
  saved IMP.
- **Every hook needs a `respondsToSelector` guard** and must degrade to "this event stops firing"
  rather than trapping. A crash here takes the user's Messages with it.

## Step 5: test

```bash
swift test --filter HelperTests
swift test --filter BBPrivateAPITests    # protocol round-trips against FakeHelper
```

`Tests/BBPrivateAPITests/FakeHelper.swift` is the seam: the transport is a protocol precisely so
a double can substitute at it. Everything below the IMCore boundary should be unit-tested.

## Step 6: verify against a real Messages

CI cannot do this. It needs a SIP-disabled Mac.

```bash
swift build --arch arm64e --product BlueBubblesHelper
```

**It must be arm64e.** Messages runs its arm64e slice on Apple Silicon; a plain arm64 dylib maps
nowhere and dyld says nothing. Verify rather than assume:

```bash
vmmap "$(pgrep -x Messages)" | grep BlueBubblesHelper
```

Then confirm `GET /api/v1/server/info` reports `private_api: true, helper_connected: true`; that
also proves the socket handshake and the audit-token code-signature check passed.

**`os_log` from the injected helper does not reliably reach `log show`** (measured on macOS
26.5.2: subsystem, `senderImagePath` and process queries all return nothing while the helper is
demonstrably running). **Debug through what the helper sends over the socket.**

## Step 7: check the selectors still exist on new macOS

```bash
cd Tools/observation-probe && ./run-probe.sh
```

Read-only, no swizzles, no mutation. Its rung-3/4 section tells you whether the selectors the
helper swizzles still exist. Run it on every macOS beta: when one vanishes the helper silently
stops delivering that event, and the only symptom is a user saying typing indicators stopped
working.

The probe answers for the process it is inside. For the question "what moved between two
releases", read the dumps instead:

```bash
Tools/private-api/compare-releases.py                     # 15.6.1 vs 26.5.2, the default pair
Tools/private-api/compare-releases.py --unresolved        # selectors no dumped class explains
```

It reports every selector the helpers dispatch in one of four buckets, and **`UNCOMPARABLE` is
a result rather than a gap**: it means the class has no header on one side, so the comparison
cannot be made and nothing may be concluded from it.

A whole new macOS release is a larger job than this step — dump, compare, decide guard against
ladder, update the capability catalog and the compatibility matrix. That is the
`macos-release-sweep` skill.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Messages starts, no helper, nothing in any log | Wrong slice. Build `--arch arm64e` and confirm with `vmmap` |
| Helper loads but never connects | Socket path mismatch. **Never use `NSHomeDirectory()`**: it is container-relative inside the sandboxed app. Both sides use `getpwuid` via `SocketLocation.realHomeDirectory` |
| Helper connects, then drops; actions answered `unknown action` | One socket serving two apps. **The sandbox restriction is symmetric: bind one socket per app**, each inside that app's own container |
| Bind or connect fails on a long user name or network home | `sun_path` is 104 bytes and truncates silently. The explicit length check is there for this; do not remove it |
| Everything works for you and not for a user | You have Full Disk Access. The server needs it to write into another app's container, and the Private API now depends on that where it did not before |
| Messages crashes on a call | Selector missing or wrong argument count. Route it through `IMCoreRuntime` |
