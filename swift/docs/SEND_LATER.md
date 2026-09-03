# Send Later

Apple's own message scheduling, and how to drive it through this server's API. Everything here
was measured on macOS 26.5.2 (Tahoe) against a real conversation — where something is a guess,
it says so.

---

## What it actually is

Send Later is the thing you get in Messages by holding the send button and picking a time. The
message goes to Apple **already scheduled**. iMessage delivers it at the appointed time whether
or not your Mac is awake, running, or on the network.

That is worth stating plainly because this server has a second, unrelated feature with a
similar name: `POST /api/v1/message/schedule` and friends. Those are **the server's own timer** —
BlueBubbles holds the message and sends it when the clock comes round, which means the Mac has
to be up and the server has to be running. Same idea, completely different machinery.

| | v1 `/message/schedule` | v2 `/message/send-later` |
|---|---|---|
| Who holds it | This server, in `app.db` | Apple, in iMessage |
| Mac must be awake at send time | Yes | No |
| Shows in Messages.app before it sends | No | Yes, in the transcript |
| Works without the Private API | Yes | No |

Both are useful. If you want a message to go out while the Mac is asleep, you want this one.

A scheduled message lives in `chat.db` like any other row, from the moment you create it. It has
two extra columns set:

- `schedule_type` — 2 means "the user scheduled this". 0 is an ordinary message.
- `schedule_state` — 1 when it is first accepted, 2 once the daemon has it. Both mean pending.

Its `date` is **the delivery time**, not when you composed it. That is Apple's choice, not ours,
and it is why a pending message sorts into the future in a transcript, which is exactly where
Messages shows it.

---

## How the sending actually works

Skip this unless you are working on the server itself.

The obvious approach does not work, which cost an afternoon. `IMMessage` has `scheduleType` and
`scheduleState` properties and an initializer that takes both. Set them, send with
`-[IMChat sendMessage:]`, and the message goes out **immediately** — the row lands with
`schedule_type 0` and a delivery time of now. No error anywhere. Those two words on the message
object are not what schedules anything.

What Messages does is put the date on the **composition**:

1. `CKSendLaterPluginInfo` initialised with the date.
2. `-[CKComposition setSendLaterPluginInfo:]`.
3. `-[CKConversation messagesFromComposition:]` — this is where it happens. That method asks the
   composition for its send-later info, and if there is one it passes `selectedDate` as the
   message's `time:` along with `scheduleType 2` / `scheduleState 1`. No info, and it passes
   "now" and 0/0.
4. `-[CKConversation sendMessage:newComposition:]` as usual.

The rest of the lifecycle is `IMChat`:

| Operation | Selector | Notes |
|---|---|---|
| Cancel | `cancelScheduledMessageItem:cancelType:` | Cancel type 1. Takes the message **item** — the GUID-based variant returns success and does nothing |
| Reschedule | `editScheduledMessageItem:scheduleType:deliveryTime:` | Type 2 with the new date |
| Send now | the same selector | Type **0** with a **nil** date. IMCore logs this branch as "Modifying scheduled time to be immediate" |
| Edit text | `editScheduledMessageItem:atPartIndex:withNewPartText:newPartTranslation:` | Rewrites the pending item in place |

The "takes the item, not the GUID" pattern shows up twice, and both times the GUID variant fails
silently. If you add anything here, load the message item first.

---

## The REST API

Everything is v2 and needs the Private API. macOS 15 or newer; below that the routes answer 400
with "Send Later is only supported on macOS Sequoia (15) and newer".

### Schedule one

```http
POST /api/v2/message/send-later
{
  "chatGuid": "iMessage;-;+15551234567",
  "message": "Happy birthday!",
  "scheduledFor": 1788440082220
}
```

`scheduledFor` is **epoch milliseconds** and has to be in the future (there is a minute of slack
for clock skew). Everything `/message/text` accepts works here too: `subject`, `effectId`,
`selectedMessageGuid` for a reply, `partIndex`, `textFormatting`, `tempGuid`.

You get back the serialised message row, same as any send. It will have `scheduleType: 2` and
`scheduleState: 1` on it.

### List what is pending

```http
GET /api/v2/message/send-later
GET /api/v2/message/send-later?chatGuid=iMessage;-;+15551234567
GET /api/v2/message/send-later?with=chat,attachment
```

Ordinary message rows, soonest delivery first, with `count` in `metadata`. This one reads
`chat.db` directly, so it works even if the helper is not connected.

### Change one

```http
PUT /api/v2/message/send-later/:guid
{ "chatGuid": "…", "message": "New text" }
{ "chatGuid": "…", "scheduledFor": 1788443682220 }
{ "chatGuid": "…", "message": "New text", "scheduledFor": 1788443682220 }
```

Send the text, the time, or both. At least one, or you get a 400. `partIndex` defaults to 0 and
only matters for multipart messages.

Editing the text of a *scheduled* message is not the same as editing a *sent* one. Nothing has
been delivered, so there is no edit history, no "Edited" label, and the recipient never sees the
earlier version. It is just a draft with a timer.

### Send it now

```http
POST /api/v2/message/send-later/:guid/send-now
{ "chatGuid": "…" }
```

Delivers immediately. The row becomes an ordinary message — `scheduleType` and `scheduleState`
drop to 0, `isDelivered` goes to 1 — and disappears from the pending list.

### Cancel it

```http
DELETE /api/v2/message/send-later/:guid
{ "chatGuid": "…" }
```

The row is **deleted** from `chat.db`. Not marked cancelled, not left in some terminal state —
gone. Drop it from your UI rather than waiting for a status change.

---

## Notes for client authors

- **`dateCreated` is the delivery time.** For pending messages it is the future. If you sort a
  transcript by it, they land where Messages puts them, which is usually what you want. If you
  need "when did I write this", it is not in the row.
- **Check `scheduleType`, not `isSent`.** `isSent` goes to 1 the moment Messages accepts the
  message, long before it is delivered. A pending message and a sent one are indistinguishable
  without the schedule fields. Those fields are only present on scheduled rows, so their absence
  means "ordinary message".
- **These are ours, not the reference server's.** The Node server never read those columns, so
  `scheduleType` and `scheduleState` are additions. They are documented in `acceptedDifferences`
  and are not going away, but a client written against the old server will not know them.
- **Cancel means the row vanishes**, so a client holding a list should remove it locally and not
  expect a change event describing a cancellation.
- **The pending list is a query, not a subscription.** There is no event when a scheduled message
  is finally delivered; it arrives as a normal new-message event, and the row it came from is the
  same row with its schedule fields cleared.
- **Only text is schedulable today.** Attachments and multipart go through a different send path
  in the helper and do not carry `scheduledFor` yet.

---

## Loose ends

- Nobody has watched a scheduled message actually **arrive** at its appointed time. Every test so
  far has cancelled or released it early. The mechanism is Apple's, so it presumably works, but
  it is untested here.
- The pending list filters on `schedule_state` 1 and 2, the two values observed on pending rows.
  What state a *delivered* scheduled message ends in was never seen, because nothing was left to
  deliver. If one ever shows up in the pending list after it has gone out, that filter is where
  to look.
- Attachments and multipart, as above.
- Nothing here has been tried on macOS 15. The version floor is inferred from when
  `scheduleType` appeared, not measured.
