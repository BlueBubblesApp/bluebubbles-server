# Audit log

What the server records about itself, in what shape, and how to get it out. This is the
reference for anyone writing a SIEM rule, a Postgres query or a spreadsheet against the
records; the design notes are in the file headers under `Sources/BBAudit/`.

The audit log is a built-in service that **ships switched off**. Nothing is recorded until it
is turned on from the Integrations screen (or by removing `app.bluebubbles.core.audit-log`
from the `disabled_services` setting). Once on, every record is written to the server's own
database, shown on the Audit Log page in the app, exportable as CSV, and optionally forwarded
to a syslog receiver as it is written.

## What is recorded

One record per:

- state-changing API request, with who made it and how it went (read-only requests too, when
  the **Record Read-Only Requests** field is on);
- authentication failure, over HTTP or the socket: a wrong password, a missing credential, a
  blocked client, a credential without the scope a route needs;
- change to the blocklist or the allowlist, automatic or administered;
- settings change, with the value before and after (secrets excepted);
- service that starts, stops, fails, or is switched on or off;
- webhook registered, changed or removed;
- scheduled message created, changed, removed, sent or failed;
- change to the subscription: a gated route refused for want of one, the entitlement moving,
  a check with the issuer succeeding or failing, a licence revoked or removed;
- thing the audit log does to itself: starting, stopping, applying retention, exporting, losing
  and regaining its syslog receiver, and dropping records it could not keep.

**Refusals are limited per client.** A refused client can be refused as fast as it can send,
so a record whose outcome is `denied` and whose actor is a client is stored once per minute
for each kind, client and route. That covers every `auth.*` record, `license.refused`, and an
`api.request` that answered 401, 402 or 403. The repeats inside that minute are counted, and one
`audit.repeats_suppressed` record says how many when the minute is up. Nothing else is
limited.

Successful authentication is **not** a record of its own. Every API request authenticates, so
it would be one record per request, which is what `api.request` already is; its
`authenticated` field says whether a credential was accepted.

## What is never recorded

A record is the artefact most likely to leave this Mac, so:

- **No message content, subjects, display names, file names or attachment names.** A record
  says that a message was sent on a route, never what it said.
- **No phone numbers, email addresses or chat identifiers.** The one address a record carries
  is a *client* address (an IP), which is what an operator blocks and unblocks. A route is
  always recorded as its template (`/api/v1/chat/:guid/read`), never the resolved path.
- **No secret values.** A change to a secret setting records that the key changed; the value
  is `••••` on both sides. A webhook URL has any credential in its query removed before it is
  recorded.
- **Nothing that says how to reach this server.** Its published address (`server_address`), a
  tunnel's public name (ngrok's custom domain, the Cloudflare and Tailscale hostnames, zrok's
  reserved name), the dynamic DNS URL and the ntfy topic are declared *confidential*. A
  change to one records that the key changed, with `••••` on both sides, as a secret does.
- **Not the entitlement token.** `license_token` is confidential too: its claims name the
  licence's subject (the vendor's customer identifier) and this Mac's fingerprint, and the
  daily check rewrites it. The `settings.changed` record for that write withholds both
  values; what the token grants is on the `license.refreshed` record beside it.

## The record

Every record has the same envelope. Kind-specific fields live in `metadata`, whose keys each
kind declares (see [the catalogue](#the-event-catalogue)). The same document is stored as a
row, exported as a CSV line, forwarded as the body of a syslog message, and rendered on the
page.

```json
{
  "schema_version": 1,
  "id": 4213,
  "uuid": "6f1c2a0e-9f3b-4d1a-8c4e-2b7d0f9a1e55",
  "occurred_at": "2026-03-04T17:22:08.531Z",
  "category": "auth",
  "kind": "auth.credential_rejected",
  "outcome": "denied",
  "severity": "warning",
  "actor": { "kind": "client", "id": "203.0.113.9" },
  "source": "http",
  "request_id": "a3f9c1d2e4b5",
  "route": "/api/v1/message/text",
  "subject": { "kind": "client", "id": "203.0.113.9" },
  "summary": "A credential from 203.0.113.9 was rejected on /api/v1/message/text.",
  "metadata": { "reason": "auth.invalid_credential", "transport": "http" },
  "host": "studio.local"
}
```

| Key | Type | Meaning |
|---|---|---|
| `schema_version` | integer | The envelope's version, `1`. Bumped only when a key is renamed or removed; adding a key is not a new version. |
| `id` | integer | The row id in `audit_event`. Present once stored, so always present in an export and in a forwarded message. |
| `uuid` | string | Stable across every surface: the same record exported twice carries the same UUID. Deduplicate on this. |
| `occurred_at` | string | RFC 3339, UTC, millisecond precision, always with a `Z`. |
| `category` | string | The first segment of `kind`; what a receiver routes on. One of the nine below. |
| `kind` | string | `<category>.<name>`, from the catalogue. |
| `outcome` | string | `success` (it happened), `failure` (attempted and did not happen), `denied` (refused on purpose: a wrong password, a blocked client, a missing scope). |
| `severity` | string | `info`, `notice`, `warning` or `critical`. A `failure` or `denied` outcome is at least `warning`. |
| `actor` | object | Who caused it. `kind` is `client` (an API caller; `id` is its address, or null when nothing identified the peer), `operator` (the person at the Mac, through the app or the command line; `id` is null), `system` (the server itself; `id` names the component: a service identifier, `startup`, `shutdown`, `access-control`, `service-registry`, `settings-propagation`, `audit`, or `app` for the app's own bookkeeping) or `unattributed` (nothing said who: the work reached the record outside every boundary that names an actor; `id` is null). An `unattributed` record is never assumed to be the operator's; it is a gap in the server's own tracing, and worth reporting. |
| `source` | string | Which way the action reached the server: `http`, `socket`, `app`, `cli`, `server`, or `unknown` for an `unattributed` record. `cli` is a command that changes the server and exits (`--clear-blocklist`, `--migrate`, `--remove-legacy-credentials`, `--import`), recorded as the operator while the audit log is on. |
| `request_id` | string or null | One identifier per API request, shared by the `api.request` record and every record written while that request was handled, so they can be joined. Null outside a request. |
| `route` | string or null | The route template the request matched. Null outside a request. |
| `subject` | object or null | What the record is about: `{ "kind": …, "id": … }`. Kinds: `setting` (a storage key), `service` (a service identifier), `client` (an IP address), `route` (a template), `webhook` (a row id), `scheduled_message` (a row id), `allowlist_entry` (a CIDR). Null for a record about nothing in particular. |
| `summary` | string | One sentence for a person. Safe to display and forward as it is. |
| `metadata` | object | The kind's own fields. `{}` for a kind with none, never null. |
| `host` | string | This Mac's hostname. Only in the syslog body, where the record is read away from the machine; not stored and not in the CSV. |

### Categories

| `category` | What it covers |
|---|---|
| `auth` | Authentication failures on either transport |
| `access_control` | The blocklist, the allowlist and the login throttle |
| `settings` | Settings written or removed |
| `service` | Services starting, stopping, failing, switched on or off |
| `api` | Finished API requests |
| `webhook` | Webhook registrations |
| `scheduled_message` | The scheduled-message queue |
| `license` | The subscription: refusals, the entitlement moving, checks with the issuer |
| `audit` | The audit log's own lifecycle |

### Severity

| `severity` | Syslog code | Meaning |
|---|---|---|
| `info` | 6 | Ordinary business: a request served, a setting saved |
| `notice` | 5 | Worth noticing: a service started or stopped, a client blocked |
| `warning` | 4 | Something failed or was refused |
| `critical` | 2 | Something a person should act on now: records were dropped |

## The event catalogue

Every kind the server can write, with the keys its `metadata` carries. `AuditEventKind`
(`Sources/BBAudit/AuditEventKind.swift`) is the declaration; `AuditDocumentationTests` fails
the build if a kind or a field exists there and is not on this page. Types are JSON types.

### `auth`

**`auth.credential_rejected`**: a credential was presented and did not match. Outcome
`denied`. Actor: the client. Subject: the client address, when known.

| Field | Type | Meaning |
|---|---|---|
| `reason` | string | The server's own failure code: `auth.invalid_credential`, `auth.expired`, `auth.revoked` over HTTP; `socket_handshake_rejected` or `socket_connect_rejected` over the socket. |
| `transport` | string | `http` or `socket`. |

**`auth.credential_missing`**: a route that needs a credential was called without one. Over
the socket, a connection whose authentication grace period lapsed. Outcome `denied`.

| Field | Type | Meaning |
|---|---|---|
| `transport` | string | `http` or `socket`. |

**`auth.request_blocked`**: the caller is blocked, so the credential was never read. Outcome
`denied`.

| Field | Type | Meaning |
|---|---|---|
| `transport` | string | `http` or `socket`. |

**`auth.scope_refused`**: the credential was valid and lacks a scope the route requires.
Outcome `denied`.

| Field | Type | Meaning |
|---|---|---|
| `scope` | string | The scope the route requires. |

### `access_control`

**`access_control.client_blocked`**: the failure threshold blocked a client. Actor:
`system` / `access-control`, because the block is the server's decision even though it
happens inside a request. Subject: the client.

| Field | Type | Meaning |
|---|---|---|
| `failure_count` | integer | Failures counted against the client in the window. |
| `offence_count` | integer | How many times this client has been blocked; the lockout grows with it. |
| `expires_at` | string | When the block lapses, RFC 3339 UTC. |
| `reason` | string | The last failure's reason. |

**`access_control.client_blocked_permanently`**: an operator blocked a client with no
expiry. Subject: the client.

| Field | Type | Meaning |
|---|---|---|
| `reason` | string | The operator's reason. |

**`access_control.client_unblocked`**: a block was lifted by hand. Subject: the client. No
metadata.

**`access_control.blocks_cleared`**: every block was lifted at once.

| Field | Type | Meaning |
|---|---|---|
| `count` | integer | How many blocks were lifted. |

**`access_control.client_allowlisted`**: an address or range was added to the allowlist.
Subject: the allowlist entry (the CIDR).

| Field | Type | Meaning |
|---|---|---|
| `note` | string | The operator's note, present only when one was given. |

**`access_control.allowlist_entry_removed`**: an allowlist entry was removed. Subject: the
entry. No metadata.

**`access_control.logins_throttled`**: failures from a source nothing could identify (a
proxy that forwards no client address) crossed the global threshold. Outcome `denied`. Actor:
`system` / `access-control`.

| Field | Type | Meaning |
|---|---|---|
| `failure_count` | integer | Unattributable failures in the window. |

### `settings`

**`settings.changed`**: one or more settings were written. One record per write, however many
keys it touched. Subject: the setting, when exactly one key changed. Actor: whoever wrote it:
a client through the API, the operator through the app or the command line, or a service
(`system` with the service's identifier) writing its own bookkeeping.

| Field | Type | Meaning |
|---|---|---|
| `changes` | object | One entry per key: `{ "<key>": { "previous": …, "current": … } }`. Values keep their stored type (a number is a number, a flag a boolean). A secret's or a confidential setting's values are `••••` on both sides; an unset value is `null`. |
| `keys` | array of strings | The keys that changed, sorted, for filtering without walking `changes`. |

**`settings.removed`**: one or more settings were deleted outright.

| Field | Type | Meaning |
|---|---|---|
| `keys` | array of strings | The keys that were removed. |

### `service`

Lifecycle records are written by the audit log service itself from the registry's health
snapshots, so a service that starts before the audit log does has no `service.started` record
in that run; `audit.recording_started` marks the point from which they are complete. Actor:
`system` / `service-registry`. Subject: the service identifier.

**`service.started`**: a service came up (or came back up after a restart).

| Field | Type | Meaning |
|---|---|---|
| `service_name` | string | The service's display name, as the Integrations screen shows it. |

**`service.stopped`**: a running service stopped, or became inactive.

| Field | Type | Meaning |
|---|---|---|
| `service_name` | string | The service's display name. |

**`service.failed`**: a service reported a failure. Outcome `failure`. A repeated failure with
the same reason is one record.

| Field | Type | Meaning |
|---|---|---|
| `service_name` | string | The service's display name. |
| `reason` | string | The failure, as the registry reported it. |

**`service.enabled`** and **`service.disabled`**: the switch on the Integrations screen (the
`disabled_services` setting) moved for this service. Written alongside the `settings.changed`
record for the same write, so a rule for "the audit log was switched off" does not have to
parse a comma-separated list out of a settings diff. Actor: whoever wrote the setting.

| Field | Type | Meaning |
|---|---|---|
| `service_name` | string | The service's display name. |

### `api`

**`api.request`**: an API request finished. Every `POST`, `PUT` and `DELETE` is recorded; a
`GET` only when **Record Read-Only Requests** is on, because clients poll constantly and each
request is a row. Outcome: `success` for a status under 400, `denied` for 401, 402 and 403,
`failure` for anything else. Actor: the client. Subject: the route template. `request_id` on
this record is the one every record written while the request was handled carries.

| Field | Type | Meaning |
|---|---|---|
| `method` | string | The HTTP method. |
| `handler` | string | The handler identifier, such as `message.sendText`. Stable across releases where a path may not be. |
| `status` | integer | The HTTP status the client received. |
| `duration_ms` | integer | How long the request took, in milliseconds. |
| `authenticated` | boolean | Whether a credential was accepted. False for a refused request and for the routes that need none. |

### `webhook`

Subject: the webhook row id.

**`webhook.created`** and **`webhook.updated`**: a webhook was registered or changed.

| Field | Type | Meaning |
|---|---|---|
| `url` | string | The endpoint, with any credential in its query removed. |
| `events` | array of strings | The events it subscribes to; `*` means all. |
| `follow_redirects` | boolean | Whether delivery follows a redirect, which changes where message content is sent. |

**`webhook.deleted`**: a webhook was removed. No metadata.

### `scheduled_message`

Subject: the scheduled message's row id. The message's text and recipient are never recorded.

**`scheduled_message.created`** and **`scheduled_message.updated`**.

| Field | Type | Meaning |
|---|---|---|
| `type` | string | The scheduled action; `send-message` for every client so far. |
| `scheduled_for` | string | When it is due, RFC 3339 UTC. |
| `recurring` | boolean | Whether it repeats. |

**`scheduled_message.deleted`**: a scheduled message was removed, or the finished history was
cleared at once.

| Field | Type | Meaning |
|---|---|---|
| `count` | integer | How many rows went. Present only when the finished history was cleared at once. |

**`scheduled_message.sent`**: the server sent it. Actor: `system` with the scheduler's
service identifier.

| Field | Type | Meaning |
|---|---|---|
| `type` | string | The scheduled action. |
| `next_occurrence` | string or null | When the series fires next, RFC 3339 UTC, or `null` for a one-shot. |

**`scheduled_message.failed`**: the server tried and could not send it. Outcome `failure`.

| Field | Type | Meaning |
|---|---|---|
| `type` | string | The scheduled action. |
| `reason` | string | Why the send failed. |

### `license`

What this server is entitled to, and what it refused for want of it. The vocabulary is the
API's: a `reason` here is the same string a client reads in a 402, and a status is the same
name `GET /api/v2/server/subscription` reports. Entering a key is not a kind of its own: it is
the `settings.changed` record whose subject is `license_key` (the value withheld, as a secret's
is), followed by the status move it caused.

**`license.refused`**: a route that needs a subscription was called on a server that does
not hold one, and answered 402. Outcome `denied`. Actor: the client. Subject: the client
address, when known. Route: the template.

| Field | Type | Meaning |
|---|---|---|
| `reason` | string | Why, as the 402 spells it: `no_license`, `license_expired`, `license_revoked`, `tier_insufficient`, `machine_mismatch` or `validation_unavailable`. |
| `required_tier` | string | The tier the route asked for, such as `pro`. |
| `current_tier` | string or null | The tier held, or `null` for no entitlement at all. |

**`license.status_changed`**: the evaluated entitlement moved. A key entered, a token
confirmed, a subscription period ending, a token no refresh has renewed, a revocation, a
removal: each is one move. Severity `notice` for a move into `active` or `none`, `warning`
for a move into any status that refuses. Actor: `system` with the subscription service's
identifier, whatever prompted the move, because the evaluation is the server's own. The first
evaluation of a run is recorded only when it found something; a server with no key is silent.

| Field | Type | Meaning |
|---|---|---|
| `previous` | string or null | The status before: `none`, `active`, `expired`, `revoked`, `machine_mismatch` or `unverifiable`. `null` for the first evaluation of a run. |
| `current` | string | The status now, from the same set. |
| `tier` | string or null | The tier held now, or `null` for no entitlement. |
| `subscription_ends_at` | string or null | When the subscription ends, RFC 3339 UTC, or `null` when no end is known. |

**`license.refreshed`**: the issuer answered a check with a token. Severity `info`: the
subscription service checks once a day, and the Subscription page's Check Now does the same.
Actor: whoever asked: the service from its schedule, the operator from the page. Says what
was received, not what it means; the `license.status_changed` record beside it says that, and
is absent when nothing moved.

| Field | Type | Meaning |
|---|---|---|
| `tier` | string | The tier the token grants. |
| `perpetual` | boolean | Whether the token says the licence was bought outright rather than subscribed. |
| `subscription_ends_at` | string or null | When the subscription ends, RFC 3339 UTC, or `null` when no end is known. |

**`license.refresh_failed`**: a check with the issuer produced no token. Outcome `failure`.
The entitlement in hand is untouched: a token stays good for its window, and the status
moves only when that runs out. Actor: whoever asked.

| Field | Type | Meaning |
|---|---|---|
| `reason` | string | What the exchange failed with. |

**`license.revoked`**: the issuer reports the licence disabled: a refund, a chargeback, a
manual revocation. Outcome `denied`, severity `warning`. Written once per revocation, not
once per daily check that repeats it. Actor: whoever asked. No metadata.

**`license.removed`**: the licence was removed from this Mac. Actor: the operator, from the
Subscription page.

| Field | Type | Meaning |
|---|---|---|
| `previous` | string | The status the licence held when it was removed. |

### `audit`

The audit log's own account of itself. Actor: `system` with the audit log's service
identifier, or `audit` for a record the recorder wrote on its own behalf.

**`audit.recording_started`**: the audit log came on. Everything after this record in a run
is complete; nothing before it in that run was recorded.

| Field | Type | Meaning |
|---|---|---|
| `retention_days` | integer | The retention in force; `0` means forever. |
| `forwarding` | string | `off`, or the syslog transport in use: `tls`, `tcp` or `udp`. |
| `records_reads` | boolean | Whether read-only API requests are recorded. |

**`audit.recording_stopped`**: the audit log is going off, or the server is shutting down.
The last record of a run. No metadata.

**`audit.retention_applied`**: the daily sweep removed records older than the retention
period. Written only when something was removed.

| Field | Type | Meaning |
|---|---|---|
| `deleted_count` | integer | How many records the sweep removed. |
| `retention_days` | integer | The retention in force. |
| `cutoff` | string | Records older than this were removed, RFC 3339 UTC. |

**`audit.exported`**: a copy of the log left the machine as a file. Actor: the operator.

| Field | Type | Meaning |
|---|---|---|
| `format` | string | `csv`. |
| `record_count` | integer | How many records the export holds. |
| `unreadable_count` | integer | Matching records this version could not read (written by a newer server, of a kind it does not know), and so left out of the file. The page and the export both say how many. |
| `filtered` | boolean | Whether a filter narrowed the export. |

**`audit.forwarding_failed`**: records stopped reaching the syslog receiver. Outcome
`failure`. One record per outage, not one per retry; records keep being stored locally and
queued for the receiver.

| Field | Type | Meaning |
|---|---|---|
| `transport` | string | `tls`, `tcp` or `udp`. |
| `reason` | string | What the connection or write failed with. |

**`audit.forwarding_restored`**: records are reaching the receiver again.

| Field | Type | Meaning |
|---|---|---|
| `transport` | string | `tls`, `tcp` or `udp`. |

**`audit.events_dropped`**: records were lost. Outcome `failure`, severity `critical`. The
recorder's buffer and the forwarder's queue are both bounded; past the cap the oldest waiting
records are dropped and the count is kept, and this record is written once the path is
flowing again, so a gap is visible to whoever reads the log rather than silent. In the syslog
copy it appears in the receiver's own stream, ahead of what followed the gap.

| Field | Type | Meaning |
|---|---|---|
| `dropped_count` | integer | How many records were lost. |
| `where` | string | `recorder_buffer` (the database could not keep up or was unavailable) or `forwarding_queue` (the receiver was unreachable for longer than the queue could hold, or the transport refused a record as too large to send). |

**`audit.repeats_suppressed`**: a refused client's record repeated inside one window, and the
repeats were counted rather than stored. Outcome `denied`, severity `warning`. Actor, source,
route and subject are those of the record that opened the window, which is stored in full.
Written when the window closes, so `occurred_at` is the last counted repeat. A SIEM rule
counting refusals adds `suppressed_count` to the one stored record it sits beside.

| Field | Type | Meaning |
|---|---|---|
| `repeated_kind` | string | The kind of the records that were counted, such as `auth.request_blocked`. |
| `suppressed_count` | integer | How many were counted rather than stored. |
| `first_at` | string | When the first counted one occurred, RFC 3339 UTC. |
| `last_at` | string | When the last counted one occurred, RFC 3339 UTC. |
| `window_seconds` | integer | How long one window lasts: 60. |

## Settings

All of the audit log's settings are fields of its own integration, configured on the
Integrations screen. Their storage keys are the field name under the service's namespace.

| Field | Default | Meaning |
|---|---|---|
| **Keep Records For (days)** `retention_days` | 90 | Records older than this are removed by a sweep that runs when the audit log starts and once a day after that. `0` keeps every record. Maximum 3650. |
| **Record Read-Only Requests** `record_reads` | off | Also record `GET` requests as `api.request`. |
| **Forward to a Syslog Receiver** `syslog_enabled` | off | Stream every record to a receiver as it is written. The local copy is kept either way. |
| **Receiver** `syslog_host` | | The receiver's hostname or address. Required when forwarding is on; with it empty the service runs, reports itself degraded and raises an alert. |
| **Transport** `syslog_transport` | `tls` | `tls` (RFC 5425), `tcp` (RFC 6587) or `udp` (RFC 5426). TLS is the only one of the three a record should cross a network on. |
| **Port** `syslog_port` | | Empty means the standard port for the transport: 6514 for TLS, 514 for TCP and UDP. |
| **Facility** `syslog_facility` | `local0` | What the receiver files these under; `local0` to `local7`. |
| **Trusted Certificate** `syslog_ca_certificate` | | PEM. The CA that signed the receiver's certificate, or the receiver's own self-signed certificate. Empty trusts the certificates the system already trusts. A secret: kept in the Keychain. |
| **Client Certificate** `syslog_client_certificate` | | PEM. A certificate the receiver has been told to expect from this server, for a receiver that requires mutual TLS. A secret. |
| **Client Private Key** `syslog_client_private_key` | | PEM. The key for the client certificate. A secret. Both or neither. |

A change to any field restarts the audit log service, which re-reads them all; the restart
itself is visible as `audit.recording_stopped` followed by `audit.recording_started`.

## Storage

Records live in the `audit_event` table of the server's own database (`app.db`), one column
per envelope key plus `metadata` as JSON text and `schema_version`. The columns, in order:
`id`, `uuid`, `occurred_at`, `category`, `kind`, `outcome`, `severity`, `actor_kind`,
`actor_id`, `source`, `request_id`, `route`, `subject_kind`, `subject_id`, `summary`,
`metadata`, `schema_version`. `(occurred_at, id)`, `(category, occurred_at, id)` and `kind`
are indexed.

Rows are inserted by the server and deleted only by the retention sweep. Nothing edits one.

**The local copy is not tamper-evident.** It is a table in a SQLite file that anyone who can
write to this Mac's Application Support folder can change, and a hash chain over it would not
help: whoever can rewrite a row can rewrite the chain after it. A record somebody on this Mac
cannot alter is one that has already left it, which is what syslog forwarding is for. Forward
to a receiver that does not let this server delete, and treat the receiver's copy as the
record and this one as a convenience.

Records are written in batches gathered over a tenth of a second, one transaction each. If the
database refuses a batch (a full disk, say), the records are held and retried after a second,
then two, doubling to a minute; the failure is logged once per outage, and the recovery once.
While it lasts the service reports itself degraded and raises one alert, which the recovery
clears.
Up to 5,000 records are held; past that the oldest are dropped, and one
`audit.events_dropped` record with the exact count is written when storing resumes.

The retention sweep deletes in batches of 5,000 rows, each its own transaction, so a large
backlog never holds `app.db`'s writer for longer than one batch takes.

A record written by a newer version of the server, of a kind this version does not know, is
left out of the page and of an export rather than failing either, and both say how many were
left out.

## CSV export

The Audit Log page's **Export CSV…** writes the records matching the page's current filter,
oldest first, as RFC 4180: a header row, CRLF line endings, a field quoted when it holds a
comma, a quote or a line break. The columns are the table's columns in the table's order,
`id` through `metadata`; `metadata` is the JSON document as one cell. A field that begins with
`=`, `+`, `-`, `@`, a tab or a carriage return is quoted and prefixed with a single quote so a
spreadsheet does not evaluate it as a formula, as OWASP recommends. The export is itself
recorded as `audit.exported`.

### Loading an export into Postgres

The columns map onto a table with the same names; `metadata` as `jsonb`:

```sql
CREATE TABLE bluebubbles_audit (
  id            bigint PRIMARY KEY,
  uuid          uuid NOT NULL UNIQUE,
  occurred_at   timestamptz NOT NULL,
  category      text NOT NULL,
  kind          text NOT NULL,
  outcome       text NOT NULL,
  severity      text NOT NULL,
  actor_kind    text NOT NULL,
  actor_id      text,
  source        text NOT NULL,
  request_id    text,
  route         text,
  subject_kind  text,
  subject_id    text,
  summary       text NOT NULL,
  metadata      jsonb NOT NULL
);

\copy bluebubbles_audit FROM 'bluebubbles-audit-2026-03-04.csv' WITH (FORMAT csv, HEADER true, NULL '');

-- Every request a client made that was refused, with the status it saw.
SELECT occurred_at, actor_id, route, metadata->>'status' AS status
FROM bluebubbles_audit
WHERE kind = 'api.request' AND outcome = 'denied'
ORDER BY occurred_at DESC;

-- Who changed the server password, and when.
SELECT occurred_at, actor_kind, actor_id, source
FROM bluebubbles_audit
WHERE kind = 'settings.changed' AND metadata->'keys' ? 'password';

-- Everything that happened under one request.
SELECT occurred_at, kind, summary FROM bluebubbles_audit
WHERE request_id = 'a3f9c1d2e4b5' ORDER BY occurred_at, id;
```

## Syslog forwarding

With **Forward to a Syslog Receiver** on, every record is sent as it is written, as an
RFC 5424 message:

```
<PRI>1 TIMESTAMP HOSTNAME APP-NAME PROCID MSGID STRUCTURED-DATA MSG
```

| Field | Value |
|---|---|
| `PRI` | Facility × 8 + severity: `local0` + `warning` is `<132>`. The severity codes are in the [severity table](#severity). |
| `TIMESTAMP` | `occurred_at`. |
| `HOSTNAME` | This Mac's hostname. |
| `APP-NAME` | `bluebubbles-server`, fixed, so a receiver's rule can name it. |
| `PROCID` | The server's process id, so two servers on one host can be told apart. |
| `MSGID` | The record's **category**, not its kind: the field is capped at 32 characters and several kinds are longer. The kind is in the body. |
| `STRUCTURED-DATA` | `[origin software="bluebubbles-server" swVersion="<version>"]`, the element the standard defines. There is no private element: the fields are in the body. `-` from a build with no version. |
| `MSG` | The record as JSON, the document above, with `host` set. No byte-order mark. |

Over TCP and TLS, messages are framed by RFC 6587 octet counting (`<length> <message>`),
because a JSON body can hold a newline inside a string and newline framing cannot survive
one. Over UDP each message is one datagram, of at most 8,192 bytes: macOS refuses a datagram
past 9,216 bytes by default, and 8,192 is the size RFC 5425 says a receiver should accept. A
record that would be larger keeps its envelope (`uuid`, `occurred_at`, `kind`, `actor` and the
rest) and has its `metadata` replaced by `{"truncated": true, "original_bytes": <size>}`, with
`summary` shortened only if that is still not enough. The local copy keeps the whole record,
and `uuid` joins the two. TCP and TLS frames carry their length and are never cut.

TLS verifies the receiver's certificate against the trusted certificate when one is set and
against the system roots otherwise, with hostname verification when the receiver is named by
a hostname rather than a literal address. A client certificate and key make the connection
mutually authenticated. PEM that cannot be read is reported once (as an alert and as
`audit.forwarding_failed`) and the forwarder stops trying until the material is replaced.

A receiver that is down does not hold up the write to the database. Records queue (up to
10,000) and the connection is retried with backoff from one second to a minute; the first
failure raises one alert and writes `audit.forwarding_failed`, the recovery clears the alert
and writes `audit.forwarding_restored`, and anything dropped from the queue in between is
reported to the receiver as `audit.events_dropped` once it is back.

When the audit log stops, a receiver that is answering is sent what is still queued, for up
to three seconds, so `audit.recording_stopped` reaches it and a clean stop is distinguishable
from a cut feed. A receiver that is not answering is not waited on; its records are in the
local copy.

### Reading the stream in a SIEM

- Route on `APP-NAME` and `MSGID` (the category); parse `MSG` as JSON.
- `uuid` is the deduplication key. A receiver that saw a message twice (a retried write after
  a broken connection) holds one record.
- `request_id` joins everything that happened under one API request to its `api.request`.
- A rule for "refused" is `outcome = denied`; for "broken" it is `outcome = failure`; for
  "look now" it is `severity = critical`, which today is only `audit.events_dropped`.
- A gap in `id` between consecutive records from the same host is a gap in what reached the
  receiver, and `audit.events_dropped` says how large.

## The Audit Log page

The page appears in the sidebar only while the audit log is switched on, newest record first,
a hundred to a page, with a category filter, an outcome filter and a search over the summary,
the actor, the subject and the route. Double-clicking a row shows the whole record, including
the metadata as the JSON a receiver would hold. **Export CSV…** writes what the current filter
matches; **Configure** opens the integration's settings. Looking at the page is not itself
recorded.
