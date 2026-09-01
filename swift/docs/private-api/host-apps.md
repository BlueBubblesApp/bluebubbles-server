# The host apps

What is known about the applications BlueBubbles injects into, and the rules that apply
inside them.

The Private API works by loading a library into an Apple application and calling its private
frameworks from inside. That library inherits everything about its host: its entitlements,
its sandbox, its filesystem view, and its process lifetime. Most of the surprises in this
part of the codebase come from that inheritance, so this page covers the host environment
first and the individual apps second.

Measured on **macOS 26.5.2 (25F84, arm64e)**. Reproduce any of it with the tools in
[`../../Tools/private-api/`](../../Tools/private-api/); see [Tool reference](tools.md).

## The hosts at a glance

| App | Bundle identifier | Binary | Injected today | What it is for |
|---|---|---|---|---|
| Messages | `com.apple.MobileSMS` | Mac Catalyst | yes | the whole iMessage Private API — IMCore |
| FaceTime | `com.apple.FaceTime` | Mac Catalyst | yes, behind a flag | calls — TelephonyUtilities |
| FindMy | `com.apple.findmy` | Mac Catalyst | no | people, items, devices |
| Notes | `com.apple.Notes` | native macOS | no | NotesShared, researched only |

All four are sandboxed (`com.apple.security.app-sandbox`) and all four have a container.
The Catalyst/native distinction is not cosmetic — it decides which copy of a framework the
process sees. See [macOS version notes § Two copies of
IMCore](macos-versions.md#two-copies-of-imcore).

Check any of it on the machine in front of you:

```bash
./Tools/private-api/dump-headers.sh --list
```

---

## The sandbox

Every one of these apps runs under the App Sandbox. Injected code is not exempt: it runs in
the host's process, so the kernel applies the host's sandbox profile to it. **The helper can
do exactly what the app can do, and nothing more.**

### Containers

A sandboxed app gets a *container* — a directory that stands in for the user's home
directory:

```
~/Library/Containers/com.apple.MobileSMS/Data/
├── Desktop/      Documents/     Downloads/
├── Library/      Movies/        Music/       Pictures/
└── tmp/
```

That layout is not decoration. Inside the app, path resolution is redirected there, so the
same call returns different answers depending on who makes it:

| Caller | `NSHomeDirectory()` |
|---|---|
| the server | `/Users/you` |
| the helper, inside Messages | `/Users/you/Library/Containers/com.apple.MobileSMS/Data` |

This has bitten the project directly. The server and the helper both derive the Private API
socket path, and they must derive the *same* one — but the server computed it from the real
home and the helper from the container, so the helper spent its life connecting to a path
that did not exist, retrying forever and reporting nothing. Both sides now go through
`getpwuid`, which is not redirected. See `SocketLocation.realHomeDirectory` in
[`Helper/BBPrivateAPIContract/SocketLocation.swift`](../../Helper/BBPrivateAPIContract/SocketLocation.swift).

### The container is not the whole story: entitlement exceptions

A container is the default, not the boundary. Apple's own apps carry
`temporary-exception` entitlements that open specific paths outside it. Messages, for
instance:

```
com.apple.security.temporary-exception.files.home-relative-path.read-write
    /Library/Messages/          ← chat.db lives here
    /Library/SMS/
    /Media/
    /Library/Caches/com.apple.MobileSMS/
```

This is why `~/Library/Messages/chat.db` is readable from inside Messages even though it sits
well outside the container. FindMy has the equivalent for `~/Library/Caches/`, which is where
its `fmipcore` caches live.

The practical rule: **a path is reachable from inside the app only if it is in the container
or named in an exception.** An arbitrary file in the user's home directory is neither.

Read the list for any app with:

```bash
codesign -d --entitlements - --xml /System/Applications/Messages.app \
  | plutil -convert xml1 -o - -
```

### Files must be copied into the container

This is the rule with the most consequences, and it fails silently.

When the Private API is asked to send an attachment, set a group icon, or set a chat
background, the caller hands over a path. If that path is outside the container, **the
sandbox denies the read and nothing reports an error.** Measured, sending
`~/Documents/profile-pic.jpg`:

```
transfer created, GUID issued, localPath assigned
existsAtLocalPath = 0   totalBytes = 0   isFileURLFinalized = 0
message sent, no error, cache_has_attachments = 0, no attachment row
```

`mediaObjectWithFileURL:filename:transcoderUserInfo:` allocates the transfer and works out
where the bytes belong; when the read is denied it copies nothing and returns normally. The
send then names a transfer with no bytes behind it, and imagent — correctly — attaches
nothing. Every layer succeeds and the attachment disappears.

The fix is to copy the file into the container **before** the helper is asked for it, which
is what [`Sources/BBPrivateAPI/AttachmentStaging.swift`](../../Sources/BBPrivateAPI/AttachmentStaging.swift)
does:

```
~/Library/Containers/com.apple.MobileSMS/Data/tmp/BlueBubbles/Outgoing/<uuid>/<filename>
```

Three details in that design worth carrying to any new file-passing feature:

- **The server stages, not the helper.** The server has Full Disk Access — it needs it for
  `chat.db` and for writing the socket — and the helper does not. Copying server-side turns
  the helper's read into a container-to-container one, which the sandbox permits.
- **The filename is preserved, only the directory is randomised.** The filename becomes the
  attachment's name in the conversation.
- **Staged copies are swept by age (one hour), not deleted after each send.** The daemon may
  still be reading the file when the send call returns.

Anything new that hands a path across this boundary — a chat background, a contact photo —
needs the same treatment. It is not optional and the failure gives no signal.

### The socket has to live in the container too

The Private API transport is a Unix domain socket, and the sandbox refuses a `connect` to one
**outside** the container. Measured from a probe inside Messages:

```
~/Library/Application Support/BlueBubbles/…   EPERM
/tmp/…                                        EPERM
<Messages container>/private-api.sock         CONNECTED
```

This was originally read as "the sandbox refuses Unix sockets", and the server fell back to a
loopback TCP bridge — which works, and which cannot identify its peer, so any local process
could drive the Private API. Inside the container it connects *and* the connection carries
`LOCAL_PEERTOKEN`, so the server can verify by audit token that the peer really is Messages.

The restriction is **symmetric**, which is why there is one socket per app rather than one
socket with per-process routing:

```
socket in Messages' container    Messages connects; FaceTime never does
socket in FaceTime's container   FaceTime connects; Messages registers, then drops
```

A shared socket looked like it worked and left whichever app did not own the container
silently absent, with every untargeted action answered by the wrong helper.

One consequence worth stating: the server writes into another application's container, which
requires Full Disk Access. It already needs FDA for `chat.db`, so this is not a new prompt —
but the Private API now depends on it where it did not before.

`sun_path` is a fixed 104-byte field and an over-long path is **truncated rather than
rejected**, so the server would bind one path and the helper connect to another with no error
on either side. `SocketLocation.maximumSocketPathLength` checks for this explicitly. Measured
lengths, against the 103-byte limit:

```
79  ~/Library/Containers/com.apple.MobileSMS/Data/private-api.sock
78  ~/Library/Containers/com.apple.FaceTime/Data/private-api.sock
76  ~/Library/Containers/com.apple.findmy/Data/private-api.sock
75  ~/Library/Containers/com.apple.Notes/Data/private-api.sock
```

A long username or a network home eats the ~25 bytes of headroom.

### Group containers

Apps also reach shared *group* containers at `~/Library/Group Containers/<group-id>/`. These
matter because some of the interesting data lives there rather than in the app container:

| App | Group containers | Notable contents |
|---|---|---|
| Messages | `group.com.apple.ManagedSettings`, `group.com.apple.Photos.PhotosFileProvider`, … | — |
| FindMy | `group.com.apple.icloud.fmipcore`, `group.com.apple.icloud.fmfcore`, `group.com.apple.icloud.fm` | FindMy state |
| Notes | `group.com.apple.notes` | `NoteStore.sqlite` — the entire Notes database |

---

## Injection

Mechanically the same for every host, and implemented once in
[`Sources/BBPrivateAPI/DylibInjector.swift`](../../Sources/BBPrivateAPI/DylibInjector.swift).

**It is a relaunch, not an attach.** The injector terminates the app and starts it again with
`DYLD_INSERT_LIBRARIES` pointing at the helper dylib. There is no path that attaches to a
running process, which also means a host app that is *not* running is not a special case —
`terminate` returns immediately when nothing matches, and the launch proceeds identically.

Four things that must hold, each of which fails quietly if it does not:

- **System Integrity Protection must be off.** Library validation otherwise refuses to load
  an unsigned dylib into a signed Apple application. This is the entire reason the Private
  API is opt-in.
- **Architectures must overlap.** On Apple Silicon the app runs its `arm64e` slice, and an
  `arm64` dylib cannot load into an `arm64e` process. dyld reports this **only on stderr**,
  so the app starts looking perfectly healthy with no helper inside it. `DylibInjector.verify()`
  checks with `lipo -archs` before quitting anything.
- **The app must actually be found.** `parentApplicationMissing` usually means the server
  lacks Full Disk Access.
- **The helper must register.** The app launching proves nothing — when dyld declines an
  inserted library it carries on without it. The only positive proof is the helper's `ping`
  arriving on the socket, and `PrivateAPIRuntime` waits for a registration *newer* than the
  one it started with, because "is something connected?" cannot answer "did the injection I
  just performed work?".

Each host is injected independently: its own dylib, its own socket, its own success or
failure. Messages failing is fatal to the Private API; FaceTime failing is not, and is raised
as an alert instead.

Two rules bind the code that runs at load time, in `HelperMain` and `FaceTimeHelperMain`:

1. **Never block.** The constructor runs before the app has finished launching. Connect on a
   background thread and return.
2. **Never throw out of the constructor.** An uncaught error there takes the host app down
   and the user has no idea why.

There is no supervision. If the user quits Messages, the helper dies with it, the service
reports `degraded(reason: "no helper connected")`, and Private-API routes refuse — but
nothing re-injects until the restart endpoint is called or the server restarts.

---

## Messages.app

The main host, and the only one whose Private API is fully wired.

**Catalyst.** It links `/System/iOSSupport/…/IMCore` and `/System/iOSSupport/…/ChatKit`, and
there is no `ChatKit.framework` under `/System/Library/PrivateFrameworks` at all — it exists
only in the iOSSupport tree. So ChatKit is in Messages' address space and answers
`NSClassFromString` from an injected helper with no `dlopen`, which is easy to miss because a
naive check for it outside a Catalyst process reports it absent.

Frameworks that matter: **IMCore** (chats, messages, accounts, and `IMFMFSession` for FindMy),
**IMSharedUtilities** (`IMMutedChatList`, `IMNickname`, feature flags), **ChatKit** (UI; holds
almost no state that is not already in IMCore or `chat.db`).

`~/Library/Messages/chat.db` is reachable from inside the sandbox via the
`temporary-exception` above, and is also what the server reads directly with Full Disk
Access. Most read paths do not need the helper at all.

What the Private API surface looks like in detail — chat backgrounds, mute, read receipts,
scheduled messages — is in [`../PRIVATE_API_SURFACE.md`](../PRIVATE_API_SURFACE.md) Part I.

## FaceTime.app

**Catalyst**, injected behind a feature flag, with its own dylib and its own socket.

Its frameworks come from **TelephonyUtilities** (`TUCallCenter`, `TUCall`, `TUConversation`,
`TUDialRequest`), and that framework has **no iOSSupport copy** — so both dumper builds report
the same thing for `TU*`, and the Catalyst/native question does not arise here.

Naming drift worth knowing: the older Objective-C helper's headers describe
`TUConversationJoinRequest` and a family of `CSD*` classes. On 26.5.2 those are renamed or
gone; the current names are `TUJoinConversationRequest` and `TUDialRequest`. This is exactly
the kind of rename a runtime dump surfaces and a stale header hides.

The separate dylib exists because each helper is its own binary loaded into its own process.
They are told apart by the bundle identifier in the registration handshake.

## FindMy.app

**Catalyst**, not injected today. Researched in full; the conclusion is that it is worth a
helper only for AirTags.

Its interest is entitlements, and the surprise is how few of them are unique. Messages holds
**all four** findmylocate services — `locationservice`, `friendshipservice`, `fenceservice`,
`settings` — exactly as FindMy does. What FindMy has and Messages does not is the
`searchpartyd` family (`ownersession`, `beaconmanager`, `securelocations`, `beaconsharing`,
`pairingmanager`) and `findmydeviced.access`.

Two structural facts shape everything else:

- **Large parts of it are pure Swift.** `FMIPCore.FMIPManager`, `FMFCore.FMFManager`,
  `FindMyLocate.Session` and the whole `FMIP*Action` family expose *nothing* to the
  Objective-C runtime. `class_copyMethodList` returns zero, so no selector-based approach
  reaches them from any host. Check with
  `./probe.sh --host FindMy members FMIPCore.FMIPManager`.
- **The on-disk caches are encrypted.** Since macOS 15, `~/Library/Caches/com.apple.findmy.fmipcore/*.data`
  are binary plists wrapping `encryptedData` and `signature`, not the plaintext JSON they
  used to be. The repository already gates on this (`FindMy.cacheIsEncrypted`).

The reachable Objective-C layers are `FMF.framework` (whose `FMFSession` turns out to be a
dead XPC client — its daemon endpoint no longer exists), `SPOwner.framework` (AirTags, and
genuinely useful), and `FindMyDevice.framework` (this Mac's own Find My Mac configuration,
including `eraseAllContentAndSettings…`, which should never be wired to a route). The full
analysis is [`../PRIVATE_API_SURFACE.md`](../PRIVATE_API_SURFACE.md) § 7.

## Notes.app

**Native macOS** (platform 1) — the only host here that is not Catalyst, and therefore the
only one dumped with the macOS build of the tools.

`NotesShared.framework` is a complete Core Data stack and is entirely Objective-C, unlike
FindMy's controllers: `ICNoteContext.sharedContext` → `managedObjectContext` → `save`, with
`ICNote` (310 methods), `ICFolder`, `ICAccount`, `ICAttachment`.

The database is at `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite` and is
readable with Full Disk Access, but note bodies are stored as opaque compressed blobs; the
argument for a helper is that `ICNote.attributedString` decodes them in-process. Not built;
see [`../PRIVATE_API_SURFACE.md`](../PRIVATE_API_SURFACE.md) § 8.

---

## Checking any of this yourself

```bash
# Platform, per host app
./Tools/private-api/dump-headers.sh --list

# Entitlements
codesign -d --entitlements - --xml /System/Applications/Messages.app | plutil -convert xml1 -o - -

# Container layout
ls ~/Library/Containers/com.apple.MobileSMS/Data/

# Is a class reachable, or is it pure Swift?
./Tools/private-api/probe.sh --host FindMy members FMIPCore.FMIPManager FMFSession
```

## See also

- [`../PRIVATE_API_SURFACE.md`](../PRIVATE_API_SURFACE.md) — what the frameworks actually
  expose, per feature
- [`../OBSERVATION_LADDER.md`](../OBSERVATION_LADDER.md) — how events are observed, and the
  order to try approaches in
- [macOS version notes](macos-versions.md) — what differs between releases
- [`Helper/BBPrivateAPIContract/SocketLocation.swift`](../../Helper/BBPrivateAPIContract/SocketLocation.swift)
  — the socket rules, with the measurements that produced them
