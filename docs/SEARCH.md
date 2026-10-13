# Message search

Searching for a word in a message finds nothing on macOS 26, and the server answers `200` while
it does it. This document is the plan for fixing that: what to build, what the user is told, and
what it costs them in privacy.

Every number below was measured on the author's Mac (macOS 26.5.2, M3 Max, arm64, release build)
against a real 422,042-message database. Where a figure is an estimate rather than a
measurement, it says so.

---

## The problem, measured

macOS 26 stopped populating `message.text`. The words live in `attributedBody` and nowhere a SQL
`LIKE` can reach. The serializer already reads through to the body, so a message DISPLAYS
correctly — which is what makes this a defect rather than a curiosity. The user sees a word on
screen, searches for it, and gets a successful, empty answer.

| Month | Messages | Empty `text` |
|---|---|---|
| 2026-06 and earlier | — | ~0.3% |
| 2026-07 | 5,392 | 47.2% |
| 2026-08 | 4,300 | **99.9%** |
| 2026-09 | 3,610 | **99.8%** |

It is **not** confined to outgoing messages: over the last ninety days, 85.2% of outgoing and
**60.4% of incoming** messages have an empty `text` column. Nor did it begin with Ventura,
which is where the obvious suspicion lands — the cliff is macOS 26, and the month-by-month
table above is what shows it.

### Why the obvious routes are closed

**There is no index to borrow.** `chat.db` contains no FTS table — no virtual tables of any
kind. What it does contain is a donation queue: `index_state_metrics` reads
`pending=0 donated=418292`, and `message_idx_pending_indexing_messages` indexes the rows still
waiting. Messages hands text to an external index and tracks what it has handed over.

**That external index is not Spotlight-as-you-know-it.** No importer is registered for Messages,
`mdutil` reports an unknown indexing state for `~/Library/Messages`, and `mdfind -onlyin` there
returns zero items. The donations land in a per-app CoreSpotlight domain, and a CoreSpotlight
query is scoped to the identity of the process making it.

That last sentence is the whole reason the reference server does what it does. Its
`MessageInterface.searchMessagesPrivateApi` opens with `checkPrivateApiStatus()` and asks the
injected helper to search, because inside Messages' own process a query runs with Messages'
identity. Outside it, the index is unreachable. When the Private API is off, the reference falls
back to the same `LIKE` that finds nothing.

**So the only route that works without injection is an index of our own.**

---

## What to build

A contentless SQLite FTS5 index over message text, in a file of its own beside `app.db`, filled
by a service walking `message.ROWID` upward and rebuilt on demand. (This plan first said "in the
server's own database, fed by the change detector". Both halves changed as it was built:
`ApplicationSupport.searchIndex` records why an optional cache must not be a table `AppDatabase`
creates, and step 4 below records why a cursor sees rows the event stream deliberately drops.)

FTS5 is a SQLite extension that stores an inverted index — for each word, the rows containing
it. It is a table in a file, not a service: nothing runs when nobody is searching. System SQLite
on the deployment floor ships it (3.51 on 26.5.2), and GRDB links system SQLite, so no
dependency changes.

### What it costs

Measured over 418,650 indexed messages:

| | `detail=full` | `detail=none` |
|---|---|---|
| Build, once | 6.2 s | 6.3 s |
| — of which decoding `attributedBody` | 0.1 s | 0.1 s |
| Disk | 21 MB | **12 MB** |
| Per message | 54 bytes | 31 bytes |
| Peak memory during the build | 4.2 MB | **0.8 MB** |
| `MATCH pizza`, warm | 0.09 ms | 0.08 ms |
| `MATCH tomorrow*` | 0.13 ms | 0.46 ms |
| `MATCH "see you"` | 0.26 ms | **unsupported** |
| One new message | 0.376 ms | — |

**Idle cost is zero CPU.** No timer, no task, no thread. The standing cost is the file and
SQLite's page cache, which `cache_size` bounds.

**On the target hardware**, and this is an ESTIMATE: a 2012–2017 Intel Mac is roughly four to six
times slower per core for this work, so the one-off build is on the order of thirty to forty
seconds, or a few minutes on a spinning disk where the build is I/O-bound rather than CPU-bound.
Queries go from tenths of a millisecond to low single-digit milliseconds. The per-message insert
goes from 0.4 ms to a few milliseconds, against a path that already does more than that. **Only
the first build is perceptible, and it happens once.** Re-measure before quoting these.

### `detail=none` is the default, and it costs phrase search

`detail=full` stores token positions, which is what lets FTS5 answer `"see you"` as a phrase.
Those positions are also what makes the index substantially reconstructable back into text.
`detail=none` stores only "this word appears in this row" — half the size, a fifth of the build
memory, and no phrase queries.

Phrase search is worth giving up, and not only for the privacy. The reference does not do true
phrase matching either: its own router records that "exact match for the Spotlight API actually
means contains" and that a contains match "tokenizes the search term and matches any token".
Requiring every token, which is what `detail=none` gives, is already stricter than the behaviour
being matched.

---

## What the user is told

The feature is **off until somebody turns it on**, it is offered during setup, and it is
explained in words that do not require knowing what an index is.

### The onboarding step — **done**

`OnboardingStep.ID.search`, offered to everyone whatever their goals, placed **last before the
summary**: nothing depends on it, and somebody setting the server up should reach a working
server before being asked to weigh a privacy trade. It sits after the group-chat step rather
than before, because that one has to stay immediately behind the Private API offer whose answer
decides whether it appears at all — an adjacency `OnboardingFlowTests` already asserted, and
which the first placement broke.

**Not skippable, deliberately.** A Skip button implies an unfinished task; this is a choice with
a default, and Continue is how the default is accepted. Two decline buttons for one decision is
worse than one. The step gates nothing.

The switch itself is the **generated `SettingRow`**, not a `Toggle` of its own, so the step and
the settings page draw the same control from the same declaration and cannot disagree about the
label, the help text, or what writing it does.

Its job is a decision, not a configuration: one switch and enough prose to make the switch
meaningful.

> **Search**
>
> *Recent versions of macOS stopped storing the words of a message where other apps can read
> them. Your messages still show up correctly — but searching for a word in one finds nothing.*
>
> **Turn on message search**  ( ) off
>
> BlueBubbles can fix this by reading your message history once and noting which words appear in
> which message. It takes about a minute and happens on this Mac.
>
> **What gets stored.** A word list, not your conversations. The index can answer *"message
> 4,182 contains the word dinner"*. It does not keep the message.
>
> **Where.** In BlueBubbles' own folder on this Mac. Nothing is uploaded, and turning this off
> deletes it.
>
> **If you leave it off.** Everything else works exactly the same. Searching message text will
> keep missing anything sent since your Mac updated.

Three rules for that copy, because they are what makes it honest:

- **Name the trade, do not sell the feature.** The last paragraph states the cost of declining
  in the same plain register as the benefit of accepting. A step that only lists upsides is a
  consent screen that has decided for the user.
- **No jargon that hides the mechanism.** Not "full-text index", not "FTS5", not "tokenised".
  "A word list, not your conversations" is the same fact in words a person can weigh.
- **Say where it lives and that leaving deletes it**, because the two questions anybody with a
  privacy instinct asks are "where does this go" and "can I take it back".

### The settings row — **done, in a section of its own**

`Message Search`, on the General tab directly under Features: the switch, then what the index
holds, then **Rebuild**. `MessageSearchSection` draws all three.

The switch is still the generated `SettingRow` from the same declaration — no second copy of a
control, per `Sources/BlueBubblesApp/CLAUDE.md` — but it is marked `isInternal` and listed by
`MessageSearchPanel`, so the generated page does not draw it too. That is the shape
`HTTPSettingsPanel` uses, and `MessageSearchPanelTests` holds the two halves together: a
setting marked internal and then dropped from the list is one nothing draws at all.

Left to the generated page, the switch was a row in Features between Startup Delay and Hide
Dock Icon, and the state it turns on was a second section further down the same tab. The
switch and what it does are one thing to read.

The state is what a declaration cannot carry: indexed with a count, building with a count, or a
Mac whose SQLite cannot hold an index.

It **reads the store, not the service**. What a person wants to know is the state of the index,
and that lives in the file; the app also has no business looking up a concrete service, since
the registry owns services rather than the other way round. Rebuild is the same shape:
`requestRebuild()` resets the cursor and the completion flag, and the indexer acts on it — no
restart ordered by a screen, and no capability the app should not have.

It is shown only while the feature is ON, the rule `GroupChatShortcutSection` follows: with it
off, the toggle directly above already says so, and a status line reading "off" underneath is a
second answer to a question that has one.

**It re-reads on the indexer's health, not only on the server phase**, and that is what makes
the count a live one. The interesting change happens entirely inside the service, seconds to
minutes after the view appeared. Keyed on the phase alone the section read once: "Building the
index… 0 messages so far" sat at zero for the whole backfill unless the user navigated away and
back — and the report the service sends on every page reached nobody, because the Integrations
screen filters on `isUserManageable`, which this manifest sets false, and the sidebar's
background list at the time listed only `.starting`. So the two halves were built and never
met. `RefreshKey` is the join: health is the trigger, the store is still the source, and the
reason the health carries a count at all is so the key changes.

**The sidebar draws a bar from the same report.** `health` carries the walk's fraction as
`ServiceHealth.degraded(reason:progress:)`, and `BackgroundActivity.forService` lists a
degraded service WITH a fraction as a task in flight (one without a fraction is a problem, and
Home reports it as one). The registry never sees the backfill as `.starting`: `start()` returns
as soon as the pump is launched, so without the fraction the build was a line on Home and
nothing in the sidebar. Two decisions in `BackfillExtent` keep the bar honest:

- **It measures the delta this build walks, not the table.** A first build starts at zero; one
  resumed after an interruption starts at the cursor it left, and the bar opens at 0% for the
  rows that remain rather than at 60% for work a previous process did. The steady state passes
  no extent at all, so a handful of arriving messages never shows a bar.
- **The ceiling is fixed before the walk.** Messages arriving mid-build lie above it and are
  walked in the same pass with the bar at 100%, rather than the bar reaching 100% and carrying
  on. Progress is in ROWIDs, the walk's own unit, because counting rows-with-text first is the
  scan this service exists to avoid.

The settings section still shows a count rather than a bar. It reads the store, and the store
has no extent: the ceiling lives in the running service, where the walk is. The section's own
`.building` case is its private enum, not the service's.

**The one rough edge, stated:** the pump's tick is sixty seconds, so a Rebuild press waits up to
a minute before the walk starts. The screen does not look stalled — the status it renders comes
from the same flag the request sets, so it says "building" at once and the count climbs within
the minute — but the work genuinely is not immediate. Waking the pump on demand needs a
continuation raced against the sleep, which is machinery for a button nobody presses twice.

That `run` is ONE loop asking "is the backfill complete?" at the top of each pass, rather than
"backfill, then poll", is what makes a rebuild possible at all: the second shape has no way back
to the building half.

---

## What the opt-in actually buys, and what it does not

This is the part to be straight about, because "it's opt-in" is often used to end a security
conversation rather than to have one.

### What it buys

**The default posture is unchanged.** With the switch off, the server persists no message
content anywhere, which is exactly true today. Nobody who does not choose this acquires a new
exposure — including every existing install after an upgrade, which must come up with the switch
off regardless of what else is migrated.

**Consent is informed and specific.** The user is told what is stored, where, and how to undo
it, before anything is written. That is a materially different position from discovering a
plaintext index in Application Support after the fact.

**It is reversible, and reversing it means something.** Turning the switch off deletes the index
file. Not "stops updating it" — deletes it.

**The blast radius is reduced twice over.** `detail=none` means the file holds a word list rather
than reconstructable text, and tightening the file mode (below) removes the most casual way to
read it.

### What it does not buy

**Opt-in does not make the file safe. It makes the choice informed.** Once the index exists it is
derived from message plaintext, sitting outside the protection the source enjoys, and the
difference is concrete:

```
chat.db   -rw-r--r--@   ← the @ is TCC. Reading it needs Full Disk Access, and macOS prompts
app.db    -rw-r--r--    ← no TCC, in a drwxr-xr-x directory
```

Reading message content takes Full Disk Access. An index in `app.db` is readable by
**any process running as this user, with no prompt and no grant**. That is the honest summary of
the trade, and it is the sentence to keep in mind if anyone proposes turning this on by default.

**A word list is not nothing.** `fts5vocab` enumerates the vocabulary, and a bag of words per
message is enough to confirm whether a topic was discussed and with whom. `detail=none` reduces
the exposure; it does not make the file boring.

### Two mitigations worth taking now

**Tighten the permissions regardless of this feature.** `app.db` is mode 644 in a 755 directory
and already holds device push tokens, webhook URLs and the blocklist. `0600` on the file and
`0700` on the directory costs nothing and is correct whether or not search ships.

**Encryption at rest is a real option and a later one.** SQLCipher encrypts whole pages and
decrypts them in memory, so FTS5 works on top of it unmodified — searching encrypted data is not
the obstacle it sounds like. The obstacle is the key: it would live in the Keychain, and this
server already knows what that costs. `PasswordDigest`'s header records that a login Keychain
which locks stops the server authenticating anybody; a headless server starting before login
would be worse, and an index it cannot open is an index it must either rebuild or refuse to use.
Decide that before adopting SQLCipher, not after.

Per-field encryption is not an option: `MATCH` cannot read ciphertext. Hashing each token with a
Keychain key is a genuine middle ground — exact-word search survives, the index is useless
without the key — but it loses prefix search and leaks frequency patterns, so it is worth
costing properly rather than reaching for.

---

## Implementation

In dependency order. Each step is meant to land and be green on its own.

### 1. The store — **done**

`SearchIndexStore` (`Sources/BBIMessage/SearchIndexStore.swift`) owns the file, its schema and
its lifecycle. Nine tests in `SearchIndexStoreTests`.

**Its own file at `ApplicationSupport.searchIndex`, not a `SchemaContributor` in `app.db`.**
This departs from the first draft of this plan, for a reason found while writing it: a table
declared through `SchemaContributor` is created inside `AppDatabase.open`, and a migration that
throws there stops the server. The FTS5 options below are not available on every SQLite this
server can run on, so as a migration they are a server that will not start, while as a separate
file they are a feature that reports itself unavailable. Two more reasons follow the same way:
deleting a file is a complete and checkable way to honour "turning this off deletes it", where
`DELETE FROM` leaves freed pages holding the old tokens until something vacuums; and a cache
that rebuilds in seconds has no business in the database that holds settings and the blocklist.

```sql
CREATE VIRTUAL TABLE message_search USING fts5(
  text, content='', contentless_delete=1, detail='none',
  tokenize='unicode61 remove_diacritics 2'
);
```

`contentless_delete=1` was not in the first draft and is not optional: **a plain contentless
FTS5 table refuses `DELETE` outright** (`cannot DELETE from contentless fts5 table`), so an
edited message could never lose its stale tokens. It arrived in SQLite 3.43.

The row id IS `message.ROWID`, which is what makes step 3 a row-id lookup rather than a join.

Beside it, `search_state` holds the backfill high-water mark, whether the backfill has completed,
the indexed count, and a schema version. A version mismatch **rebuilds** rather than migrates:
the whole index costs seconds, and partially migrating an inverted index is not worth writing.

**The deployment floor supports it.** `contentless_delete` arrived in SQLite 3.43 and macOS 14
is close enough to that boundary to be worth checking rather than assuming; it was checked, in a
Sonoma VM, and the create succeeds. Search is available on every release this server supports,
and the onboarding copy needs no caveat about macOS versions.

The store still detects it by ATTEMPTING the create rather than comparing version numbers. That
is not distrust of the measurement — it is that the alternative encodes a release-to-feature
mapping which has to be re-verified on every new floor, and gets it wrong in the dangerous
direction when it drifts.

### 2. The setting — **done**

`Settings.searchIndexEnabled` (`search_index_enabled`, `Bool`, default **false**),
`section: .features`, `control: .toggle`, in `Settings.renderable`. Five tests in
`SearchIndexSettingTests`.

**A plain setting and not a `FeatureFlag`**, which is closer than it looks. Both existing flags
gate API surface a client can detect — each adds endpoints — and this adds none: `/message/query`
already takes the `where` clause it improves the answers to. `FeatureFlags`' own header also puts
anything configured during ordinary setup on the plain-setting side, and this is configured in
onboarding.

The default is pinned by a test rather than left to review, because `true` there would be
invisible in a diff and would index every user's history on their next update. Also pinned:
that it applies live (a `.composition` switch would move and do nothing until a restart), that
it has no `requires:` parent (it must never be made to depend on `enable_private_api` — the
index is the route that works when the Private API is off), and that it is not secret (a service
cannot declare a read of a secret, so marking it so would stop the indexer reading its own
switch).

Whatever reads it declares it in `readSettings`; an undeclared read throws. That happens in
step 4, with the service.

**One thing this step did not verify.** `--set search_index_enabled=true` starts the server, but
so does `--set definitely_not_a_key=true`: `parseOverrides` layers whatever it is given without
checking it against the registry, so a typo is silently inert. That is pre-existing and wider
than search, but it means an end-to-end `--set` run proves nothing about a key being declared,
and the tests are what actually hold this.

### 3. Reading through it — **done**

`MessageQuery.resolvedMessageRowIDs: [Int64]?`, following `resolvedChatRowIDs` exactly: a derived
value the repository fills in, not part of the public initialiser and not a `MessageFilter` case.
`MessageQueryPlan.predicate(for:)` turns it into `m.ROWID IN (…)`; an EMPTY array matches nothing rather than
being dropped, which is the `.guidIn` guard in a different costume.

`MessageRepository.resolvingSearch` is the routing, called from **both** `messages` and
`messageCount` — they build their own queries and share only the predicate, so a search resolved
in one and not the other returns a page of matches beside a total counting the database. Each `.textLike` filter is decided **on its own**, so one unanswerable term does not stop
another from being widened; a filter falls back to `LIKE`, unchanged, when there is no index,
the backfill is unfinished, its term is inexpressible, or the index matched nothing for it.

`MessageSearchRoutingTests` and `MessageSearchTermTests`.

**`countsAWholeChat` needed a new clause, and its own comment predicted this.** Resolving a
search REMOVES the `.textLike` filter, so a chat-scoped search looked condition-free and took
the join-only fast count — reporting the conversation's entire message count as the total beside
a page of matches. The property is written as a list of what must be ABSENT precisely so a new
condition in the query plan has to be considered here; it was, and there is a test.

**Two divergences from `LIKE`, both deliberate and both tested** (`MessageSearchTerm`):

- *Narrower.* `%harb%` finds "harbour"; `%bour%` does not. An inverted index records where
  tokens start, so a trailing wildcard is FTS5's prefix operator and a leading one has nothing
  to map onto. `%term` — "ends with" — is refused outright and falls back, rather than answered
  narrowly by an exact-token match that would look like a working search finding nothing.
- *Broader.* `%see you%` becomes `"see" AND "you"*`, which matches those words anywhere rather
  than adjacent. `detail='none'` stores no positions, so adjacency is not expressible. Accepted:
  the alternative today is finding nothing, and the result is a superset rather than a different
  set. The exact fix is known and costed — re-check candidates against their decoded text at
  0.015 ms each.

The term is untrusted input spliced into a query language with operators, so every token is
emitted quoted with internal quotes doubled; `AND`, `NEAR`, `-`, `(` and a `"` are all tested as
words rather than syntax.

Row ids are rendered as **literal integers**, not bound parameters: every one is an `Int64` this
server read out of its own index, so it is safe by construction, and binding ten thousand of
them would put the statement against a `SQLITE_MAX_VARIABLE_NUMBER` this code does not choose.
The match limit is 10,000, ordered by `rowid` in the query's own direction — the whole set has
to be present for the date ordering to be right, and `message.ROWID` is assigned in arrival
order, so a capped search keeps the newest matches.

### 4. The indexer — **done**

`MessageSearchIndexService`, registered in `ServerComposition`, `readSettings:
[search_index_enabled]`. Eighteen tests across `MessageSearchIndexServiceTests` and
`MessageReindexTriggerTests`.

**`isUserManageable: false`**, which reverses what this plan first said. The switch a user meets
in onboarding IS the control; listing the service on the Integrations screen would put a second
switch beside it that could disagree, which is the failure that flag exists to prevent.

**A ROWID cursor, not an event listener**, and the reasoning is worth keeping because the
opposite is the obvious choice:

- The event stream is deliberately lossy. `maximumAnnouncedPerTick` caps announcements and the
  watcher discriminates news from a sync so an iCloud backfill does not spam clients — and
  those suppressed messages are exactly the bulk history an index must contain. A cursor sees
  every row by construction.
- A second `ChangeDetector` would be a second fingerprint pass over the same table. Instead the
  service polls `PRAGMA data_version`, a shared-memory read, and does no query at all unless the
  answer moved.
- Backfill and steady state are the same code, so resumption is exercised every tick rather than
  only after a crash.

The cost is latency: a new message becomes searchable within a minute rather than at once.
Nothing waits on that; delivery is a different path entirely.

**Edits and unsends come from the watcher, because a cursor cannot see them.** A forward-only
walk never looks back, so an edited message would keep the words it used to have. Querying for
them is not an option — `chat.db` has no index on `date_edited`, so "what changed lately" plans
as `SCAN message` plus a temp b-tree over four hundred thousand rows, once a minute, for the
eighty-one rows that have ever been edited on the author's Mac. The watcher has already computed
it, so it tells the index: `MessageSearchIndexService` publishes a `MessageReindexing` hook,
`ChangeDetectionService` reads it per batch and forwards the rows whose `.edited` or `.retracted`
field moved.

- The hook is **published before the backfill starts** — an edit arriving mid-build must still
  land — and **withdrawn first in `stop()`**, because one left published writes to a store that
  is closed, or to one the user has just switched off and expects to be gone.
- `ChangeDetectionService.rowIDsNeedingReindex` is a named static rather than a closure in the
  pump, so the rule can be asserted without standing up a detector.
- A **deleted** message needs nothing: its row is gone, so the index's row id resolves to
  nothing and the join drops it.
- A **new** message is deliberately not forwarded. The cursor owns those, and a second writer
  for the same rows is a second thing to reason about for a latency nobody is waiting on.

#### Measured against a real database

One run, macOS 26.5.2, M3 Max, release build, 422,042 messages:

| | |
|---|---|
| Backfill | **5.6 s** for 418,672 messages |
| Service start | 1 ms — the backfill is behind it, not in it |
| Index on disk | **10.5 MB** |
| Resident memory | 68 MB idle &rarr; **84 MB** with the index open |
| Search latency, 25 rows hydrated | **11&ndash;20 ms** warm |

The benchmark that justified this plan predicted 6.2 s and 12 MB, so the estimates hold. The
Intel figures in the table above remain estimates.

**The search finds what it could not before**, and by the right amount. The same query, with
the feature off and on:

| Term | `LIKE` only | Indexed | Recovered |
|---|---|---|---|
| tomorrow | 2,020 | 2,070 | 2.4% |
| dinner | 1,886 | 1,916 | 1.6% |
| thanks | 1,582 | 1,614 | 2.0% |
| meeting | 439 | 445 | 1.3% |
| airport | 233 | 234 | 0.4% |

2.47% of the messages on that Mac have an empty `text` column and are reachable only through
`attributedBody`. Recovery clustering at about two per cent is the index reaching exactly that
population — neither missing it nor over-matching.

**Two defects that only a real run could show.** Both were invisible to the whole suite:

- **The repository was never given the index.** `MessageRepository(database:profile:searchIndex:)`
  defaults that parameter to nil, and `openReadPath` did not pass one — so the indexer filled a
  file nothing consulted, and the first run returned *identical totals* with the feature on and
  off. Every unit test injected its own store and passed over the gap. `openReadPath` now builds
  one store and hands it to both the repository and the service, and
  `compositionSharesOneIndex` asserts the composition rather than a hand-assembled object.
- **The directory stayed at 0755.** `createDirectory(attributes:)` only applies its attributes
  to a directory it CREATES, and on every existing install this one is already there — so the
  index landed 0600 inside a world-readable directory. The mode is now set unconditionally. A
  test could not have caught it: the temporary directory a test makes is always new.

**Teardown is a promise, not a cleanup.** `start()` reads the switch, and off means "make sure
there is nothing on disk" — run on every start, so an install switched off while the server was
stopped is still honoured. That is why the service is not a `GatedService`: a gated service that
declines is never constructed, and something has to be running to do the deleting.

**A replaced `chat.db` throws the whole index away.** The index is nothing but row ids, and a
row id only means anything inside one copy of the database: a restore, a rebuild or a migration
reassigns `message.ROWID` from 1, so every stored row then names a *different* message and a
search returns messages that do not contain the term, with a confident total beside them. It
does not heal on its own either — the cursor sits above the new maximum, so the walk ends
immediately while `backfill_complete` is still true in the index's own state file and the
reader goes on trusting it.

**It is asked by identity, not by magnitude.** The obvious signal is "the maximum ROWID has
fallen below the cursor", which is what this guard first used and what `ChangeDetector` uses.
It is wrong here, and not marginally: deleting the NEWEST message puts the maximum below the
cursor in a database nobody touched, and leaves it there until the next message arrives,
because `AUTOINCREMENT` does not reissue the id. An unsend, or deleting the last message in a
conversation, would have discarded a 418,000-row index and rebuilt it — silently, and every
time it happened. `ChangeDetector` can afford the cheap signal because a false positive costs
it a re-announced window; here it costs the whole index.

So the backfill pins one message — `SearchIndexStore.origin`, the oldest row, because the
newest is the likeliest to be deleted — and every pass asks that row id what its `guid` is
now. `message.ROWID` is `AUTOINCREMENT`, so an id is never reused within one file, which makes
the three answers exact:

| Answer | Means | Action |
|---|---|---|
| the same guid | the same database | nothing; this is every ordinary pass |
| a **different** guid | another message holds that id, which only a rebuilt file can do | discard and rebuild |
| no row | that one message was deleted | re-pin to the oldest row still there |

A new *file* rather than `requestRebuild()`, because the rows here are not stale but wrong: a
rebuild would rewrite the ones below the new maximum and leave every one above it matching for
ever. Two tests hold the pair, and each fails if the guard goes back to comparing maxima:
`replacedDatabaseDiscardsTheIndex` and `deletingTheNewestMessageIsNotAReplacement`.

Recording the pin is why `SearchIndexStore.schemaVersion` is 2. An index built under 1 has no
origin, and the version bump rebuilds it rather than migrating — seconds of work against a
partial migration of an inverted index.

**A deleted message loses its words, on a sweep, because nothing reports a deletion.** This is
residue rather than wrong answers: a deleted row id resolves to nothing, so the join drops it
and no search ever returned it — but `message.ROWID` is `AUTOINCREMENT`, the id is never
reused, and the entry therefore sat in the file for the life of the index. Somebody who deleted
a message on purpose was left with a record of which words it held, and `fts5vocab` can
enumerate a vocabulary.

There is no event to hang this on. The cursor never looks back, the watcher does not observe
deletions (`ChangeDetectionService` says so where it forwards edits and unsends), and `chat.db`
has no "deleted" column to query. So `pruneDeletedMessages` reconciles the index against the
rows that still exist, and three things keep it cheap:

- **at most hourly** (`pruneInterval`);
- **only after a commit** — a deletion IS a commit, so an unchanged `PRAGMA data_version`
  means nothing can have gone. Same gate `ChangeDetector` puts on its reconcile pass, so on a
  quiet Mac the sweep never runs at all;
- **in windows of ten thousand row ids**, which is 2 ms on the index side against 78 ms to
  scan a whole 420,000-row index (both measured), and never more than 80 KB of `Int64` on
  either side of the comparison. The whole reconcile over the author's 418,697-row index
  and 422,140-row `chat.db` is **212 ms across 43 windows**, measured.

> Measuring this is where `immutable=1` will lie to you. A reader opened that way skips the
> WAL, and on a live Mac `chat.db-wal` was 1.3 MB holding three messages the main file did
> not have — so a sweep run from such a reader reports orphans that are not orphans, and a
> `MAX(ROWID)` three below the truth. `ReadOnlyDatabase` says why it never sets it; a
> verification script has to make the same choice.

`deletedMessagesArePruned` pins it, with `pruneInterval: .zero` so the assertion does not
depend on whether the delete landed before or after the first steady-state pass.

**Progress reports are throttled; transitions are not.** `setState` is the one door out of the
state machine, and it calls `serviceHealthDidChange(Self.id)` so the settings screen can follow
a backfill; the registry then reads this service's `health` again and no other. The backfill sets `.building` once per page, 840 times in fourteen seconds on the
author's database, and each carries a different count, so equality does not dedupe them. The
count therefore reports at most once every five seconds (`progressReportInterval`) and the
transitions into and out of building always report, because that is the half a screen branches
on. Five seconds rather than one because every report re-renders the sidebar's task row, and
on macOS 26 the sidebar is glass: a count moving once a second re-sampled the glass once a
second for the length of the build.

**And the steady state is not a build.** `indexNewMessages` serves both phases and used to
announce `.building` on every page of either, with nothing in the steady state ever setting it
back — so one arriving message left `health` reporting
`degraded("building the search index")` for the rest of the process's life, over a finished
index. Latent while nothing consumed the reports; rendered the moment the settings screen
followed them, which is the usual shape of wiring up a second half. `reportingProgress` is now
the caller's decision, and `steadyStateIsNotABuild` holds it.

### 5. Telling the client the truth — **done, as the fallback**

An index that is not finished under-reports, and it does so silently — the same failure this
document exists to fix, wearing a different hat. The decision was between a new `metadata` key
saying so (a contract, the moment a client reads it) and falling back to `LIKE` until the index
can answer in full. **The fallback, and no new key**: it costs nothing, adds no contract, and
returns the behaviour the server had before the feature rather than a worse one.

`SearchIndexStore.matchingRowIDs` returns nil — which the repository reads as "use `LIKE`" —
in four cases:

1. The index is not open: the feature is off, or unsupported on this Mac.
2. `backfill_complete` is false: it has not walked the whole table yet.
3. The term is one a token index cannot express (`%term`, an interior wildcard, a `_`).
4. The read itself failed. `matchingRowIDs` does not throw: the answer is always `LIKE`, so
   there is nothing for a caller to recover from, and the store logs it at `warning` because
   unlike a pass that retries in a minute this one does not heal.

`incompleteBackfillFallsBack` pins the second, which is the one that matters.

#### Several text conditions are several widenings

The union composes under `AND`, so each `.textLike` filter becomes its own bracketed `OR` and
the `AND` already between filters does the combining:

```sql
(m.ROWID IN (…idsA…) OR m.text LIKE '%dinner%')
AND (m.ROWID IN (…idsB…) OR m.text LIKE '%harbour%')
```

No set arithmetic, which is why this works now and did not before. Under the replacement shape
two conditions really would have had to intersect two id sets, and rather than write that the
first version answered only a query carrying exactly one text condition — sending both to
`LIKE`, and therefore finding nothing at all on macOS 26. The restriction outlived its reason
by one refactor.

`MessageRepository.maximumIndexedTextTerms` caps how many the index answers at **four**. That
is a bound on the statement, not on what the route accepts: each answered term splices up to
`defaultMatchLimit` literal row ids into the SQL, so a hundred conditions would otherwise build
a seven-megabyte statement. Conditions past the fourth keep the plain `m.text LIKE ?` they
would have had with no index at all. No client is known to send even two.

`twoTermsAreBothWidened`, `oneUnanswerableTermDoesNotBlockTheOther` and
`termsPastTheCeilingFallBack` pin the three behaviours, and the first fails if the
single-condition guard comes back.

#### The index WIDENS the `LIKE`; it never replaces it

The condition `MessageRepository.resolvingSearch` builds is

```sql
(m.ROWID IN (…the index's matches…) OR m.text LIKE ? COLLATE NOCASE)
```

and the `OR` is the important character. The two halves answer different questions and
**neither answer contains the other**:

- the index reaches messages whose `text` column is empty — the whole point of it, and
  everything sent since macOS 26;
- `LIKE` reaches a fragment in the middle of a word, and a word inside a Chinese or Japanese
  sentence, neither of which a token index can express.

This started out as a replacement — resolve the index's answer, drop the `.textLike` filter —
and that took results away. Measured against the real 422,042-message database:

| Term | Before the feature (`LIKE`) | Replacement | Union |
|---|---|---|---|
| `%tomorrow%` — prefix, the good case | 2,020 | 2,070 | 2,070 |
| `%omorrow%` — fragment mid-word | 2,020 | **0** | 2,020 |
| `%morrow%` — one token matched by prefix | 2,031 | **1** | 2,031 |
| `%晚饭%` — a word inside an unspaced sentence | matches | **0** | matches |

The third row is the one that shows why an "if the index found nothing, fall back" rule is not
enough: the index found *something*, so the fallback never fired, and one confident result
stood in for 2,031. The fourth is the widest blast radius — `unicode61` breaks on anything that
is not a letter or a digit, every character of Chinese, Japanese and Thai is a letter, so an
entire sentence in one of them is a single token (`明天我们去吃晚饭好吗` is one term in
`fts5vocab`). Under the replacement, switching this feature on switched message search off for
those users.

The union costs the scan `LIKE` always cost — **110 ms** over 422,042 messages, measured — and
in exchange the feature is *purely additive*: it cannot return less than the server did before
it existed. That is the property to keep, and three tests hold it:
`infixTermFallsBackToLike`, `partialIndexMatchStillUnionsWithLike` and
`unspacedScriptFallsBackToLike`, each of which fails if the `OR` half is removed.

The other route — widening the index so it could answer these itself — is `trigram`, and it is
not free. It needs `detail='full'` (with `detail='none'` the `CREATE` succeeds and every
substring query then errors `phrase queries are not supported`), and `detail='full'` restores
exactly the token positions whose absence is what lets this document claim the index cannot be
read back as sentences. It also cannot answer a query shorter than three characters, which
includes most two-character CJK words. So the tokenizer stays and the column match stays
beside it.

#### The window this leaves, stated rather than hidden

A message that arrives AFTER the backfill completes is not indexed until the next tick, so for
up to sixty seconds a search does not find it. On macOS 26 that changes nothing — `LIKE` cannot
find it either, because its `text` column is empty — but on an older release, where the column
is populated, it is a real sixty-second regression against the un-indexed server.

Accepted, and it is the same trade the whole cursor design makes: the ROWID walk is what makes
the index COMPLETE, and completeness is worth more than the last minute of latency. Closing it
would mean forwarding new messages through the reindex hook as well, which is two lines and was
deliberately not done — the hook is lossy by design (`maximumAnnouncedPerTick`), so the cursor
would still have to walk them, and a second writer for the same rows is a second thing to reason
about. Revisit if anyone reports it.

### 6. The tests that keep it honest

- A message whose `text` is empty and whose `attributedBody` carries the term **must** be
  returned by `message.text LIKE ?`. This is the thing the current code gets wrong, it goes in
  `MessageFilterSQLTests`, and it asserts the **rows and the `total`**, both of which are wrong.
- The index and the `LIKE` path agree on a corpus where both work, so the routing cannot
  silently change results.
- Switching the setting off removes the file.
- An interrupted backfill resumes from its high-water mark rather than restarting or skipping.
- A query plan assertion, in the shape `ChatOrderingPlanTests` uses: the row-id lookup seeks and
  does not scan.

---

## Deliberately not in this plan

**The Private API search path.** `searchMessages` is already wired end to end — contract method,
`WireKey`, dispatch, `PrivateAPIClient` — and only `IMCoreBridge.searchMessages` throws
`notImplemented`. Finishing it would add a second source with better recall on things we cannot
decode. It is not the foundation, because it works only while the helper is injected, and a
search feature that disappears with the Private API is one users cannot rely on. Revisit once the
index exists and its gaps are known rather than guessed.

**A header re-dump.** Only needed for the path above. No group in `Tools/private-api/hosts.conf`
covers Messages search today, so it would be a new group and a new dump, and there is no reason
to spend it until the Private API path is actually wanted.

**Indexing attachments, subjects or sender names.** Message text first. Each addition widens what
the file holds, so each deserves its own decision rather than arriving as scope creep.

**Scoping the index to a window** (the last N days rather than everything). A smaller index is a
smaller exposure and would suit somebody who wants recent search without a full history on disk.
Worth having, worth doing after the whole-history case works.

---

## See also

- `.claude/docs/database.md` — schema contributors, and why `AppDatabase` declares no tables
- `docs/TESTING.md` — what the suites assert
- `Sources/BBIMessage/MessageFilter.swift` — the typed allowlist, and what `.textLike` alone
  can and cannot reach
