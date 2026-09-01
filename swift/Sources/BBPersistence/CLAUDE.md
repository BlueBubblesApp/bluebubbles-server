# BBPersistence

Two databases with opposite rules. Full detail:
[`../../.claude/docs/database.md`](../../.claude/docs/database.md).

## `ReadOnlyDatabase` — `chat.db`

Apple's file, with Messages actively writing to it. **There is no write API, by construction** —
no `write`, no `execute`, no migrator, no accessor for the underlying queue. A write does not
compile.

That is structural rather than a flag because a flag is what fails: a `readonly: true` option can
be dropped, overridden or forgotten in a new code path, and nothing catches it until a user's
message history is corrupted — which is unrecoverable.

Do not add a write path, a raw-queue accessor, or a temporary escape hatch. **Checkpoint,
`VACUUM`, `ANALYZE`, `REINDEX` and temp indexes are all writes too** — several look harmless.

Three settings that look like omissions and are not:

- **`immutable` is deliberately unset** — it promises SQLite the file cannot change, which is
  false while Messages runs, and produces stale reads or corruption.
- **`maximumReaderCount = 1`** — one connection, not a pool. Lower memory on old hardware; a
  reader needs no concurrency against a database it never writes.
- **`readCursor` exists and unbounded queries must use it.** `fetchAll` on a large message query
  is how memory grows with the size of the user's history.

**Never `SELECT *`.** Apple adds and removes columns per release (Sequoia removes
`message_processing_task`, which Sonoma has), so a vanished column takes the whole query with it.
Name every column and consult `BBIMessage/SchemaProfile.swift`.

## `AppDatabase` — `app.db`

Ours, read-write, GRDB, foreign keys on.

**`read` and `write` are the entire surface and the queue is not public.** There is deliberately
no `readSynchronously`: GRDB's async `read` requires a `Sendable` result, so a closure returning
`[Row]` silently resolves to the *synchronous* overload and blocks the caller while still reading
as `await`. Through `AppDatabase` that closure fails to compile instead. Only two types ever held
a raw queue and both hit this — do not add a third.

### Migrations

- **Append-only. Never edit a released migration.** Two installs on the same version would end up
  with different schemas and neither would know it.
- Rename a column via a *new* migration using `table.rename(column:to:)`.
- Add the migration and the model change in the same commit.

### Naming (enforced by `Tests/CompositionTests/NamingConventionTests.swift`)

Tables `snake_case` and singular. Columns `snake_case`, `_at` for event times, `_for` for
intended times, `is_` for booleans, `_count` for counts, `<table>_id` for foreign keys. New
tables use `id` for the primary key and `uuid` for a UUID that is not it.

**Column names leak onto the wire** — `blocked_client` is serialized field-for-field onto
`/api/v2/server/security/blocklist`.
