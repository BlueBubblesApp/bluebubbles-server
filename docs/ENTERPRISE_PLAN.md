# Enterprise features: plan

What an operator of a long-running, unattended server expects from it, which of those things
this server has, and which it does not. A brainstorm turned into a ranked list that an
implementing pass can take one item at a time.

**Status: not built.** Nothing in §2 exists. §1 is what was measured against the tree on
4 October 2026, with the file that proves each line; re-measure before trusting it after a
large change.

The audience is one person running one Mac for their own phones. That shapes the ranking
more than anything else: a feature is worth building here when it makes a silent failure
visible, makes a support request answerable, or makes the install reproducible. Multi-tenant
features (operator accounts, roles, per-team quotas) are listed in §4 with the reason they
are not built, so the question does not get re-asked.

---

## 0. The rules every item below is under

These come from [`CLAUDE.md`](../CLAUDE.md) and are restated because every item touches them.

- **The v1 wire is frozen.** A new endpoint goes in `AdditiveRoutes`
  (`Sources/BBHTTPAPI/`), under `/api/v2`, through the `add-api-route` skill. A field added
  to a v1 response goes in `acceptedDifferences` with a line saying what it is, and is a
  contract from then on.
- **A setting is declared in `SettingsRegistry` and named on the manifest of every service
  that reads it**, through the `add-a-setting` skill. An undeclared read throws.
- **A table in `app.db` is a `SchemaContributor`** in the module that owns it, appended to
  `AppSchema.contributors`. Migrations are append-only.
- **A new subsystem with a lifecycle is a service**, through the `add-a-service` skill:
  manifest first, `typealias Host` naming only the capabilities it uses, registered in
  `ServerComposition`, with a `CompositionTests` test asserting the wiring exists.
- **Never log a secret, never log a person.** A secret renders as `••••`; an address goes
  through `Redaction`; message content, subjects, display names, file names and the public
  URL are never written anywhere a person pastes into an issue. Every record this plan
  proposes (audit rows, delivery history, support bundles) is under that rule, not just the
  log.
- **Alerts go through `BBDiagnostics`, explicitly.** Logging never produces one.
- **Never construct `Process`; never hand-roll a timeout.** `Subprocess` and `withTimeout`.
- **A "never" ships with a source-scanning test** in the same change.
- **British spelling**, and the word rules in [`WRITING.md`](WRITING.md): no `currently`,
  no Latin abbreviations, allowlist and blocklist.

---

## 1. What exists, measured

Each line names the file that proves it. The gaps are what §2 is built from.

### 1.1 Resilience

| Mechanism | Where | Behaviour |
|---|---|---|
| Service start supervision | `Sources/BBServiceKit/ServiceRegistry.swift:396-478` | Exponential, no jitter, **gives up permanently** after `maxAttempts` (`giveUp`, lines 404-415). The budget is per incident. |
| Policies | `HTTPService.swift:85` (1 s → 30 s, 10), `ProxyService.swift:162` (5 s → 120 s, 10), `ChangeDetectionService.swift:20` and `PrivateAPIGatedService.swift:20` (5 s → 60 s, 5) | A pinned `bind_address` that is absent for more than about 2.5 minutes leaves the listener unbound for the life of the process. Recorded as `TODO.md` § "A pinned bind address that disappears". |
| Liveness revival | `ServiceRegistry.swift:481-533`, `ServiceLiveness.swift` | Polls every 60 s; at most 3 revivals per service; the budget resets only on a deliberate start, stop or restart, never with time. |
| Binary tunnels | `Sources/BBProxy/Tunnels.swift:149-192`, `DaemonProcess.swift:43-73` | 10 restarts per 300 s window, then dormant retries every 300 s for as long as the service runs. This is the shape that does not give up. |
| Tailscale | `TailscaleTunnel.swift:395-420` | Same budget, then **gives up permanently**. |
| Helper socket | `Helper/HelperShared/HelperSocketClient.swift:91-92` | 1 s → 30 s, retries for ever, resets on success. |
| FCM | `Sources/BBPushKit/FCMSender.swift:228-262` | 500 ms then 2 s, three attempts, then the push is dropped. |
| Webhooks | `Sources/BBEvents/WebhookSink.swift:147-194, 370` | One `POST`, 15 s timeout, **no retry**; an alert after 10 consecutive failures. |
| Event lanes | `Sources/BBEvents/EventBus.swift:112-127, 209-243` | In memory, 512 per sink, oldest dropped when full, drops counted and logged. Nothing survives a restart. |
| Network observation | `Services/NetworkPathService.swift:8-12` | `NWPathMonitor` runs and publishes; **nothing consumes it**. `NetworkPath.permitsRetry` has no caller. The design is [`NETWORK_AWARENESS.md`](NETWORK_AWARENESS.md). |
| Shared primitives | `Sources/BBCore/AsyncPrimitives.swift:52-118`, `Timeout.swift:47` | `RetryPolicy` has no jitter. `withRetry` is called only from its test. `withTimeout` has four production callers; everything else carries its own. |
| Rate limiting | `Sources/BBAuth/AccessControl.swift:1-21` | Failed authentication only. No per-client request rate on the API, no limit or queue on the send path. |
| Concurrency caps | `HTTPListener.swift:78` (128 connections), `FCMSender.swift:94` (8), `WebhookSink.swift:109-118` (8), `BBMedia/ConversionGate.swift:28` | Present and bounded. |

### 1.2 Observability

| Mechanism | Where | Behaviour |
|---|---|---|
| Log | `Sources/BBDiagnostics/Logging.swift:377-399`, `BBCore/LogDestination.swift:20` | swift-log to a rotating plain-text file (`~/Library/Logs/bluebubbles-server/main.log`, 10 MB × 3) and stdout. One process-wide level, applied live. No JSON option, no per-label level, no time-based retention. |
| Access line | `HTTPServer.swift:294-304` | One `debug` line per request: method, route template, status, duration, client. Invisible at the default level. **No request id.** |
| Request metrics | `Sources/BBHTTPAPI/Middleware.swift:375-400` | `RequestMetrics` counts requests, errors and duration per route. Its doc comment says `GET /server/info` surfaces it; **nothing calls `snapshot()`**. |
| Alerts | `Sources/BBDiagnostics/AlertCenter.swift`, `BBAppStore/AlertRepository.swift` | Persisted in `alert` (500 rows, 30 days), coalesced by `dedupeKey`, logged on raise. Drawer, badge and `GET /alert` only. Out-of-band egress was considered and rejected: `decisions.md` § "Alerts egress through the log, and nowhere else". |
| Log export | `SystemHandlers.swift:221-250`, `Views/LogsView.swift:76`, `NotificationsView.swift:259-265` | Last N lines over the API; copy visible lines; copy one alert's redacted report. **No support bundle.** |
| Crash handling | `Sources/BlueBubblesLauncher/main.swift:105-168` | The launcher relaunches and detects a crash loop. No crash report is captured. |
| Persisted history | `Composition/AppSchema.swift:32-37` | `setting`, `contact*`, `alert`, `device`, `webhook`, `scheduled_message`, `backup`, `blocked_client`, `allowed_client`, `paired_client`, `auth_failure`. **No table records a server start, a settings change or a service failure.** `auth_failure` is created by the schema and **has no writer** (`grep auth_failure Sources` finds only the schema and the migration). |
| Health | `RouteTable.swift:243, 278` | `GET /ping` and `GET /server/info`. No per-service health on the wire; `Service.health` exists and the app reads it. Liveness checks that a pump task is alive, not that it is producing (`decisions.md` § 4f). |

### 1.3 Configuration, secrets and portability

| Mechanism | Where | Behaviour |
|---|---|---|
| Settings storage | `Sources/BBSettings/SettingsSchema.swift:24-30`, `SettingsStore.swift:557-571` | `setting(key, value, type_tag, is_secret, updated_at)`, overwritten in place. The previous value is held in memory only to compute `changedKeys`. **No history.** |
| Layering | `Setting.swift:233-237` | `declaredDefault < persistedStore < configFile < commandLine`. `--set` and `--config` on the CLI (`BlueBubblesServerCommand.swift:48-81`). |
| Config file | `ServerComposition.swift:1038-1062` | `~/bluebubbles.yml`, read as flat `key: value` lines. Not YAML, no validation, unknown keys ignored, secrets accepted in plaintext and taking precedence over the Keychain (`SettingsStore.swift:380-381`). |
| Secrets | `Sources/BBSettings/SecretStore.swift`, `BBPushKit/ServiceAccount.swift:204`, `BBSystem/CertificateStore.swift` | Keychain, code-signature ACL. `app.db` holds only the `is_secret` flag. |
| Export and import | `RouteTable.swift:477-485`, `AdminInterface.swift:272-320` | `/backup/{theme,settings}` stores opaque **client** blobs. `PushInterface.importCredentials` imports Firebase files. The Electron migration (`Migration/MigrationRunner.swift:154-185`) reads the legacy `config` table and nothing else, one way. **No export of server settings, webhooks, allowlist, blocklist, devices or schedules exists.** |
| TLS | `HTTPListener.swift:314-325`, `TLSProvisioning.swift` | NIOSSL when `use_custom_certificate` is on; self-signed renewed, user-supplied never replaced. |
| Retention | `AlertRepository.swift:103-106`, `UploadStore.swift:29-51`, `AttachmentStaging.swift:99-119`, `Logging.swift:271` | Alerts, uploads, staging and the log are bounded. Finished scheduled messages are deleted only on demand. `setting` and `backup` rows never are. |

### 1.4 Integration and operations

| Mechanism | Where | Behaviour |
|---|---|---|
| Webhook payload | `WebhookSink.swift:8, 360` | `{"type","data"}`, `Content-Type` only. **No signature.** No delivery history (`WebhookDeliveryTracker` keeps the last outcome and a consecutive-failure count, in memory). |
| Scheduled messages | `Services/ScheduledMessageService.swift:73-186` | 60 s poll, due rows sent on start, claim-before-send. A failed one-shot is `failed` with no retry; a recurring one skips missed occurrences. |
| Auth modes | [`AUTH.md`](AUTH.md) § 1 | One shared password grants every scope. Token mode is dormant and its device store is in memory (`ServerComposition.swift:601-604`), so the persisted `paired_client` table is unused. |
| Client attribution | `ClientActivityTracker.swift`, `InterfacesSchema.swift:53-59` | One global last-seen timestamp; `device.last_active` for FCM tokens. **Nothing records which client, from where, with which credential.** `TODO.md` § "Auth usage telemetry does not exist". |
| CLI | `BlueBubblesServerCommand.swift:48-81` | Seven flags, **no subcommands**: no `status`, `doctor`, `config`, `logs`. swift-argument-parser is already a dependency. |
| Updates | `Models/SparkleUpdater.swift`, `SettingsRegistry.swift:522-589` | Sparkle, beta channel, scheduled install hour, Ed25519 appcast. No rollback. |
| Maintenance | `UploadStore.swift`, `ServiceSettingsBridge.swift:242`, `--clear-blocklist` | Per-service reset, sweeps. **No `integrity_check`, no `VACUUM`, no copy of `app.db`.** |
| Proactive monitoring | `Services/PermissionsMonitorService.swift` | Alerts when macOS revokes a permission while running. **Nothing watches whether Messages.app is running, whether iMessage is signed in, or whether change detection has produced anything lately.** |
| OpenAPI | `Package.swift:880, 936`, `Views/APIDocsView.swift` | Rendered in the app from an in-process document. The running server serves no `/openapi.json`. |

---

## 2. What to build, ranked

Ranked by how much a single operator gains per unit of work. Each item says what it is, the
failure it prevents, what "done" looks like, where it hooks in, and what it must not do.
Items marked **small** are one sitting; **medium** is a service or a table plus a page;
**large** touches several modules.

### 2.1 Audit journal — medium

**What.** An append-only `audit_event` table in `app.db`, written at every point where the
server's own state changes, readable as a running list in the app, over the API, and from
the CLI. Not an access log and not a second alert drawer: it answers "what changed, when,
and from where", which nothing else answers.

**The failure it prevents.** A setting that was changed weeks ago by a tap in the client, a
service that was disabled by a migration, a blocklist entry that arrived at 3 a.m. — each is
a mystery the log has rotated away. The operator's own memory is the only record.

**Rows.** `id`, `at`, `category`, `action`, `subject`, `actor`, `detail` (JSON, small),
`outcome`. Categories and the hook that writes each:

| Category | Actions | Hook |
|---|---|---|
| `setting` | `changed` | `SettingsStore.write` already computes `changedKeys` (`SettingsStore.swift:439-593`); emit one row per key with the old and new value. **A secret's values are both `••••`**: the row says it changed and nothing else. `log_level` changes are worth a row because they explain where the log gets noisier. |
| `service` | `started`, `stopped`, `failed`, `gave-up`, `revived`, `enabled`, `disabled` | `ServiceRegistry.performStart`, `giveUp`, `revive`, the enable switch. |
| `server` | `started`, `stopped`, `restart-honoured`, `updated` | `ServerComposition` start and stop (`:1009-1025`), the remote-restart watcher, Sparkle's install hook. |
| `auth` | `blocked`, `unblocked`, `allowlisted`, `throttled`, `password-changed`, `device-registered`, `device-revoked` | `AccessControl`, `TokenAuthService`, `DeviceDirectory`. Addresses through `Redaction.address`; a client IP is logged as `client` per the existing rule. |
| `admin` | `webhook-created`, `webhook-deleted`, `schedule-created`, `schedule-deleted`, `blocklist-cleared`, `reset-to-defaults`, `config-imported`, `config-exported`, `bundle-exported` | The interfaces in `Sources/BBInterfaces/`, never the handlers, so the app and the API share the row. |
| `permission` | `granted`, `revoked` | `PermissionsMonitorService`. |

**Actor.** An enum, not free text: `app`, `cli`, `api(client: <redacted address>)`,
`system`, `migration`, `remote-restart`. The API case is the one that needs plumbing: the
handler knows the peer and the interface does not. Pass it down as a value on the request
context, the same way the handler already carries the authenticated scope.

**Surface.** A `TablePage` in the app (`Views/Components/SettingsLayout.swift`, never
`SettingsPage` for a table) with a category filter and a date range;
`GET /api/v2/audit?since=&category=&limit=` in `AdditiveRoutes`, `server:admin` scope;
`bluebubbles-server audit --since 7d` on the CLI (§2.10). Retention is a declared setting,
default 90 days, pruned on the same cadence as alerts (`AlertCenter.swift:427-433`).

**Must not.** Record message content, chat identifiers, file names or the public URL; those
are the rules in [`architecture.md`](../.claude/docs/architecture.md) § Diagnostics and they
bind the `detail` column exactly as they bind log metadata. Extend
`LogRedactionPolicyTests` or add a sibling that scans every `AuditJournal.record(` call site
the same way. Do not raise an alert from the journal; the two are different systems.

**Why not reuse `alert`.** An alert is a condition that wants a person's attention and
coalesces repeats; a journal row is a fact that happened once. Putting ordinary settings
changes in the drawer is what makes a drawer unreadable.

### 2.2 Configuration export and import — medium

**What.** One JSON document that captures a server's configuration, and an import that
applies one with a diff shown first. The document is the server's, not a client's: the
existing `/backup/settings` route stores client-app blobs and stays as it is.

**The failure it prevents.** Rebuilding a Mac, moving to a second one, or recovering from a
corrupt `app.db` means re-entering every setting, every webhook, the allowlist and the
Firebase credentials by hand, from memory, and getting one wrong.

**Document.** Versioned (`schemaVersion`), with sections: `settings` (every non-secret key
with a value that differs from its declared default, by storage key), `services` (enablement
and per-service fields), `webhooks`, `accessControl` (allowlist and blocklist),
`scheduledMessages` (optional, off by default: they carry recipients). Secrets are NOT in
the document by default. A `--include-secrets` flag writes them, prints a one-line warning,
and names the file in the audit journal; the Firebase service account and client config
export the same way, since `importCredentials` already exists for the other direction.

**Import.** Validate against `SettingsRegistry` first: an unknown key, a type mismatch or a
value a setting's validation refuses is a refusal before anything is written, listing every
problem rather than the first. Then show the diff (key, stored value, incoming value) and
apply only on confirmation, through `SettingsStore.write` so that `watchedSettingKeys`
restarts fire and the journal records it. Never write `app.db` rows directly.

**Surface.** Export and import buttons on the settings page; `bluebubbles-server config
export [--include-secrets] > file` and `config import --dry-run file` on the CLI;
`GET /api/v2/config/export` under `server:admin` **without** secrets and with no flag to
include them, because a credential that can leave over the API is a credential that leaves
with a stolen password.

**Relation to the config file.** `~/bluebubbles.yml` is read as flat lines and is not YAML.
Either the export format becomes the config-file format (JSON, validated, the same loader)
or the two stay separate with a sentence in the header saying why. Making them the same
thing is the cheaper and the more honest option; see §2.11.

### 2.3 Support bundle — small

**What.** One button, one CLI flag and one `server:admin` route that produce a zip
containing: the current and rotated log files, the alert history, the audit journal,
`GET /server/info`, the per-service health table, the macOS and build versions, the Private
API state (helper connected, architecture, injected or not), the permission grants, the
tunnel kind and state, and the configuration export from §2.2 with secrets excluded. Every
file passes through the same redaction the log already does.

**The failure it prevents.** A support thread that goes six rounds of "can you also send
me…". The pieces all exist; nothing collects them.

**Must not.** Include the public URL (`ProxyCoordinator` and `ServerAddressAnnouncer`
already omit it on purpose), chat identifiers, or anything from `chat.db`. Build the archive
with `Subprocess` running `zip` or with Foundation; never `Process`.

### 2.4 Retry that never becomes permanent — medium

**What.** Close the gap the surveys found between the design in `decisions.md` § 4a ("a
transient failure must never become a permanent one") and what the registry does: the
tunnel daemon goes dormant and keeps trying, the registry's own supervision does not.

**Steps.**

1. `ServiceRegistry.supervise` adopts the `DaemonProcess` shape: after `maxAttempts` the
   policy decides the **interval**, not whether to continue. A `dormantDelay` on
   `RestartPolicy` (default 300 s), an alert when entering dormancy, and the alert withdrawn
   on the first successful start. `HTTPService` is the case that matters; a bind to a
   vanished address keeps asking every five minutes until the address is back.
2. `TailscaleTunnel` stops giving up permanently, for the same reason.
3. `NetworkPathService` gets its consumer: a path change that makes `permitsRetry` true
   skips the dormant wait for services that are dormant **and nothing else**. The rule in
   [`NETWORK_AWARENESS.md`](NETWORK_AWARENESS.md) § 4 is binding: a network change is
   permission to retry what is broken, never an instruction to restart what works.
4. Jitter on `RetryPolicy.delay(forAttempt:)`: full jitter, so six tunnels coming back after
   a router reboot do not all fork at the same instant. `RetryPolicyTests` pins the bounds.
5. The liveness revival budget (`ServiceRegistry.swift:481-533`) refreshes with time, on the
   same window arithmetic the daemon uses, rather than only on a deliberate action.

**Must not.** Reset a budget on success alone; the reason is written at
`decisions.md` § 4a and it is the flapping-tunnel loop. Restart a working service on a path
change.

### 2.5 Health endpoint and staleness watchdog — medium

**What.** `GET /api/v2/health` in `AdditiveRoutes` for an external monitor (Uptime Kuma,
healthchecks, a cron with `curl`), and the one check the liveness poll cannot make: whether
change detection has **produced** anything.

**Response.** Status `200` when every required service is `.running`, `503` otherwise, so
a monitor needs no JSON parsing. Body: uptime, per-service `health` and `isAlive`, Private
API connected, `chat.db` readable, Messages.app running, iMessage signed in, last
change-detection tick and last detected change, tunnel state, listener address kind (never
the URL), event lane depths and drop counts since start. Unauthenticated callers get the
status code and `{"status":"ok"|"degraded"}` only; `server:admin` gets the body. Nothing in
it is PII.

**Staleness.** `ChangeDetectionService` records the time of its last successful tick and
last detected change. A tick that has not completed within three poll intervals is
`.degraded` with a reason, and raises a coalescing alert ("Message detection has stalled");
the alert is withdrawn on the next tick. This is the "messages stopped arriving" symptom
`decisions.md` § 4f describes, which liveness alone cannot see.

**Messages.app and sign-in.** A monitor (in `PermissionsMonitorService` or beside it) that
checks `NSRunningApplication` for Messages and, with the Private API, the account state, on
the liveness cadence. Alert on transition only, withdrawn on recovery.

### 2.6 Heartbeat to an external monitor — small

**What.** A setting `heartbeat_url`, empty by default. When set, the server sends a `GET`
to it on a declared interval (default 5 minutes) while `GET /api/v2/health` would answer
`200`, and does not send while it would answer `503`. That is the whole feature.

**The failure it prevents.** The one `decisions.md` § "Alerts egress through the log"
names and leaves open: on an unattended install every alert surface is behind the listener
that is down. A dead-man's switch inverts it: silence is the alarm, and the alarm is raised
by a service that is not this server. It costs nothing when unset, adds no delivery path for
alert bodies, and respects the decision not to push alerts over FCM or ntfy.

**Must not.** Send anything but the request: no body, no server identity beyond what the
URL's owner put in it. Log the URL through `Redaction.url`. Follow redirects: no, for the
reason the webhook does not. It is a service (`HeartbeatService`, `.integration`
category, depends on `http`) so it has a manifest, a form and an enable switch.

### 2.7 Durable webhook delivery — medium

**What.** Retry, a signature, and a delivery history for webhooks, each per target and each
additive on the wire.

- **Retry.** Up to a declared number of attempts on a transport error, a `429` or a `5xx`,
  with jittered backoff and the existing 15 s per-attempt timeout; a `4xx` other than
  `429` is final. The attempts live in the sink's own lane so a slow target cannot stall the
  bus (`EVENTS.md` § "`emit` does not protect the caller" is the rule).
- **Signature.** An optional `secret` on a webhook; when set, `X-BlueBubbles-Signature:
  sha256=<hex HMAC of the body>` and `X-BlueBubbles-Timestamp`. The secret is a declared
  secret: Keychain, never in the `webhook` row, `••••` in every log and journal line. The
  wire fields on `POST /webhook` are additions in `acceptedDifferences`; a v1 client that
  omits them changes nothing, which is the same "absent means leave it" rule
  `follow_redirects` already follows.
- **History.** A `webhook_delivery` table: target, event name (not payload), attempt
  count, final status, duration, failure reason, finished at. Bounded (last 1,000 rows or
  7 days). Shown under the webhook in the app with a "resend" action that re-posts from
  the stored event **only if the payload is kept**, which it is not by default because it
  is message content; without it, "resend" is a `hello-world` test send, which exists.

**Must not.** Persist payloads by default. Change the `{"type","data"}` body.

### 2.8 Metrics — small, after §2.5

**What.** Make the counters that exist readable, then add the ones that matter.

1. `RequestMetrics.snapshot()` has no caller and its doc comment says `/server/info`
   surfaces it. Either surface it there (an addition, in `acceptedDifferences`) or on
   `/api/v2/health`, and fix the comment. A comment that claims a wire fact nothing serves
   is the exact shape `CLAUDE.md` rule 8 warns about.
2. Counters for: events dispatched and **dropped** per lane, webhook and FCM outcomes,
   sends and their latency, change-detection tick latency, Private API request latency and
   timeouts, conversion gate waits. In-process, with `swift-metrics` as the API so a
   backend is a composition-root choice.
3. A `/metrics` route in OpenMetrics text format behind a setting (`metrics_enabled`,
   off), `server:admin` scope. For one operator a Grafana is overkill; the setting exists
   so the counters can be read by anything, and so they are not a second UI.

### 2.9 Structured log and request id — small

**What.** `log_format` setting (`text` default, `json`), a request id on every request,
and time-based log retention.

- The id is read from `X-Request-Id` when a client sends one, minted otherwise, echoed in
  the response header, and carried in the logger metadata for the whole request so every
  line a request produces can be found from the access line. Additive: a header is not a
  body.
- The access line stays `debug` for `2xx` and moves to `info` for `4xx` and `5xx`, with
  the route template and never the path, per the existing rule.
- Per-label level overrides (`log_level_overrides`, a map of label to level) so
  `bluebubbles.events` can be `trace` while the rest stays `info`.
- Rotation by age as well as size: a declared `log_retention_days`, default 14.

### 2.10 CLI subcommands — medium

**What.** Replace the seven flags with subcommands under swift-argument-parser, keeping the
flags as hidden aliases for one release so a launch agent someone wrote does not break.

| Subcommand | Does |
|---|---|
| `run [--headless] [--config] [--set]` | What the bare command does without a subcommand. |
| `status` | Calls `GET /api/v2/health` on the local listener with the Keychain password and prints the table. Exit code mirrors the status code. |
| `doctor` | Offline preflight: Full Disk Access, Automation, Contacts, Keychain readable, `chat.db` openable, port free, helper slices (`lipo`), Messages.app present, SIP state, tunnel binary and version. One line per check, pass or fail with the fix. Nothing here needs the server running. |
| `config export \| import \| diff` | §2.2. |
| `audit [--since] [--category]` | §2.1. |
| `logs [--follow] [--level]` | Tails `main.log`. |
| `bundle` | §2.3. |
| `clear-blocklist`, `migrate`, `check-keychain` | The existing flags, as verbs. |

**Must not.** Reach `AppContext`; each subcommand takes the capability it needs, the same
rule the services are under. `doctor` must not start services.

### 2.11 Validated configuration file — small, with §2.2

**What.** The config-file loader (`ServerComposition.swift:1038-1062`) accepts anything
and ignores what it does not know. Make it the §2.2 import format, validated against the
registry on load: an unknown key or a type mismatch is logged at `warning` with the key,
and refused rather than silently dropped when `--strict-config` is set. A secret in the
file is accepted and logged once at `warning` as "a secret was supplied outside the
Keychain", because that is a choice an operator should see they made. Environment overrides
(`BB_SETTING_<KEY>`) are cheap once the layering exists and are the standard for anything
run under launchd; they go above the file and below the command line.

### 2.12 `app.db` care — small

**What.** `PRAGMA integrity_check` on open with an alert on failure; a `VACUUM INTO` copy
of `app.db` on a declared schedule (default daily, keep 7) in the support directory; a
restore path that is the §2.2 import of the settings plus a file copy, documented in the
same header. Finished scheduled messages pruned on the alert cadence.

**Must not.** Touch `chat.db`; it is Apple's and read-only by construction. Claim a copy
of `app.db` is a full backup: the secrets are in the Keychain and the header says so.

### 2.13 Client attribution — small, with §2.1

**What.** Write the `auth_failure` table that exists and has no writer, and add a
`client_session` table: redacted address, credential kind (password, token with device id),
user agent family, first seen, last seen, request count. One row per distinct client, not
per request. This is `TODO.md` § "Auth usage telemetry does not exist", and it is the
evidence any future `auth_mode` decision needs. Surfaced on the devices page and in the
support bundle.

**Must not.** Record paths or query strings. Count successful requests into any rate
limit; the limiter counts failures only, deliberately (`decisions.md` § "The rate limiter
counts an address the peer told us about").

---

## 3. Suggested order

Each row is one pull request. The order puts the record-keeping first because every later
item writes to it, and the resilience fix second because it is the one defect a user meets.

| # | Item | Depends on |
|---|---|---|
| 1 | §2.1 Audit journal | — |
| 2 | §2.4 Retry that never becomes permanent | — |
| 3 | §2.5 Health endpoint and staleness watchdog | — |
| 4 | §2.6 Heartbeat | 3 |
| 5 | §2.2 Configuration export and import, with §2.11 | 1 |
| 6 | §2.3 Support bundle | 1, 3, 5 |
| 7 | §2.7 Durable webhook delivery | 1 |
| 8 | §2.9 Structured log and request id | — |
| 9 | §2.8 Metrics | 3 |
| 10 | §2.10 CLI subcommands | 1, 3, 5, 6 |
| 11 | §2.12 `app.db` care | 5 |
| 12 | §2.13 Client attribution | 1 |

A change is done when the five checks in [`CLAUDE.md`](../CLAUDE.md) § Fast commands pass
and the module's `CLAUDE.md`, file headers and this document are updated: an item that
ships moves from §2 to §1 with the file that proves it, and §1's measurement date moves
with it.

---

## 4. Considered and not built

Listed so the question is not re-asked. Each can be reopened by a concrete need.

- **Operator accounts and roles.** One person runs this server. Scopes exist on the
  dormant token path and are the right primitive if a second operator ever appears; a role
  model on top of a single shared password would be a UI with nothing behind it.
- **Pushing alerts to a phone.** Rejected with reasons at `decisions.md` § "Alerts egress
  through the log, and nowhere else". §2.6 is the answer that respects them.
- **A persistent outbox for socket events.** An event nobody was connected for is gone
  either way, and replay is strictly opt-in (`EVENTS.md` § "Replay is strictly opt-in").
  Webhooks get retry (§2.7); sockets do not get a queue.
- **A send queue with its own rate limit.** The send path is bounded by Messages, and
  per-`tempGuid` dedupe is the guard that matters (`TODO.md` § "A retry can still send
  twice"). A queue would change what a client observes about a send's timing.
- **Update rollback.** Sparkle has none; keeping the previous bundle beside the current one
  is possible and is not worth a release of its own until an update has broken something.
- **Serving OpenAPI from the running server.** The app renders it and CI publishes
  `docs/api/openapi.json`; a `/openapi.json` route is one line in `AdditiveRoutes` if a
  client ever asks for it.
- **Persistent device store for token mode.** The table exists; the mode is dormant.
  Wire `paired_client` when the mode is switched on, not before.
- **Secret rotation with a grace window.** Requires a client change; see
  `decisions.md` § 3.
