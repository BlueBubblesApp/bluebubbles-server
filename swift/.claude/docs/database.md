# Databases

There are **two**, and confusing them is the most expensive mistake available in this codebase.
Domain rules for the data inside `chat.db` — chat GUIDs, typedstream, the send path — are in
[`imessage.md`](imessage.md).

| | `app.db` | `chat.db` |
|---|---|---|
| Owner | Us | Apple / Messages.app |
| Path | `~/Library/Application Support/bluebubbles-server/app.db` | `~/Library/Messages/chat.db` |
| Type | `AppDatabase` | `ReadOnlyDatabase` |
| Access | Read **and** write | Read only, **by construction** |
| Schema | Ours; linear migrator | Apple's; changes per macOS release, in both directions |
| Second writer | No | **Yes — Messages, constantly** |

Both live in `Sources/BBPersistence/`.

---

## `chat.db` — read-only, and structurally so

`ReadOnlyDatabase` (`Sources/BBPersistence/ReadOnlyDatabase.swift`) exposes **no write API at
all** — no `write`, no `execute`, no migrator, and no way to get at the underlying
`DatabaseQueue`. A write does not compile.

The guarantee is structural rather than a flag, because a flag is the thing that fails: a
`readonly: true` configuration option can be dropped, overridden, or forgotten in a new code path,
and nothing catches it until a user's message history is corrupted — which is unrecoverable.
**Do not add a write path, a raw-queue accessor, or a one-off escape hatch.**

Other properties that look like omissions and are not:

- **`immutable` is deliberately NOT set.** It promises SQLite the file cannot change, which is
  false while Messages is running, and yields stale reads or corruption. We need live WAL
  content and pay for it.
- **`maximumReaderCount = 1`.** One connection, not a pool — lower memory on the old hardware
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

`SchemaProfile` also carries `dateUnit` — High Sierra switched `chat.db` from seconds to
nanoseconds, and getting it wrong produces dates that look plausible and are decades off. Use
`BBCore`'s Apple timestamp helpers; never hand-roll the epoch maths.

### Chat GUIDs

Never compare with `==`, never derive a service from the prefix, never write a literal
`c.guid = ?`. They differ between servers on the same iCloud account, and macOS 26 rewrote every
prefix to `any`. Use `ChatGUID.lookupCandidates()` in queries. Full rules:
[`imessage.md`](imessage.md#chat-guids--the-single-most-dangerous-thing-in-this-codebase).

### `SchemaProfile` drives the wire format

**A field absent from the schema must be ABSENT from the JSON, not null.** Clients distinguish
the two. This is why serializers consult the profile rather than checking for `nil`, and why
moving a `serialize` call between layers cannot change the bytes.

### Change detection

`Sources/BBIMessage/ChangeDetector.swift` turns file activity into message events. Four of its
behaviours are load-bearing — changing any of them loses messages:

- **The dual lookback** — a 30-minute fast window every tick (Apple only permits edits within
  ~15 minutes and unsends within ~2), widening to a full 7 days every 5 minutes to catch read
  receipts and notification flags on older messages.
- **Query by `date`, filter the other timestamps in memory.** `date` is the only one of them
  with an index in Apple's schema and we cannot add one, so an `OR` across all of them
  full-scans `message`.
- **The >24h clamp**, so a machine that slept for a week does not replay a week as new messages.
- **Watching the `-wal` sidecar**, not just the database file. SQLite in WAL mode appends there
  and checkpoints later; watching only `chat.db` misses most activity.

Develop against fixtures, never your own messages:

```bash
python3 Tools/chatdb-fixtures/generate.py --out Tests/ChatDBFixtures
```

Writes deterministic `chat-ventura.db`, `chat-sonoma.db`, `chat-sequoia.db` covering direct and
group chats, an attachment, a reaction, a threaded reply and an edited message. Regeneration is
byte-identical, so they never show up as diff noise. They are gitignored — rebuild, do not
commit.

---

## `app.db` — ours

`AppDatabase` (`Sources/BBPersistence/AppDatabase.swift`), GRDB, foreign keys on, opened and
migrated by `AppDatabase.open(at:)`. `AppDatabase.inMemory()` for tests.

### The access surface is `read` and `write`, and the omission is the point

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
```

Rules:

- **Append-only. Never edit a released migration** — two installs on the same version would end
  up with different schemas and neither would know it.
- Renaming a column means a **new** migration with `table.rename(column:to:)`.
- Add the migration and the model change in the same commit.

### Naming — enforced by `Tests/CompatibilityTests/NamingConventionTests.swift`

- Tables `snake_case` and **singular** (`alert`, not `alerts`) — a row is one of the thing.
- Columns `snake_case`.
- `_at` for a time something happened (`created_at`, `read_at`, `blocked_at`, `last_seen_at`).
  All of them, no exceptions.
- `_for` for a time something is aimed at — `scheduled_message.scheduled_for` is the only one.
- `is_` for booleans; `_count` for counts; `<table>_id` for foreign keys.
- New tables: `id` for the primary key, `uuid` for a UUID that is not the primary key.

**Column names leak.** `blocked_client` is serialized field-for-field onto
`/api/v2/server/security/blocklist`, so a badly named column is a badly named wire key.

Four legacy identity spellings (`alert.uuid`, `device.identifier`, `contact.id`,
`paired_client.client_id`) are **not** renamed — they are primary keys and foreign key targets,
and the churn buys nothing a comment cannot.

Full rules: [`docs/NAMING.md`](../../docs/NAMING.md).

### Repositories

`Sources/BBInterfaces/` — `AlertRepository`, `BackupRepository`,
`DeviceRepository`, `ScheduledMessageRepository`, `WebhookRepository`. Add new tables' access
here, not in handlers.

---

## Settings storage

Settings live in `app.db`'s `setting` table:
`key TEXT PRIMARY KEY, value BLOB, type_tag TEXT, is_secret INT, updated_at`.

Values are JSON-encoded **with a stored type tag**, never inferred from the stored bytes. Type
inference cannot distinguish an integer `0`/`1` from a boolean, or a whole-numbered `Double` from
an `Int`, and guessing wrong silently changes a setting's meaning.

**Secrets never sit in the DB.** `password`, `ngrok_key`, `zrok_token`,
`zrok_reserved_token`, the Firebase service account, and the signing/encryption keys are
Keychain items; the row holds only a reference. Reads return `SecureString` — an `mlock`-ed
allocation that zeroes on `deinit` and exposes only `withUnsafeBytes` and constant-time `==`.
The credential *files* (`fcmDir/server.json`, `fcmDir/client.json`, the TLS private key) are
Keychain items too, with an ACL bound to the app's code signature.

Providers resolve in order: **declared defaults → `~/bluebubbles.yml` → CLI args → persisted
store.** CLI values are never written into the DB.

Writes are transactional and emit **one** `SettingsChange`:

```swift
try await settings.write { $0[.proxyService] = .zrok; $0[.zrokToken] = tok }
```

Adding a setting means declaring it in `Sources/BBSettings/SettingsRegistry.swift` and adding it
to **both** `Settings.allKeys` and `Settings.renderable`.
`Tests/BBSettingsTests/RenderableSettingsTests.swift` fails if you forget either — it has
already caught two.

`Sources/BBSettings/LegacyConfigMigration.swift` imports settings from an older `config.db` if
one is present: coerce each value by its declared type, move secrets to the Keychain, delete the
plaintext rows, stamp a marker. **It leaves the old file untouched** — do not add a cleanup step
that deletes it.
