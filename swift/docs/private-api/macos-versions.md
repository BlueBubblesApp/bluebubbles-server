# macOS version notes

What differs between releases, what the tools do about it, and what to check when a dump from
one release does not look like a dump from another.

**Measured on macOS 26.5.2 (25F84, arm64e) unless a line says otherwise.** Rows marked
*unverified* are inferred from Apple's documented behaviour or from this repository's
existing version gates, not measured on a machine running that release. Producing a dump on
one of those releases settles it — see [Collecting headers](collecting-headers.md).

## Supported range

| macOS | Name | Status |
|---|---|---|
| 26 | Tahoe | measured; the release this project develops against |
| 15 | Sequoia | *unverified* — expected to work |
| 14 | Sonoma | *unverified* — the floor the tools allow |
| 13 and older | Ventura ↓ | refused; override with `PA_ALLOW_OLD_MACOS=1` |

The floor is a judgement, not a technical limit. The tools may well run further back. It is
set because a header dumped on a release nobody has examined can be read as authoritative,
and that is exactly the failure this whole directory exists to prevent. If it is overridden, note that
alongside the resulting dump so the output is not later read as validated.

Note the numbering jump: **there is no macOS 16 to 25.** Apple went from 15 (Sequoia) to 26
(Tahoe). Version comparisons must be `>= 26`, never `> 15 && < 17`.

## Two copies of IMCore

The single most important thing to understand here, and the reason `dump-headers.sh` builds
itself twice.

Messages.app is a **Mac Catalyst** app:

```
$ otool -L /System/Applications/Messages.app/Contents/MacOS/Messages
    /System/iOSSupport/System/Library/PrivateFrameworks/ChatKit.framework/…/ChatKit
    /System/iOSSupport/System/Library/PrivateFrameworks/IMCore.framework/…/IMCore
```

Several private frameworks ship **twice** — once under `/System/Library/PrivateFrameworks`
for native macOS apps, once under `/System/iOSSupport/…` for Catalyst apps — and the two
copies are not the same binary. On 26.5.2, `IMChat` has 932 instance methods in the macOS
copy and 936 in the iOSSupport copy:

| Only in the macOS copy | Only in the iOSSupport copy |
|---|---|
| `-dateCreated`, `-dateModified` | the `momentShare*` family |
| `-chatItemsForMessages:` | the `subscriptionSwitchParticipantAdd*` family |
| `-setOverallChatStatus:` | `+_NPSManagerClass` |

`-dateCreated` and `-dateModified` are the sharp edge: they look available in a macOS-built
dump and **do not exist in the IMCore that Messages actually runs**.

### Which copy you get is decided by the process, not the path

This is the opposite of what most people assume, so it is worth stating plainly:

- A **Catalyst** process that opens `/System/Library/…/IMCore.framework/IMCore` is
  **redirected** to the iOSSupport copy.
- A **native macOS** process cannot open the iOSSupport path at all — `dlopen` fails with
  *"wrong platform to load into process"*.

You cannot load both into one process, and you cannot get the wrong one from the right
build. So the knob is the **compiler target**, which is why `lib.sh` has:

```bash
clang -target "$(uname -m)-apple-ios13.1-macabi" -isysroot "$(xcrun --sdk macosx --show-sdk-path)" …
```

`dump-headers.sh` reads each host app's Mach-O `LC_BUILD_VERSION` (platform 1 = macOS,
6 = MACCATALYST) and builds the dumper to match. Run `--list` to see what it decided.

Every emitted header records its source on an `// Image:` line, so which copy answered is
checkable after the fact rather than assumed:

```objc
// Image: /System/iOSSupport/System/Library/PrivateFrameworks/IMCore.framework/Versions/A/IMCore
```

### On other releases

Messages has been Catalyst since Big Sur (11), so Sonoma and Sequoia are expected to behave
the same way — *unverified*. Detection is automatic either way. `--list` reporting `macos`
for Messages on any release would be a genuine finding and worth recording.

Not every app is Catalyst. On 26.5.2, Messages, FaceTime and FindMy are; **Notes is a native
macOS app** (platform 1) and gets the macOS dumper. TelephonyUtilities, which FaceTime uses,
has no iOSSupport copy at all, so both dumpers report the same thing for `TU*`.

## Toolchain

The Catalyst build needs a macOS SDK that includes `/System/iOSSupport`. Xcode always has
one; the Command Line Tools alone are sometimes enough and sometimes not, and the failure
message is unhelpful. If `pa_compile` reports it cannot build for Catalyst:

```bash
sudo xcode-select -s /Applications/Xcode.app
```

The Catalyst deployment target is pinned to **iOS 13.1** — the first version Catalyst ever
supported, and therefore the one every Catalyst-capable clang accepts. Naming something
recent builds fine on a current Xcode and fails on an older one for no benefit: the
deployment target has no effect on what the Objective-C runtime reports, which is all these
tools read.

`/bin/bash` on macOS is **bash 3.2** and has been since 2007. Every script here has to run
under it, so there is no `mapfile`, no `declare -A`, and no `${var^^}` anywhere in this
directory.

## Where the shared cache lives

`notifications.sh` greps the dyld shared cache, because private frameworks have no binary on
disk — they exist only inside it. Its location has moved:

| Release | Path |
|---|---|
| 26 | `/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/` — `/System/Library/dyld` is empty |
| 13–15 | Cryptex path exists; `/System/Library/dyld/` may also be populated (*unverified*) |
| 12 and older | `/System/Library/dyld/` |

`pa_shared_cache_files` checks all three roots and both the Cryptex and legacy layouts, then
picks the files matching this machine's architecture — `arm64e` on Apple Silicon, `x86_64h`
on Intel. The cache is split across numbered files (`.01`, `.02`, …) and a given string may
be in any of them, so all are searched; `.map` and `.atlas` are indexes and are skipped.

## Architecture

`uname -m` decides both the clang target and which shared cache is read. Both Intel and
Apple Silicon dumps are useful and they are **not interchangeable** — Apple has shipped
different code to each before.

One trap: running these tools under Rosetta on an Apple Silicon Mac makes `uname -m` report
`x86_64`, and you will get a real, correct dump of the x86_64 world — which is not what that
Mac runs. Use a native terminal.

## Changes we know about

Confirmed differences worth knowing when a dump from an older release looks wrong:

| Change | Release | Evidence |
|---|---|---|
| FindMy caches encrypted — `~/Library/Caches/com.apple.findmy.fmipcore/*.data` became binary plists wrapping `encryptedData`, no longer plaintext JSON | 15 (Sequoia) | this repo already gates on it: `FindMy.cacheIsEncrypted` in `BBSystem/FindMy.swift` |
| `FMFSession`, `FMFSessionDataManager`, `FMFHandle`, `FMFLocation` absent from IMCore; `IMFindMyHandle` / `IMFindMyLocation` / `IMFindMyDevice` are the current types | by 26 | [`../headers/README.md`](../headers/README.md) |
| `com.apple.icloud.fmfd` no longer vended by any launchd job, making `FMFSession` a dead XPC client | by 26 | [`../PRIVATE_API_SURFACE.md`](../PRIVATE_API_SURFACE.md) § 7 |
| Chat backgrounds (`-[IMChat setTranscriptBackgroundAndSendToChat:transferID:]` and friends) | 26 | *unverified* — expected absent on 14 and 15 |

That last row is a good example of what a dump settles in seconds. If `IMChat.h` for a
release has no `transcriptBackground` methods, the feature is genuinely unavailable there,
and the server should report that rather than fail at runtime.

## When a class is missing

It is recorded, not skipped:

```objc
// IMMutedChatList is NOT PRESENT on this system.
```

Three possibilities, in the order worth checking:

1. **The framework holding it was never loaded.** A class in a framework nothing opened
   reads exactly like one Apple removed. Check the `load` lines for that group in
   `hosts.conf`, and look for `warning: could not load …` in the output.
2. **It moved.** Apple relocates classes between frameworks. Find it with
   `./probe.sh --host <group> classes <PartOfTheName>` and add the framework it turned up in.
3. **It is genuinely gone.** That is the answer, and it is worth checking in.

The reverse also happens, and matters just as much: a class present on an older release and
absent on a newer one is a feature that will break on upgrade.

## Adding a new release

```bash
./Tools/private-api/collect.sh --keep    # writes docs/headers/macos-<version>/ too
git add swift/docs/headers/macos-<version>
```

Then read the diff, because it is the actual deliverable:

```bash
diff -r swift/docs/headers/macos-15.6.1 swift/docs/headers/macos-26.5.2
```

Commit the whole directory, `environment.txt` included — it records which machine and
toolchain produced the dump, which is what makes the headers interpretable later.
