# Databases

There are **two**, and confusing them is the most expensive mistake available in this codebase.
Domain rules for the data inside `chat.db`: chat GUIDs, typedstream, the send path, are in
[`imessage.md`](imessage.md).

| | `app.db` | `chat.db` |
|---|---|---|
| Owner | Us | Apple / Messages.app |
| Path | `~/Library/Application Support/bluebubbles-server/app.db` | `~/Library/Messages/chat.db` |
| Type | `AppDatabase` | `ReadOnlyDatabase` |
| Access | Read **and** write | Read only, **by construction** |
| Schema | Ours; linear migrator | Apple's; changes per macOS release, in both directions |
| Second writer | No | **Yes: Messages, constantly** |

Both live in `Sources/BBPersistence/`.

---

## `chat.db`: read-only, and structurally so

`ReadOnlyDatabase` (`Sources/BBPersistence/ReadOnlyDatabase.swift`) exposes **no write API at
all**: no `write`, no `execute`, no migrator, and no way to get at the underlying
`DatabaseQueue`. A write does not compile.

The guarantee is structural rather than a flag, because a flag is the thing that fails: a
`readonly: true` configuration option can be dropped, overridden, or forgotten in a new code path,
and nothing catches it until a user's message history is corrupted, which is unrecoverable.
**Do not add a write path, a raw-queue accessor, or a one-off escape hatch.**

Other properties that look like omissions and are not:

- **`immutable` is deliberately NOT set.** It promises SQLite the file cannot change, which is
  false while Messages is running, and yields stale reads or corruption. We need live WAL
  content and pay for it.
- **`maximumReaderCount = 1`.** One connection, not a pool: lower memory on the old hardware
  this targets, and a reader needs no concurrency against a database it never writes.
- **Checkpoint, `VACUUM`, `ANALYZE`, `REINDEX` and temp indexes are all writes.** Several of
  them look harmless and none of them may touch `chat.db`.
- **`readCursor` exists, and unbounded queries must use it.** `fetchAll` on a large message
  query makes resident memory scale with the size of the user's message history.

### Never `SELECT *`

Apple changes the schema in both directions:

- Sonoma **adds** 6 message columns (`is_critical`, `is_kt_verified`, `is_sos`, `is_stewie`,
  `bia_reference_id`, `fallback_hash`)
- Sequoia **adds** 6 more (`schedule_state`, `schedule_type`, `associated_message_emoji`,
  `needs_relay`, `is_pending_satellite_send`, `sent_or_received_off_grid`)
- Sequoia **removes** `message_processing_task`, which Sonoma has

So a profile cannot be a version number, and a `SELECT *` takes the whole query down when a
column vanishes. `SchemaProfile` (`Sources/BBIMessage/SchemaProfile.swift`) introspects the
columns at runtime; **every query names what it wants.**

`SchemaProfile` also carries `dateUnit`: High Sierra switched `chat.db` from seconds to
nanoseconds, and getting it wrong produces dates that look plausible and are decades off. Use
`BBCore`'s Apple timestamp helpers; never hand-roll the epoch maths.

### Read a cell through `MappedRow`, never `row["x"]`

This applies to every database another process writes: `chat.db`, the sticker store
(`StickerRepository`) and the call log (`CallHistoryRepository`, in BBSystem).

SQLite does not enforce a column's declared type, and GRDB's typed `Row` subscript decodes
with `try!`. A `text` cell holding a BLOB that is not UTF-8 therefore ends the process, and
the search indexer reaches every row in the background. `MappedRow`
(`Sources/BBPersistence/MappedRow.swift`) is the reader: `required` throws `RowReadError`
for an identity cell, and `optional` reads a mistyped cell as NULL and warns once per column
per store (the reasoning is in the `MappedRow` header). Get one from `mapRows(in:)` or
`Row.mapped(in:)`, passing the `RowSource` of the store, which is how a warning or an error
names the file that held the bad cell. Each owning module declares its own:
`.chatDatabase` and `.stickerStore` in BBIMessage, `.callHistory` in BBSystem.
`RowSubscriptPolicyTests` fails the build on a raw string subscript in any file that holds a
`ReadOnlyDatabase`, together with its `+` extensions. A value fetch (`Int64.fetchAll`,
`String.fetchOne`) throws rather than traps and needs no wrapper.

### Chat GUIDs

Never compare with `==`, never derive a service from the prefix, never write a literal
`c.guid = ?`. They differ between servers on the same iCloud account, and macOS 26 rewrote every
prefix to `any`. Use `ChatGUID.lookupCandidates()` in queries. Full rules:
[`imessage.md`](imessage.md#chat-guids-the-single-most-dangerous-thing-in-this-codebase).

### `SchemaProfile` drives the wire format

**A field absent from the schema must be ABSENT from the JSON, not null.** Clients distinguish
the two. This is why serializers consult the profile rather than checking for `nil`, and why
moving a `serialize` call between layers cannot change the bytes.

### A small ROWID window is sorted, not found by walking the date index

The incremental sync asks `/message/query` for `message.ROWID > n`, newest first, a thousand at
a time. Ordered by `m.date`, SQLite walks `message_idx_date` from the newest entry and tests
each ROWID. That stops after `offset + limit` matches, so a window too small to fill the page
reads the entire index: 1,803 pages on a 427,661-message database, against 25 for seeking the
window and sorting it. On a spinning disk those are random reads on the only connection, and
every other client waits behind them. Apple's `sqlite_stat1` does not change the choice.

`MessageQueryPlan.sortsRowIDWindow` switches the listing to `ORDER BY +m.date` (the unary plus
stops an index supplying the order) when the window cannot fill the page, and only while the
window is under about 1/64 of the table. A wider window keeps the walk, which stops early when
the new rows are the newest. `RowIDWindowPlanTests` asserts the decision, the plan on each
committed fixture, and that the rows come back in date order either way.

### A date window on one conversation uses the join's copy of the date

`chat_message_join.message_date` is a copy of `message.date`, and Apple's
`chat_message_join_idx_message_date_id_chat_id` covers it together with the chat. A window on
`m.date` cannot use that index, so a chat-scoped count with `after` or `before` (the total
beside every page a full sync reads) touched every message row in the conversation: 34,545
pages for a 55,795-message chat, against 334 counted from the join. A narrow window on the
listing walked the whole chat from one end testing `m.date`: 34,476 pages for the last month,
against 28.

- **The count** (`MessageQuery.countsFromTheJoin`) is answered from the join alone when the
  query is one conversation with at most a window on the sent date. A receipt window
  (`count/updated`) cannot be: the join has no copy of those dates.
- **The listing** windows `cmj.message_date` IN ADDITION to `m.date`, never instead. The join's
  half lets SQLite seek the range; the `m.date` half still decides exactly which rows are on
  the page.
- **Both depend on the copy being trusted**, which `joinDatesCanOrderAChat` asks of the
  database once (no zero or null copy), exactly as the chat ordering does. A database that
  fails it keeps the message-table forms.

What the trust rests on, measured: the column and the index are present on Sonoma and on
macOS 27; on 27, all 423,850 join rows agree with their message, history migrated from older
releases included; and scheduling then rescheduling a Send Later message moves both copies
together within a second. Not measured: the values on a Sonoma database with history.
`JoinDateWindowTests` holds the counts exact at both inclusive edges, the plan, and the
fallback; `CountAndScheduleQueryTests.countsAgree` compares every count shape with the
message-table form.

### Change detection

`Sources/BBIMessage/ChangeDetector.swift` turns chat.db activity into message events and
`chat-read-status-changed`. The file watcher is `DatabaseFileWatcher.swift`, and the ledgers
carried between ticks are `ChangeDetector+State.swift`. It never
polls the table on a quiet Mac. Two signals, in a fixed order of trust:

1. **Primary: kqueue vnode events** on `chat.db` and `chat.db-wal`, through `DispatchSource`,
   on descriptors the process holds open. The kernel delivers them directly: no fseventsd, no
   coalescing daemon. A WAL write queries within the debounce, a fixed 500ms floor between
   ticks that is not a setting. This is where every message normally arrives from.
2. **Backup: `PRAGMA data_version`, every `db_poll_interval`.** SQLite bumps it on the reading
   connection whenever any other connection commits, and answering reads the WAL index out of
   shared memory: microseconds, no disk, no file-system event required. Unchanged means
   nothing was committed and **no query runs**. Changed means the watcher missed something,
   and the query runs then. The same pass re-arms a sidecar that did not exist at startup.

`db_poll_interval` is the Electron server's poll-period key, kept for migration, and it now means
the backup period: default and minimum 30 seconds. A legacy value below that is raised and a
higher one is kept, and `ChangeDetectionService` clamps whatever it reads, so an install that
stored a sub-30s value under the old meaning cannot come up polling. **Do not shorten it into a
poll**: the backup is the safety net, and its interval costs only latency in the one case the
watcher failed.

The Electron server had only FSEvents, and on some Macs those stop arriving once the disk has
been idle; users wrote "pokers" that touched `chat.db` to wake it. Neither applies here: the
backup needs no file-system event at all, and a quiet Mac costs one shared-memory read every 30
seconds. `data_version` is only comparable on the SAME connection, which
`ReadOnlyDatabase.changeToken()` guarantees: a pooled reader keeps a sentinel connection aside
for the question, because a pool hands `read` whichever reader is free.

Two refinements in the stream loop:

- **A file wake that finds no commit is re-checked once**, after the floor plus 250ms. kqueue
  reports the WAL write before SQLite publishes the commit to readers, so an early wake can
  query and see nothing; without the re-check that message would wait for the backup pass.
- **A wide pass owed is a reason to tick.** The fast pass reads the last half hour by send
  date, so a read receipt or an edit on an older message is visible only to the seven-day pass,
  which runs at most every five minutes. The fast tick that reads the commit consumes it and
  sees nothing, and the backup pass used to tick only on a NEW commit, so the receipts waited
  for whatever wrote to chat.db next, half an hour on a quiet Mac, and then arrived together.
  The backup pass now also ticks when the wide pass is due and something was committed since
  the last one (`ChangeDetector.isReconcileOwed(now:)`): still a memory read, never a query,
  and owed once per commit, so a quiet Mac never ticks for it.
- **A deaf watcher heals itself.** Three consecutive backup passes that find a commit no file
  event announced means the descriptors are stale or events stopped arriving. The watcher is
  torn down and re-armed, and a warning names the watched paths. That log line is what to look
  for on a Mac that used to need a poker.

**What a tick reads.** `MessageRepository.messageFingerprints`: ROWID, GUID and the nine
fields that can move, never the full row. The 70-column row with its attributed-body and
payload blobs is hydrated by `messages(rowIDs:)` only for the rows whose fingerprint changed.
Pages are keyset-resumed on `(date, ROWID)`, not `OFFSET`: OFFSET re-walks the skipped rows on
every page and shifts when Messages inserts mid-walk. `ChangeDetectorTests` asks SQLite for the
plan of both page shapes and fails if either leaves `message_idx_date` or sorts. The fingerprint
cache holds 25,000 entries, more than the 20,000-row page budget, because a cache smaller than
the window forgets fingerprints on every wide pass, and a forgotten fingerprint is an update
that can no longer be detected. `BoundedCache` evicts in O(1) for the same reason.

**What counts as new.** A GUID the cache has not seen, dated after the cursor OR within the
30-minute fast window of now. The second clause is the late arrival: a row carries the time the
message was sent, and after a network outage the backlog lands dated inside the gap, all of it
older than the cursor: under the cursor rule alone none of it raised an event. Anything older
than both is history (iCloud backfill, a re-synced device) and is cached silently; a late
arrival older than 30 minutes is therefore treated as history too, and that constant is the
line. **The first tick announces nothing.** On startup or restart the cache is empty and
everything in the window is unseen; re-announcing the last half hour on every restart was the
bug users noticed. A client that missed something syncs.

**A new message waits for its chat.** Messages commits the message row first and the
`chat_message_join` row in a later commit, and the first write is what wakes the detector. A real
send through a server with no hold went out as `new-message` with `chats: []`, which the client's
handler throws on, because it reads `chats.first` unchecked. So each tick asks
`messageRowIDsWithChat(among:)` about the rows it is about to announce, and a new one with no join
goes into `HeldArrivals` and is offered again on the next tick. The join's own commit is what
wakes that tick. The wire rule is the reference's: its poll INNER-joins the chat, so a row with
no chat is not returned at all, and a later poll returns it once the join exists.

The rest is this server's, and each part prevents a specific failure:

- The ROWID mark moves over a held row, so nothing behind it waits, and the row leaves the hold
  exactly once, so it cannot be announced twice.
- A receipt on a held row is not announced. Its `new-message` is built from the row as it stands
  at release, so it already carries the receipt. A failed send is the exception: the `error`
  column moving is remembered and raised as `message-send-error` straight after the
  `new-message`, because a client hears of a failure from that event and no other.
- After `maximumHold` a held row is given up on with a warning: cached, not announced, and not
  announced later if a join does land. It is one limit for whatever the row is waiting on, and a
  row keeps the time it was first held across every retry. The join is read before the bound is
  applied, so a late tick cannot discard a message whose chat arrived.
- A change to any other row with no chat is dropped, because `updated-message` reads
  `chats.first` too. A live `chat.db` holds rows like that.
- The hold is counted into `maximumAnnouncedPerTick`, ahead of the check, which is what bounds it.
- A failed read of the join table holds the new rows and lets updates through.
- A failed read of the rows being announced holds the new ones too, and still returns the tick's
  chat reads. The updates in it are lost and counted in the warning, and a client's sync has them.
- `EventHydrator` sends no event for a message whose chats it cannot read or that has none, which
  takes a read failing just after the gate's succeeded. That message waits for a client's sync.

The attachment link needs no gate of its own on what was measured: on two outbound sends it
landed in an earlier commit than the join, in the same commit as `cache_has_attachments`, so
waiting for the chat also waits for it. An INBOUND attachment or sticker has not been measured,
and neither has an inbound row's gap to its join. The reference's attachment join is a LEFT join
and holds nothing back.

**What counts as updated.** A stored fingerprint whose delivered, read, played, edited,
retracted or error field moved, whose `did_notify_recipient` went false to true, or whose
`associated_message_type` moved: Messages rewrites the turn an iMessage-app session update
supersedes to 3 when the update lands, on this Mac as well as on the phone, for turns this
server sends too, and nothing else in that row changes (`docs/GAME_PIGEON.md` § 4). The event
carries the row as hydrated, which can be newer than the fingerprint that was compared; the
next tick then reports that later move as an update. Nothing is lost, and a tick that throws
records nothing: not the change token, not the wide pass, so the next pass retries.

**What counts as a chat read.** The same tick reads `ROWID`, `guid` and
`last_read_message_timestamp` from `chat` (`chatReadMarks(readAfter:)`) for chats read inside
the fast window, and announces a chat whose value INCREASED, or that has no entry in the ledger
(`ChatReadLedger`). The second is safe only because the window's floor never falls: the
baseline cached every chat in it, so a chat can enter afterwards only by being read. Neither the
reconcile pass's seven days nor a clock stepped backwards may lower it, or every chat they
uncovered would be announced as just read. The ledger is keyed by chat ROWID, never by GUID.
`ChangeDetectionService.announce(chatReads:)` emits each as the reference's
`{ chatGuid, read: true }`, and that covers the mark-read route too: on macOS 27 a mark-read
moved the column to the moment of the read and produced exactly one event. Mark-unread does
NOT move it (the message's `is_read` changes, the chat's column does not), so
`ChatInterface.markUnread` emits `read: false` itself. The helper observes no read state.

Four further behaviours are load-bearing: changing any of them loses messages:

- **The dual lookback**: a 30-minute fast window every tick (Apple only permits edits within
  ~15 minutes and unsends within ~2), widening to a full 7 days every 5 minutes to catch read
  receipts and notification flags on older messages. The wide pass is **skipped when nothing
  has been committed since the last one**: a receipt is a commit, so it never runs on a
  quiet Mac.
- **Query by `date`, filter the other timestamps in memory.** `date` is the only one of them
  with an index in Apple's schema and we cannot add one, so an `OR` across all of them
  full-scans `message`.
- **The >24h clamp**, so a machine that slept for a week does not replay a week as new messages.
- **Watching the `-wal` sidecar**, not just the database file. SQLite in WAL mode appends there
  and checkpoints later; watching only `chat.db` misses most activity. `-shm` is not watched:
  SQLite writes it through `mmap`, which raises no vnode events.

`Tests/BBIMessageTests/DatabaseFileWatcherTests.swift` covers the watcher against real files
(late sidecar, replaced file). `ChangeDetectorTests` covers the backup pass, the gated
reconcile, the query plan, keyset paging across a mid-walk insert, the silent first tick, late
arrivals, backfill, and the primary path end to end through a real vnode event.
`ChatReadDetectionTests` covers chat reads, including the windows that must not replay one.

Develop against fixtures, never your own messages:

```bash
python3 Tools/chatdb-fixtures/generate.py --out Tests/BBIMessageTests/ChatDBFixtures
```

Writes deterministic `chat-ventura.db`, `chat-sonoma.db`, `chat-sequoia.db` covering direct and
group chats, an attachment, a reaction, a threaded reply and an edited message. Regeneration is
byte-identical, so they never show up as diff noise. They are gitignored; rebuild, do not
commit.

---

## `app.db`: ours

`AppDatabase` (`Sources/BBPersistence/AppDatabase.swift`), GRDB, foreign keys on, opened and
migrated by `AppDatabase.open(at:)`. `AppDatabase.inMemory()` for tests.

### The access surface is `read`, `write` and `observe`, and the omission is the point

`observe(_:)` is a read that GRDB re-runs after every commit touching what it read, returned
as an async sequence whose first element is the current value. It is how a screen follows a
table instead of re-reading it on a timer: `WebhookRepository.changes()` wraps it in a plain
`AsyncThrowingStream` so callers outside `BBPersistence` never name a GRDB type. Any write
path counts, including the HTTP API and the command line.

There is no `readSynchronously`, and the `DatabaseQueue` is not public. GRDB offers both a sync
and an async `read`; the async one requires a `Sendable` result, so a closure returning `[Row]`
(which borrows the statement's storage and is not `Sendable`) **silently resolves to the
synchronous overload** and blocks the caller while still reading as `await`. Through
`AppDatabase` that same closure fails to compile instead.

Only two types ever held a raw queue and both hit this. Do not add a third.

### Migrations

Registered in `AppDatabase.migrate()`, in order:

```
createSettings              createAlerts               createDevices
createWebhooks              createContactIndex         addContactAddressRawAndAccount
createScheduledMessages     createBackups              createAccessControl
addBlockOffenceCount        addAlertDurability         createPairedClients
normaliseTimestampColumnNames
interfaces.addScheduledMessageAnchor
```

Rules:

- **Append-only. Never edit a released migration**: two installs on the same version would end
  up with different schemas and neither would know it.
- Renaming a column means a **new** migration with `table.rename(column:to:)`.
- A new migration goes in its contributor's `registerSchema`, which runs after
  `normaliseTimestampColumnNames` on every install. `registerSchemaBeforeTimestampRename` is
  closed: `AppDatabase` refuses an identifier there that was not released before the rename.
- Add the migration and the model change in the same commit.

### Naming: enforced by `Tests/SourcePolicyTests/NamingConventionTests.swift`

- Tables `snake_case` and **singular** (`alert`, not `alerts`): a row is one of the thing.
- Columns `snake_case`.
- `_at` for a time something happened (`created_at`, `read_at`, `blocked_at`, `last_seen_at`).
  All of them, no exceptions.
- `_for` for a time something is aimed at: `scheduled_message.scheduled_for` is the only one.
- `is_` for booleans; `_count` for counts; `<table>_id` for foreign keys.
- New tables: `id` for the primary key, `uuid` for a UUID that is not the primary key.

**Column names leak.** `blocked_client` is serialized field-for-field onto
`/api/v2/server/security/blocklist`, so a badly named column is a badly named wire key.

Four legacy identity spellings (`alert.uuid`, `device.identifier`, `contact.id`,
`paired_client.client_id`) are **not** renamed: they are primary keys and foreign key targets,
and the churn buys nothing a comment cannot.

Full rules: [`docs/NAMING.md`](../../docs/NAMING.md).

### Repositories

`Sources/BBInterfaces/`: `AlertRepository`, `BackupRepository`,
`DeviceRepository`, `ScheduledMessageRepository`, `WebhookRepository`. Add new tables' access
here, not in handlers.

### The contact index: three tables, and one of them deliberately has no foreign key

`ContactIndex` (`Sources/BBContacts/`) owns all three and is the only thing that reads or
writes them.

`contact` is one row per person, merged from every source at index time rather than per
request. Besides the name parts it carries `account_kind`/`account_name` (which address-book
account a record synced from — iCloud, Google, a CardDAV server; distinct from `source`, which
is only "address book" vs "created through `POST /contact`" and is frozen into the wire format
as `db`/`api`) and `search_haystack`.

`contact_address` is the phones and emails, cascading from `contact`. `normalized` is the
lossy lookup key, `raw` is what was actually entered, and `reversed` is the normalized address
BACKWARDS: matching a handle means "ends with these N digits", SQLite can range-scan a prefix
but not a suffix, so storing it reversed turns the suffix match into an indexed prefix probe.
That index is what makes name resolution affordable, and it runs once per handle per message.

`contact_disabled` is which contacts the user has switched off, and its shape is the whole
design of that feature:

* **Its own table, not a column on `contact`.** `reindexAll` deletes every address-book row
  and re-inserts it — that is how a contact deleted in Contacts disappears — so a column would
  be wiped by the next re-index and every choice would silently revert.
* **No foreign key.** A cascade would be the same bug wearing a constraint. It survives
  because the id is stable (`addressBookPrefix` + `CNContact.identifier`), so a contact that
  comes back gets its setting back. A contact deleted for good leaves two columns of text
  behind, which is the accepted cost.
* **Only the disabled ones are stored.** Absence means served, so "enabled by default" is the
  schema rather than a backfill, and the table is the size of the exceptions.

**A disabled contact is not served ANYWHERE, and that is load-bearing rather than incidental.**
`ContactIndex.enabledPredicate` is on the list, the count AND both handle-to-name lookups, so a
message from a disabled contact shows the raw address in every client and in notifications.
Anything optimising `findContact` has to carry the predicate with it. It is written `NOT
EXISTS` rather than `NOT IN`, because `NOT IN` against a subquery that can yield NULL answers
NULL for every row, which would serve nobody at all.

**When a removal is noticed.** The index is rebuilt by `reindexAll`, which deletes every
address-book row and re-inserts what Contacts hands over, so a deleted contact — or an entire
account someone unlinked — simply stops being returned. Three things trigger it: server start,
a manual Refresh (the button and `POST /contact/refresh`), and `CNContactStoreDidChange`, which
`ContactsService.observe` watches with a ten-second debounce. That last one used to be missing
— the notification appeared in this codebase only inside a comment — so a server left running
for weeks went on serving contacts the Mac no longer had. It is debounced because the
notification says only that SOMETHING changed, never what: unlinking an account delivers one
per contact removed, and acting on each would walk the whole address book dozens of times
during one sync. There is no feedback loop to guard against; this server only ever reads the
contact store.

Two costs that are easy to reintroduce. `ContactIndex.search` filters, counts and orders in
SQL because the alternative — what it replaced — is reading the whole address book into the
app to filter it in memory, which is where the memory goes and why the list could not be
paged. And a page hydrates its addresses in ONE query (`hydrate(rows:db:)`); the per-row form
is for single lookups only, and using it for a list made a page of fifty cost fifty-two
selects. `ContactPageCostTests` counts statements through GRDB's trace hook, because an N+1
implementation passes every behavioural test there is.

---

### Metrics: two tables, one writer, thirty days

`MetricsSchema` (`Sources/BBAppStore/MetricsStore.swift`) contributes `metric_minute` (one
row per `MetricKey` per finished minute, primary key `(metric, minute_at)`) and
`availability_span` (when the server and each Private API helper was up; `ended_at` is null
while a span is open). `ServerMetrics` is the only writer: it records each finished minute,
prunes everything older than `MetricsStore.retention` on the same flush, and at the next start
closes any span a crash left open at the last minute that was flushed, the last moment
anything can vouch for. The metric is a closed enum whose raw value is the stored identifier,
never a free-form string, so a typo cannot open a series that stays empty. Counts only: no
address, path, message or name lands here. Home reads it through `model.monitoring`.

## Settings storage

Settings live in `app.db`'s `setting` table:
`key TEXT PRIMARY KEY, value BLOB, type_tag TEXT, is_secret INT, updated_at`.

Values are JSON-encoded **with a stored type tag**, never inferred from the stored bytes. Type
inference cannot distinguish an integer `0`/`1` from a boolean, or a whole-numbered `Double` from
an `Int`, and guessing wrong silently changes a setting's meaning.

**Secrets never sit in the DB.** `password`, `ngrok_key`, `zrok_token`,
`zrok_reserved_token`, the Firebase service account, and the signing/encryption keys are
Keychain items; the row holds only a reference. Reads return `SecureString`: an `mlock`-ed
allocation that zeroes on `deinit` and exposes only `withUnsafeBytes` and constant-time `==`.
The credential *files* (`fcmDir/server.json`, `fcmDir/client.json`, the TLS private key) are
Keychain items too, with an ACL bound to the app's code signature.

Providers resolve in order: **declared defaults → `~/bluebubbles.yml` → CLI args → persisted
store.** CLI values are never written into the DB.

Writes are transactional and emit **one** `SettingsChange`:

```swift
try await settings.write { $0[.proxyService] = .zrok; $0[.zrokToken] = tok }
```

Adding a setting means declaring it in the `SettingsRegistry+<Section>.swift` file for its section
and adding it to `Settings.renderable` (has a UI) or `Settings.hidden` (bookkeeping) in
`SettingsRegistry.swift`. `Settings.allKeys` is
derived from those two lists; there is no string list to keep in step. Settings the composition
root reads once: which route groups mount, how chat.db is opened, declare
`application: .composition`, and `SettingsPropagation` derives its "restart to apply" set from
that. Rows kept only so the Electron `config.db` can migrate live under `Settings.Legacy`.
Refer to a key as `Settings.x.key`, never as a string literal: `WatchedSettingsTests` proves
every watched key exists, but only a typed reference makes a rename a compile error.
`RenderableSettingsTests` and `SettingApplicationTests` fail if a declaration is missing from
the lists.

`Sources/BBSettings/LegacyConfigMigration.swift` imports settings from an older `config.db` if
one is present: coerce each value by its declared type, copy secrets into the Keychain, stamp a
marker. What each Electron key becomes is one table, `Legacy.rules`, whose destinations are
typed settings or service fields; a key the registry declares that no rule reads, or a value
that will not coerce, is listed in `Result.notCarriedOver` and named on the migration step,
never dropped or counted as imported. `run` opens the old database READ-ONLY and **leaves the
file untouched**: do not add a cleanup step that deletes it.

This paragraph used to say the import deleted the plaintext rows. It did not: both connections
were opened `readonly = true`, there was no `DELETE` in the file, and the sentence contradicted
its own next clause. The credentials stayed readable in `config.db` indefinitely.

Removing them is now `LegacyConfigMigration.removePlaintextSecrets`: the only writer to the old
database anywhere, offered by the migration wizard as its own step, and only after the copy into
the Keychain has completed. It is separate because it is irreversible and because it is exactly
what stops a user downgrading to the Electron server, which is a decision to ask about rather
than a side effect of importing settings.

### `app.db` waits for a lock rather than failing

`AppDatabase.configuration()` sets `busyMode = .timeout(5)`. GRDB's default is
`.immediateError`, which throws the instant another connection holds the database.

Normal operation never reaches that: `SingleInstanceLock` stops two servers, and
`AppModel.start` hands the same `Storage` to `build` rather than opening a second connection,
but one path skips the lock ON PURPOSE. `--clear-blocklist` opens `app.db` before acquiring it,
because an admin locked out by a bad access rule needs recovery to work while the server is up.
Under the default that recovery failed with "database is locked" exactly when it was needed,
and looked like a broken flag.

Five seconds is a ceiling, not a delay: an uncontended write does not wait at all. Every write
here is a settings row or a small delete, all of them milliseconds, so a wait that reaches the
ceiling means something is genuinely stuck and should be reported rather than absorbed.

The timeout covers `SQLITE_BUSY` and nothing else. It does not help `SQLITE_IOERR_LOCK`, which
is a different failure with a different cause; see below.

### Test fixtures are rollback-journal; a real `chat.db` is WAL

`Tools/chatdb-fixtures/generate.py` never sets a journal mode, so the committed fixtures are in
SQLite's default `delete` mode. Messages keeps the real `chat.db` in WAL: its file header says
so, and `-wal`/`-shm` sit beside it.

That difference is invisible until a test opens one copy TWICE, read-only through
`ReadOnlyDatabase` and writable to stand in for Messages, which the hydration tests do. In
rollback-journal mode a reader's SHARED lock blocks the writer, and with both connections in one
process SQLite answers `BEGIN IMMEDIATE` with `SQLITE_IOERR_LOCK`: surfaced as "SQLite error
10: disk I/O error". Measured at 100% of attempts in that mode and 0% in WAL. It read as a
load-dependent flake because load widened the overlap between the reader's transaction and the
writer's; the conflict itself is not a race.

**A busy timeout does not help**, and that was the standing theory for months.
`Configuration.busyMode` retries `SQLITE_BUSY`; this is `SQLITE_IOERR` and returns immediately
whatever the busy handler says.

So a test that needs both connections goes through `CommittedChatDB.walCopy()`
(`Tests/BBTestSupport/`), which converts the copy to WAL. The ORDER inside it is load-bearing: the writable connection opens first and the
caller must hold it, because a read-only connection cannot create the `-shm` file a WAL database
needs and fails with `SQLITE_CANTOPEN` without one. That is the same constraint
`ReadOnlyDatabase` documents for production: it can read `chat.db` while Messages is running,
because that is what keeps `-shm` alive.

Shipping the fixtures in WAL instead would not work: the sidecars exist only while a connection
holds them, so a committed WAL file arrives with none and cannot be opened read-only at all.

`ChatDatabaseFixture` (`Tests/BBIMessageTests/`) builds its file at run time, so it starts in WAL
and holds its writer for as long as it lives. It has to: a stream test's ticks overlap its writes.
In rollback-journal mode that overlap fails the write in two ways, depending on which side gets
there first: a read already in progress gives the `SQLITE_IOERR_LOCK` above, and a read starting
inside the writer's transaction gives "SQLite error 5: database is locked" at `COMMIT`. A busy
timeout clears only the second. Neither reaches Messages through this server's reads, because a
real `chat.db` is in WAL and a WAL reader does not block a commit.

WAL also means a reader does not wait for a commit to finish, as a rollback-journal reader does,
so a file wake can query ahead of the commit, as it can in production. A test through the real
watcher has to keep its clock moving so the re-check can run.

### A settings write is never `try?`

`SettingsStore.set` throws for a reason a person needs to hear: the Keychain refused, the
disk is full, a value failed validation. Propagate it, or (where nothing can catch it, a
closure handed to a service or a SwiftUI action) use `trySet`, which logs at error level
with the key and returns whether the value stuck. In the app, a caught failure goes to
`AppModel.report(_:while:)`, which raises an alert. Grep for `try? await .*\.set(` before
committing; the answer should be nothing.

