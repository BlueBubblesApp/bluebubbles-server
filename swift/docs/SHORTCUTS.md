# Group chat creation through Shortcuts

How the BlueBubbles server creates group chats on a Mac without the Private API, why no other
mechanism is available, and what was measured to establish that.

All measurements in this document were taken on **macOS 26.5.2 (build 25F84)** unless a different
version is named. Statements about earlier releases come from the Node server this port replaces,
which shipped against them.

---

## Why a Shortcut is involved at all

Creating a chat is one of the operations a server without the Private API cannot perform through
AppleScript. This is not a recent regression and it is not specific to Tahoe.

### AppleScript cannot create a group chat on any supported macOS

The Node server states the limitation outright and refuses the call before attempting it:

```js
// packages/server/src/server/api/interfaces/chatInterface.ts
if (method == 'apple-script' && isMinBigSur && addresses.length > 1) {
    throw new Error("Cannot create group chats on macOS Big Sur or newer!");
}
```

`isMinBigSur` is `macosVersion.isGreaterThanOrEqualTo("11.0")`. Big Sur is macOS 11; the Swift
package's deployment floor is macOS 14. Group creation through AppleScript is therefore
unavailable on **every** version this server supports — Sonoma, Sequoia and Tahoe alike. There is
no version to gate on.

The same file records what the Node server does instead for a one-to-one chat:

```js
// Since chat creation doesn't work on Big Sur+, we just need to send the message to an
// "infered" Chat GUID based on the service and first (only) address
```

### The Messages scripting dictionary confirms it

`make new chat` was exercised directly. Every form fails:

| Attempt | Result |
|---|---|
| `make new chat with properties {participants:{p1,p2}}` | `-1700`, cannot coerce a list to `participant` |
| `make new chat with properties {participants:p1}` | `-10000`, AppleEvent handler failed |
| `make new chat` — **no properties at all** | **`-10000`** |
| `make new chat at end of chats` | `-1700` |
| `make new chat at end of chats of <account>` | `-1700` |
| `make new chat with data {p1,p2}` | `-10000` |
| `make new text chat` (pre-Big-Sur spelling) | `-1728`, the class no longer exists |
| JXA `Application('Messages').Chat({...})` then `chats.push()` | `-10000` |
| `make new participant with properties {handle:…}` | `-10000` |
| `send "text" to {p1, p2}` | `-1700`, the `to` parameter is singular |

The `make new chat` case with **no properties** is the decisive one: it fails before participant
handling is reached, so no argument spelling can affect the outcome.

`/System/Applications/Messages.app/Contents/Resources/Messages.sdef` agrees. Every `chat` element
is declared `access="r"`, and the `chat` class declares no `responds-to` entry for `make`. The
participant element's description — `"This property may be specified at time of creation"` — is
text left over from iChat and does not correspond to a working handler.

### Compiled scripts do not change this

The Swift port replaced `osascript` shell-outs with compiled `NSAppleScript` invoked through Apple
Event parameters. That change removes the escaping layer around user-supplied values. It has no
bearing on chat creation: the handler Messages exposes is a stub, and the calling convention does
not alter what the target application implements.

### One-to-one chats are a different case

A direct chat still works without the Private API, because nothing is created explicitly. Sending
to a participant that has no existing conversation causes Messages to open one. That is
`bbSendToParticipant` in `Sources/BBAppleScript/MessagesScripts.swift`, and it needs no install and
no additional permission beyond the Automation grant that sending already requires.

---

## What Shortcuts provides

`is.workflow.actions.sendmessage` is the **only** messaging action available on the system.
Establishing that involved two enumerations:

- All 402 `is.workflow.actions.*` identifiers present in the dyld shared cache
  (`dyld_shared_cache_arm64e.01`, `.05`, `.09`). The only matches for messaging vocabulary are
  `is.workflow.actions.sendmessage` and `is.workflow.actions.text.match.getgroup`, the latter
  being a regular-expression action unrelated to chats.
- All 571 `Metadata.appintents` bundles under `/System`. Messages contributes exactly one App
  Intent, `ConversationListFocusFilterAction`, which is a Focus filter.

There is no action for renaming a chat, adding or removing a participant, leaving a chat, or
sending a tapback. **This mechanism closes one capability gap and is not a general substitute for
the Private API.**

### Recipient resolution behaviour

Sending to two or more recipients resolves the participant set to an existing conversation when
one exists, and creates a group chat when one does not. Observed across six distinct participant
sets:

| Recipients | Outcome |
|---|---|
| `A + B` | reused an existing group |
| `A + C` | reused an existing group |
| `B + C` | **created** a new group |
| `A + D + C` | reused an existing group |
| `D + A` | **created** a new group |
| Repeat of `D + A` | reused the group just created; chat count unchanged |

Matching is on the participant set, not on ordering.

---

## The workflow

The shortcut is generated in Swift (`Sources/BBShortcuts/GroupChatShortcut.swift`), signed with
`shortcuts sign --mode anyone`, and handed to the Shortcuts app for the user to confirm. It is not
a checked-in binary, so its definition is reviewable in a diff.

Its input is a JSON object supplied through `shortcuts run -i`:

```json
{"recipients": "first@example.com\nsecond@example.com", "message": "text"}
```

Three actions:

1. `is.workflow.actions.getvalueforkey`, key `recipients`
2. `is.workflow.actions.getvalueforkey`, key `message`
3. `is.workflow.actions.sendmessage`, reading both lookups

### Three serialization rules, each established by measurement

**1. There is no "Get Dictionary from Input" step, and adding one breaks the workflow.**

`is.workflow.actions.detect.dictionary` produces an empty result. Both documented input forms were
tested — the shortcut input as a `WFTextTokenString` and as a `WFTextTokenAttachment` — and a
diagnostic workflow returned an empty value for each. `is.workflow.actions.getvalueforkey` reads a
key directly from the shortcut input with no conversion step, which was verified end to end.

**2. The input crosses into `getvalueforkey` as `WFTextTokenAttachment`.**

A `WFTextTokenString` coerces the payload to text, after which the action fails with *"Get
Dictionary Value failed because Shortcuts couldn't convert from Text to Dictionary."* The
attachment form matches Apple's own authored workflows; `GetStartedWithModels.wflow` in
`WorkflowKit.framework/Resources/Gallery.bundle` is a reference example that uses `WFDictionaryKey`
with a `WFTextTokenAttachment` input.

**3. Recipients are delivered as multi-line text.**

Newline-separated addresses in a text parameter resolve to several participants. This was the
first form proven to work and is retained for that reason.

### The failure mode these rules prevent

When a send action's parameters resolve to nothing, Shortcuts does not report an error. It
**prompts the user** for a recipient and a message body, then exits `0` having sent a real message
to whatever was typed. From outside the process this is indistinguishable from success: the exit
code is zero, a message row appears in `chat.db`, and `is_sent` is `1`.

This occurred twice during development. In both cases the recipient and body in the database were
values a human had typed into a dialog, not the values the server supplied. `Tests/BBShortcutsTests`
asserts the serialization types and the action wiring for this reason — the mistake is invisible at
every layer below the workflow definition.

---

## Operational constraints

### Installation and removal are user gestures

The `shortcuts` CLI provides `list`, `run` and `sign`. It provides no `add` and no `delete`.

- **Installing** can only be started, not completed, by the server. The signed file is handed to
  `open`, and the Shortcuts app presents a confirmation sheet. There is no callback; the outcome is
  discovered by calling `shortcuts list` again afterwards.
- **Removing** cannot be started at all. The only programmatic route would be writing to
  `~/Library/Shortcuts/Shortcuts.sqlite`, a private Core Data store belonging to a running
  application. The server opens the Shortcuts app instead and the interface explains the step.

### Importing a duplicate name breaks both copies

Importing a shortcut whose name is already present **adds a second entry rather than replacing the
first**. Because the CLI addresses shortcuts only by name, two entries sharing a name cause every
invocation to fail:

```
Error: The operation couldn't be completed. Couldn't find shortcut
```

Both copies become unusable, and neither can be distinguished in the Shortcuts app. `install()`
therefore refuses when a copy is already present, and the settings interface offers no reinstall
action.

### The first run blocks on an approval sheet

The first invocation raises *"Allow … to send a message?"* and blocks until it is answered. A run
left unanswered was measured at **63 seconds** before the CLI abandoned it. The timeout in
`ShortcutsCommand.run` is 180 seconds to accommodate this.

The prompt offers **Don't Allow**, **Allow Once** and **Always Allow**. Only **Always Allow**
produces a durable grant. It is recorded in `~/Library/Shortcuts/Shortcuts.sqlite`, table
`ZSMARTPROMPTPERMISSION`:

```
Mode   => "ActionWildcard"
Status => "Allow"
ContentDestination => { BundleIdentifier => "com.apple.MobileSMS", managedLevel => 1 }
```

`ActionWildcard` scopes the grant to the shortcut's send action targeting Messages. It is **not**
scoped to a recipient set: after one approval, sends to new addresses and the creation of entirely
new group chats proceed without further prompting. Seven consecutive runs across four different
recipient sets, including one that created a new group, completed in approximately 1.2 seconds each
with no prompt.

This is why the settings interface includes a test send. The grant does not exist until a message
has actually been sent and approved.

### Failures are not diagnosable

`shortcuts run` reports **every** failure as the same string:

```
Error: An unknown error occurred.
```

A missing permission grant, a malformed parameter, and a recipient set Messages declined all
produce that sentence and the same exit code. Nothing corresponding appears in `log stream` for the
Shortcuts subsystem. Callers must not attempt to classify a failure from this output; the only
supportable report is that the operation did not complete.

One recipient set failed reproducibly this way — three attempts, before and after the permission
grant and with the addresses reordered — while five other sets succeeded. The target conversation
was structurally indistinguishable from ones that worked: same `service_name`, `style`,
`account_id`, and neither archived nor filtered. No explanation was established.

### The send action returns nothing

No GUID and no output of any kind. The created chat is located afterwards in `chat.db` by its
participant set, which is what `MessageRepository.chats(matchingParticipants:normalize:)` exists
for. The row is reliably absent for a short period after the send returns, so the lookup polls.

---

## How the server uses it

`ChatInterface.create` selects among three backends in a fixed order:

1. **Private API**, when the helper is connected. Creates either kind of chat, requires no first
   message, and returns the GUID directly.
2. **AppleScript**, for a one-to-one chat, by sending to the participant.
3. **The Shortcut**, for a group chat, when the user has installed it.

A group request on a server with neither the helper nor the Shortcut is refused with a message
naming the setting that resolves it.

Because backends 2 and 3 both create the chat *by sending*, a first message is required when the
Private API is unavailable. This is reported as a `400` explaining the reason rather than as a
generic failure, since the Private API genuinely has no such requirement.

### Availability is re-checked before every use

A shortcut can be deleted in the Shortcuts app at any moment, and nothing notifies the server.
`shortcuts list` is the only detection mechanism available. `GroupChatShortcutManager.status`
caches for 10 seconds so that rendering a settings page does not spawn a subprocess per redraw, and
`send` forces a refresh before running so that a deletion is noticed rather than surfacing as the
undiagnosable error above.

---

## Verification performed

The shipping code path was exercised end to end against a clean Shortcuts library:

| Check | Result |
|---|---|
| Swift-generated workflow signs and imports | Confirmed |
| Direct message with dynamic recipient and body | Delivered to the requested address; body matched the supplied text exactly |
| Group creation for a participant set with no existing chat | New chat `;+;` row created with exactly the requested participants; body matched |
| Repeat run with the same participant set | Reused the existing chat; chat count unchanged |
| Runs after the permission grant | Exit `0`, approximately 1.2 seconds, no prompt |

Message bodies were read back from `message.attributedBody` rather than `message.text`, which is
empty for these rows.
