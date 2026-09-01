# Private API tooling

BlueBubbles reaches features Apple never made public — reactions, editing, typing
indicators, group management — by loading a small library inside Messages.app and calling
IMCore directly. IMCore is private, which means it is undocumented, and it changes between
macOS releases with no notice and no changelog.

These tools answer the questions that come up because of that:

- *Does this class still exist on macOS 26?* → [`dump-headers.sh`](tools.md#dump-headerssh)
- *Does anything, anywhere, know the word "wallpaper"?* → [`probe.sh`](tools.md#probesh)
- *What does this method actually do?* → [`trace.sh`](tools.md#tracesh)
- *How do I hear about it when it changes?* → [`notifications.sh`](tools.md#notificationssh)
- *Why did that file silently fail to send?* → [The host apps](host-apps.md#files-must-be-copied-into-the-container)
- *What broke between Sonoma and Tahoe?* → the diff between two `docs/headers/macos-*/`
  directories

## Start here

| Goal | Page |
|---|---|
| produce a header dump for a macOS release | [Collecting headers](collecting-headers.md) |
| understand the apps we inject into, and their sandbox | [The host apps](host-apps.md) |
| look up a flag or a worked example | [Tool reference](tools.md) |
| find what differs across macOS releases | [macOS version notes](macos-versions.md) |
| read what has been found with these tools | [`../PRIVATE_API_SURFACE.md`](../PRIVATE_API_SURFACE.md) |
| understand how events are observed | [`../OBSERVATION_LADDER.md`](../OBSERVATION_LADDER.md) |

New to this? [Collecting headers § Background](collecting-headers.md#background) explains
what a class dump is and why the Objective-C runtime can be queried at all.

The tools themselves are in [`../../Tools/private-api/`](../../Tools/private-api/).

## Why the tools read the live runtime

**A header that disagrees with the running system is worse than no header**, because it gets
treated as authoritative.

This project has been bitten by that repeatedly. Headers carried over from an iOS 16 SDK
described `FMFSessionDataManager` as the way to observe FindMy; on macOS 26 that class is
not in IMCore at all, so the shipping Objective-C helper simply stopped delivering location
events and reported nothing. A probe looked for it, did not find it, and concluded FindMy
was unreachable from Messages — which was also wrong.

So everything here reads the **live Objective-C runtime** on the machine it runs on.
`class_copyMethodList` reports what the runtime will actually dispatch; there is no fidelity
lost against parsing a binary, and nothing has to be extracted from the shared cache. The
output is checked in, one directory per macOS release, and **the diff between two of those
directories is the deliverable** — it is the answer to "what did Apple move this time",
which is the question that costs the most time when a Private API feature breaks.

## Safety

Nothing here needs System Integrity Protection disabled, and nothing here needs Full Disk
Access. The tools load Apple's frameworks into their own short-lived process and read type
information out of the runtime. `trace.sh` disassembles under lldb without ever calling the
code it is reading.

They do not open the Messages database, notes, contacts, or location data, and they emit no
file contents of any kind. See
[Collecting headers § What the archive contains](collecting-headers.md#what-the-archive-contains)
for the exact contents of a dump.
