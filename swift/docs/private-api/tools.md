# Tool reference

Everything lives in [`swift/Tools/private-api/`](../../Tools/private-api/). Run the scripts
from anywhere; they locate the repository themselves.

```
lib.sh             shared plumbing — sourced, never run
hosts.conf         what to dump, and out of which process
dump-headers.m     the header emitter
dump-headers.sh    driver: reads hosts.conf, builds, dumps
probe.m            runtime search
probe.sh           driver for probe.m
trace.py           lldb commands: sels, consts
trace.sh           driver for trace.py
notifications.sh   NSNotification names out of the dyld shared cache
collect.sh         everything, packaged for sending back
```

All five scripts take `--help`. All five are read-only.

---

## dump-headers.sh

Writes `docs/headers/macos-<version>/` from the classes on this Mac. This is the one other
people run.

```bash
./dump-headers.sh                    # every group in hosts.conf
./dump-headers.sh Messages           # only groups whose name starts with "Messages"
./dump-headers.sh --list             # what would run, and on which platform
./dump-headers.sh --out /tmp/x       # somewhere other than docs/headers/
./dump-headers.sh --quiet            # warnings and errors only
```

`--list` first, always — it shows the decision that matters most:

```
$ ./dump-headers.sh --list
Messages chat          catalyst  4   classes  detected from Messages.app
Messages findmy        catalyst  11  classes  detected from Messages.app
FaceTime               catalyst  16  classes  detected from FaceTime.app
FindMy                 catalyst  21  classes  detected from FindMy.app
Notes                  macos     11  classes  detected from Notes.app
```

That `catalyst`/`macos` column is read out of each app's Mach-O header, not assumed. It
decides which **copy** of a shared framework gets dumped, and getting it wrong produces a
header that looks perfectly reasonable and describes a different binary from the one
Messages actually runs. See [macOS version notes § Two copies of
IMCore](macos-versions.md#two-copies-of-imcore).

A class that does not exist on this release is recorded, not skipped:

```objc
// IMMutedChatList is NOT PRESENT on this system.
```

That line is the point of the exercise. `collect.sh` gathers them into a summary.

### Adding a class

Edit `hosts.conf`. No shell involved:

```
group Messages chat
app      com.apple.MobileSMS
platform catalyst
load     @ios/IMCore.framework/IMCore
class    IMChat
class    IMChatRegistry
protocol IMDaemonListenerProtocol
```

`@ios/` expands to `/System/iOSSupport/System/Library/PrivateFrameworks/`, `@sys/` to
`/System/Library/PrivateFrameworks/`. The `app` line is what platform detection keys off;
`platform` is only used when that app is not installed.

Dump wide rather than narrow. A name that turns out to be absent costs one file and answers
a question permanently.

---

## probe.sh

Searches every class the runtime can see. This is what you use *before* you know which
class to dump.

```bash
# Does anything, anywhere, know this word?
./probe.sh --host Messages selectors wallpaper background

# What classes does a framework contain?
./probe.sh --host Messages classes ChatKit

# How much Objective-C surface does a class actually have?
./probe.sh --host FindMy members FMIPCore.FMIPManager FMFSession SPOwnerSession

# Which @objc protocols are around? (NSXPCInterface needs one)
./probe.sh --host FindMy protocols fence friendship
```

Options: `--host <group or bundle id>` loads the frameworks a `hosts.conf` group uses and
matches that app's platform; `--load <path>` adds one framework; `--platform macos|catalyst`
overrides. Default platform is `catalyst`, because a native macOS process cannot open
anything under `/System/iOSSupport` at all.

Output is tab-separated — `image`, `class`, `selector` — so it pipes:

```bash
./probe.sh --host Messages selectors transcriptbackground | cut -f2 | sort -u
```

### `members`: checking for pure-Swift classes

```
$ ./probe.sh --host FindMy members FMIPCore.FMIPManager FMFSession FindMyLocate.Session
class                 instance  class_methods  properties  image
FMIPCore.FMIPManager  0         0              0           FMIPCore
FMFSession            168       4              19          FMF
FindMyLocate.Session  0         0              0           FindMyLocate
```

A `0 0 0` row is a **pure Swift class**. The name resolves, `NSClassFromString` succeeds,
and the runtime will dispatch nothing — so no selector-based approach will ever reach it,
and header-dumping it emits an empty `@interface` that reads as "exists, has no API". Check
this before building on anything. Large parts of FindMy are behind that wall; see
[`../PRIVATE_API_SURFACE.md`](../PRIVATE_API_SURFACE.md) § 7.

---

## trace.sh

Reads what a method does, by disassembling it and resolving each `objc_msgSend$foo` stub
back to a selector name. Read-only: lldb stops at `main` in a stub process and disassembles.
No Apple code is executed.

```bash
# What does this method actually call?
./trace.sh --host Messages IMChat setTranscriptBackgroundAndSendToChat:transferID:

# What string constants does it use?
./trace.sh --host Messages --consts IMChat transcriptBackgroundPath

# Class methods take a + prefix
./trace.sh --host FindMy +FMFSession sharedInstance
```

The first turns two anonymous `id` arguments into a documented call:

```
+48    msgSend "chatRegistry"
+76    msgSend "_chat:setTranscriptBackgroundAndSendToChat:transferID:"
```

…and following that one level further down showed the first argument being passed to
`+[NSURL URLWithString:]` — so it is a URL *string*, which no header could have told you.

The second recovers key names:

```
$ ./trace.sh --host Messages --consts IMChat transcriptBackgroundPath
+40    const "trabaid"
```

`trabaid` is the key under which a chat's background asset id is stored in `chat.properties`.
That is how the whole chat-background feature was mapped.

Options: `--consts` switches modes, `--limit <n>` walks further (default 400 instructions),
`--host` / `--load` / `--platform` as for `probe.sh`.

Both commands stop at the first unconditional branch, because these methods usually tail-call
rather than return — without that they run into whatever function was linked next and print a
plausible, wrong call graph.

To use the commands inside an interactive lldb session, load `trace.py` yourself:

```
(lldb) command script import /path/to/swift/Tools/private-api/trace.py
(lldb) sels IMChat setDisplayName:
(lldb) consts IMChat _supportsTranscriptBackgrounds 60
```

---

## notifications.sh

Lists the `NSNotification` names a framework posts — the rung-1 events, the cheapest and
most durable way to observe something. See [`../OBSERVATION_LADDER.md`](../OBSERVATION_LADDER.md).

```bash
./notifications.sh                      # every __kIM*Notification name
./notifications.sh chat mute            # filtered
./notifications.sh --pattern '__kFM[A-Za-z]*Notification'
```

```
$ ./notifications.sh transcriptbackground muted pinned
__kIMChatTranscriptBackgroundChangedNotification
__kIMMutedChatListDidChangeNotification
__kIMPinnedConversationsDidChangeNotification
```

It greps the dyld shared cache, which looks crude and is correct. These names are
`@"__kIMChatFooNotification"` **string literals** in `__cstring`, not exported symbols —
`dlsym` reports them absent, and that false negative has been believed in this project more
than once. Private frameworks have no on-disk binary either; they exist only in the cache.

---

## collect.sh

`dump-headers.sh`, plus a description of this Mac, packaged as a `.tar.gz`.

```bash
./collect.sh                  # archive onto the Desktop
./collect.sh --out /tmp       # elsewhere
./collect.sh --keep           # also write into docs/headers/macos-<version>/
```

Use `--keep` on your own machine when you are updating the checked-in headers.
See [Collecting headers](collecting-headers.md) for the contributor-facing version.

---

## lib.sh

Sourced by all of them. Worth knowing about because everything portable lives here:
architecture detection, host-app platform detection, locating the dyld shared cache across
releases, the Catalyst/macOS build helpers, and the single `hosts.conf` parser.

Two constraints it exists to hold:

- **Everything runs on `/bin/bash`, which is bash 3.2.** macOS has shipped that version
  since 2007 and contributors will not have installed a newer one. No `mapfile`, no
  `declare -A`, no `${var^^}`.
- **Nothing is hardcoded that could differ on someone else's Mac** — not the CPU
  architecture, not whether an app is Catalyst, not where the shared cache lives.
