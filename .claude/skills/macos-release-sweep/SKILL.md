---
name: macos-release-sweep
description: Work out what a macOS release changed for the Private API, and update the repository to match. Use when a new macOS (or beta) ships, when a feature works on one release and not another, when a user reports that typing indicators or reactions stopped working after an update, when adding a class to the header dumps, or when the capability catalog, compatibility matrix or per-release docs need to be brought up to date. Covers dumping headers in a VM, validating a dump, comparing releases, deciding guard versus ladder, and the tests that keep the catalog honest.
---

# Sweeping a macOS release

Read [`docs/MACOS_COMPATIBILITY.md`](../../docs/MACOS_COMPATIBILITY.md) first: §2 is the
dumps, §3 is guard-against-ladder, §6 is every dispatched selector by category. This skill is
the procedure that produces that page.

**The mistake this whole exercise exists to avoid** is treating "I could not check this" as an
answer. A missing header is not evidence of a missing selector; a nil from the runtime is not
evidence of a missing class. Every step below is built around keeping those separate.

## Step 0: what you are actually being asked

| The question | Start at |
|---|---|
| Does feature X work on release Y? | §6 of `MACOS_COMPATIBILITY.md`; the cell meanings in §2 |
| A selector we call vanished | `compare-releases.py` (step 3), then guard or ladder (step 4) |
| An inbound event stopped firing | The observation probe (step 6). Rungs 3 and 4 are the fragile ones |
| A whole new release shipped | All of it, in order |

## Step 1: dump every release, from the same list

`Tools/private-api/hosts.conf` is the list of classes to dump — one `class <Name>` line under
the right `group`, plus the `app` line that decides whether the dumper is built Catalyst or
native, because the two see different copies of several private frameworks. Adding a name is a
one-line change and needs no shell. A class that does not exist on your macOS is not an error:
it is the answer, written into the header as a `NOT PRESENT` comment.

```bash
cd Tools/private-api
./collect.sh                          # this Mac: dump, describe the machine, produce an archive
./vm-share.sh Sonoma Sequoia          # rebuild the share for every release you are not running
# in each VM: open the shared folder, then  bash dump-headers-vm.sh
./import-dump.sh                      # file what came back, under docs/headers/
```

- **Re-run `vm-share.sh` before every dump.** The share holds a COPY of `hosts.conf`; a copy
  that predates the class you just added dumps the old list, and your class comes back with no
  header — indistinguishable from a release that does not have it.
- **A dump is filed by what it says it is.** `dump-headers-vm.sh` refuses to run on a machine
  that is not the one its folder names, and `import-dump.sh` takes the release from the dump's
  own `environment.txt` rather than from the directory it arrived in. A dump taken on this Mac
  and filed as Sonoma is worse than no dump at all.

## Step 2: validate the dump before you conclude anything from it

One failure invalidates a whole directory: **a framework that fails to load reports every one of
its classes as absent**, which reads exactly like a removal. Check for it, and check that no
header is present-but-empty. Record the build and the host app platform; `environment.txt`
should name the app and `catalyst` or `macos`.

**A dump taken on the wrong platform is the same failure wearing a different hat.** The dumper
is built Catalyst or native to match the host app, and the two see different copies of several
private frameworks: a native dump cannot see ChatKit at all, and every class it misses reads as
a divergence. `environment.txt` is what settles which one you have; §2 of
`docs/MACOS_COMPATIBILITY.md` records what this cost when it went wrong.

## Step 3: compare, and respect the four buckets

```bash
Tools/private-api/compare-releases.py                     # the default pair
Tools/private-api/compare-releases.py docs/headers/macos-14.6.1 docs/headers/macos-26.5.2
Tools/private-api/compare-releases.py --unresolved        # selectors no dumped class explains
Tools/private-api/compare-releases.py --matrix            # all releases, by hosts.conf group
```

It reads every Objective-C selector the helpers actually dispatch, so it answers about what we
call rather than about IMCore at large.

| Bucket | Means | Do |
|---|---|---|
| `BOTH` | present on both sides | nothing |
| `ONLY-<rel>` | present on one, absent from the other **though its class was dumped there** | step 4 |
| `UNCOMPARABLE` | its class has no header on one side | dump the class (step 1) and re-run. Conclude nothing |
| `UNRESOLVED` | no dumped class on either side declares it | add the class to `hosts.conf`, or find out what really declares it |

`--unresolved` is worth running on its own: a selector nothing explains is usually a name we
call that no longer belongs to the class we think it does.

## Step 4: guard or ladder — and this is the decision that matters

Picking the wrong one is how a feature Apple merely renamed ends up refused on a release that
supports it.

| The dump says | Fix | In the catalog? |
|---|---|---|
| The **class** is absent (`-`) | A version guard: `if #available(macOS 26, *)` **plus** a runtime `NSClassFromString` / `respondsToSelector` check, since a class can disappear within a major version | Yes — this is what the catalog lists |
| The class is there, the **selector** is not (`no`) | A ladder onto the older spelling | **No entry at all.** The feature works everywhere; listing it would advertise an upgrade that buys nothing |
| `?` — no header for that class | Neither. Nobody asked. Go and dump it | — |

**A nil from `NSClassFromString` inside a sandboxed host means "not loaded HERE", not "not on
this Mac."** `OBSERVATION_LADDER.md` recorded `FMFSessionDataManager` as CLASS GONE on macOS 26
and drew a roadmap conclusion from it, while `docs/headers/macos-26.5.2/FMFSessionDataManager.h`
carries `setLocations:`, byte-identical to the Sonoma dump: the probe runs inside Messages.app,
where `FMF.framework` is not loaded. **Cross-check every runtime absence against the dumps
before writing it down.**

Where you add a guard, put it at the **interface**, not in the helper: a helper-side failure is
reported after the request has already been accepted. `POST /chat/:guid/known` answered 200 and
did nothing on macOS 14 and 15.

## Step 5: update the executable half

`Sources/BBPrivateAPICatalog` carries the same facts as the compatibility TL;DR, as code, and
three things read it: the version gates, the settings screen, and the tests. Adding a capability
is two lines there and nothing anywhere else.

**Declare `evidence`, never a bare version number.** A version is the conclusion; naming the
class or selector that decides it is what lets `CapabilityCatalogTests` re-derive the minimum
from `docs/headers/` and fail on a wrong one. Three tests close three different ways this rots:

| Could go wrong | Caught by |
|---|---|
| A wrong macOS minimum | "Every declared minimum is the oldest release whose dump has the evidence" |
| A feature missing from the catalog entirely | `ActionCoverageTests` walks every `MessagesHelperAction` and `FaceTimeHelperAction`, failing unless each is claimed or exempted with a reason |
| API vocabulary reaching the screen | the test rejecting any title, summary or heading naming a class, selector, framework or Apple type prefix |

What is **not** automatic is writing the entry: nothing infers a title or a one-line summary
from a selector, and nothing should. That copy is the product decision; the tests exist to make
sure it is made.

## Step 6: inbound events need the probe, not the dump

A dump says a selector exists. It does not say the event still arrives.

```bash
cd Tools/observation-probe && ./run-probe.sh
```

Read-only: no swizzles, no mutation, nothing sent. Needs SIP disabled. Its rung-3/4 section is
the one to read on every beta — when a swizzled selector vanishes the helper silently stops
delivering that event, and the only symptom is a user saying typing indicators stopped working.

Resolve anything you touch to the **highest rung that works**: a posted `NSNotification` (rung
1), a second `IMDaemonListener` (rung 2), a message-layer swizzle (3), a UI-layer swizzle (4, a
defect to be replaced). Rungs 1 and 2 are dramatically less version-fragile, which is why this
subsystem needs a per-release sweep at all. See `docs/OBSERVATION_LADDER.md`.

## Step 7: write it down, then run the checks

```bash
Tools/private-api/compare-releases.py --matrix --markdown   # regenerates the §6 tables
swift test --filter BBPrivateAPICatalogTests
swift test --filter HelperTests
```

- `docs/MACOS_COMPATIBILITY.md` §2 gains a row for the release: build, how it was dumped, host
  app platform, absent-class count. §6 is generated, grouped by the `hosts.conf` group each
  class belongs to, so the document does not invent a second taxonomy that can drift from the
  first.
- The per-release page (`docs/SONOMA_COMPATIBILITY.md`, `docs/SEQUOIA_COMPATIBILITY.md`) gets
  the measured detail. Say **measured**, and say out of what.
- `docs/PRIVATE_API_SURFACE.md` gains any selector you had to hunt for.
- Commit the header dump itself. It is the evidence every later claim is checked against.

Then the five that decide whether a change is done: `swift build`, the strict build, the lint,
`python3 Tools/package-graph/check.py`, `swift test`.

## Troubleshooting

| Symptom | Cause |
|---|---|
| A class you just added came back with no header | The VM share holds a stale `hosts.conf`. Re-run `vm-share.sh` and dump again |
| Every class in one framework reports absent | That framework failed to load. The dump is invalid, not the release |
| The probe says a class is gone, the dump says it is there | The framework is not loaded in that host process. The dump wins |
| `compare-releases.py` reports `UNRESOLVED` for a selector we dispatch | No dumped class declares it. Either the class is missing from `hosts.conf`, or we are calling it on the wrong class |
| `CapabilityCatalogTests` fails on a minimum | The catalog and the dumps disagree. The dumps are the measurement; fix the catalog, or dump the release that would settle it |
| `ActionCoverageTests` fails after adding a helper action | Decide whether a user would recognise it: a catalog entry, or an exemption naming the action and giving a reason |
