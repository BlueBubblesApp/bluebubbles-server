# Server updates from a client

How a client tells its user that the server has an update, and lets them install it at once or
schedule it for a window such as overnight. Everything here is this server's API; where it is
the reference's (`electron/packages/server/src/…`), it says so.

---

## The flow

1. The server finds a release and emits **`server-update`** over the socket and FCM. The payload
   is the bare version string (`"1.4.0"`), once per version, as the reference sends it
   (`updateService/index.ts`). This is the event to raise a notification from.
2. The notification opens the client's update page, which reads
   **`GET /api/v2/server/update`**.
3. The page offers two actions:
   - **Install now**: `POST /api/v1/server/update/install`. The server downloads, installs and
     relaunches.
   - **Schedule**: `POST /api/v2/server/update/schedule` with a window. The server downloads
     at once and relaunches inside the window.
4. While the page is open, **`server-update-status-changed`** keeps it current: downloading,
   scheduled, installing, or nothing pending. The page needs no polling.

A server that answers `GET /api/v2/server/update` with a 404 predates scheduling. Offer only
**Install now** there.

---

## `GET /api/v2/server/update`

Scope `server:admin`. Answers on every server, including one that cannot install.

```json
{
  "current_version": "1.3.0",
  "available": true,
  "update": {
    "version": "1.4.0",
    "release_name": "BlueBubbles Server 1.4.0",
    "release_date": 1788396119000,
    "release_notes": "<ul><li>…</li></ul>",
    "release_notes_url": "https://github.com/BlueBubblesApp/bluebubbles-server/releases/tag/v1.4.0"
  },
  "install": {
    "version": "1.4.0",
    "state": "scheduled",
    "scheduled_for": 1788418800000,
    "scheduled_until": 1788429600000,
    "scheduled_by": "client"
  },
  "can_install": true,
  "requested_window": { "start": 1788418800000, "end": 1788429600000 },
  "automatic_install": {
    "enabled": false,
    "start_hour": 3,
    "end_hour": 6,
    "time_zone": "America/New_York",
    "next_window": { "start": 1788418800000, "end": 1788429600000 }
  }
}
```

Every date is epoch **milliseconds**, `release_date` included. v1's `update/check` sends that
one as an ISO string, and v1 is frozen with it; this route has no reason to repeat it.

| Field | Meaning |
|---|---|
| `available` | Whether the feed offers a newer release. `update` is null when it is false |
| `update.release_notes` | HTML from the feed, or null. `release_notes_url` is the page to link to instead |
| `install` | What is happening to the release. Null when nothing is pending |
| `install.state` | `downloading`, `scheduled` (downloaded, waiting for a window) or `installing` (relaunching now) |
| `install.scheduled_for`, `scheduled_until` | The window the relaunch waits for. `scheduled` only |
| `install.scheduled_by` | `client` for a window asked for through this API, `automatic` for the hours set on the Mac. `scheduled` only |
| `can_install` | False under the headless server and on a build that cannot verify downloads. Hide both actions when it is false |
| `requested_window` | The window a client asked for, at its next occurrence. Null when none was asked for |
| `automatic_install` | The Mac's own schedule (Install Updates Automatically and its hours), in the Mac's time zone |
| `automatic_install.next_window` | The automatic window open now or opening next. Reported with the switch off too |

`requested_window` and `install` answer different questions, so read both. Straight after a
schedule request the download is still under way: `install.state` is `downloading`, and
`requested_window` is the window it will wait for once it lands.

`automatic_install.next_window` is the natural default for a schedule picker: it is the window
the person who runs the server chose, already converted to an instant.

---

## Installing now

`POST /api/v1/server/update/install`, unchanged from v1. `?wait=true` holds the response until
the download lands. The server emits `server-update-downloading` (payload null) first, as the
reference does (`serverRouter.ts`).

Install now beats any schedule. A download already waiting for a window installs straight away;
one still downloading for a client's window installs the moment it lands.

The app relaunches, so the connection drops. Reconnect and read the v2 status:
`current_version` is the new one once the relaunch is done.

---

## Scheduling

`POST /api/v2/server/update/schedule`, scope `server:admin`.

```json
{ "window_start": 1788418800000, "window_end": 1788429600000 }
```

Both fields are required, in epoch milliseconds. They are **absolute instants**, so the
client's time zone and the Mac's do not have to agree: convert the person's "2am to 5am" on
the client, or offer `automatic_install.next_window`, which is already an instant.

| Rule | Outcome when broken |
|---|---|
| Both are finite numbers, `window_end` later than `window_start` | 400 `Validation Error` |
| `window_end` in the future | 400 `Validation Error` |
| `window_end` at most seven days ahead | 400 `Validation Error` |
| The window at most a day long, because a missed one is tried again the next day | 400 `Validation Error` |
| A release is available | 400 `Validation Error`: there is nothing to install |
| The server can install (`can_install`) | 503 `Server Error`, naming the download to install by hand |
| Nobody at the Mac has the updater's own window open | 503 `Server Error`; try again later |
| The app can install unattended (its bundle is somewhere this user can write) | 503 `Server Error`; install from the Mac |

A `window_start` already past means "from now". The response is the status above, after the
request.

What the server does with it:

- **It downloads at once.** The window only has to hold a relaunch, which takes seconds.
- **It replaces the automatic hours for this update**, whether or not Install Updates
  Automatically is on. The request is consent of its own.
- **It holds the relaunch while a scheduled message is due within fifteen minutes**, then
  looks again every fifteen until the window closes.
- **A window that closes without the install comes round the next day** at the same times:
  the Mac slept through it, or a scheduled message held it to the end. It does not install
  outside the hours the person chose.
- **Asking again replaces the window.** There is only ever one.

### Withdrawing it

`DELETE /api/v2/server/update/schedule`, no body. Answers with the status.

The download stays. The update falls back to the automatic hours if Install Updates
Automatically is on, and to installing when the app next quits if it is not. An automatic
schedule is a setting on the Mac and is not withdrawn: the status still shows it, with
`scheduled_by: automatic`. Withdrawing when nothing was requested is not an error.

---

## Events

| Event | Payload | When |
|---|---|---|
| `server-update` | The version, a bare string | A release is found, once per version |
| `server-update-downloading` | null | A client asked to install now, before the download starts |
| `server-update-status-changed` | `{"install": …}`: the `install` object above, or null | `install` moves: downloading, scheduled (including a window that moves), installing, or cleared |

All three go to the socket, to FCM, and to webhooks subscribed to them. `server-update-status-changed` fits FCM's
4096 bytes with room to spare: it carries no release notes.

The `installing` event is emitted just before the relaunch and is best-effort: the process that
sends it is about to exit. The reconnect after the relaunch is the reliable signal.

---

## What a schedule does not survive

The window lives in the running app. Stopping and starting the server keeps it; the app
quitting does not need to, because Sparkle installs a downloaded update when the app quits.
The one gap is an app that exits before the download lands, such as a crash: the window is
gone, and `requested_window` reads null when the server comes back. Read the status after a
reconnect rather than assuming a schedule still stands.
