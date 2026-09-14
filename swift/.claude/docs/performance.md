# Memory, processes and concurrency

Two things this codebase treats as constraints rather than qualities: **it must run comfortably on
an old Mac mini**, and **every child process and every async boundary here has already produced a
bug worth not repeating.**

---

## Memory budget

The target hardware is an old Mac mini left running as an always-on server. Headroom here is spent
easily and recovered slowly, so the budget is asserted rather than hoped for.

| Scenario | Target resident memory |
|---|---|
| Idle, headless, socket-only | < 60 MB |
| Idle with UI open | < 150 MB |
| Serving a 1000-message query | no more than **+40 MB over idle**, returning to baseline after |
| 24-hour soak under synthetic traffic | **flat**, no upward trend |

Two of these are asserted in CI on a fixture dataset
(`Tests/BBIMessageTests/MemoryBudgetTests.swift`, `Sources/BBCore/MemoryFootprint.swift`): the
query budget and the return to baseline. The two idle figures and the soak are NOT: a test
runner hosts the whole package's symbols, so "idle" there is nothing like a shipped headless
server's, and no soak runs anywhere. **The numbers are proposed rather than measured on real
hardware**, so adjust deliberately rather than raising one to make a test pass.

A budget only means something if the workload can approach it. The +40 MB query budget was
asserted against an actual 1.5 MB -- a 27-times margin that would have survived a twentyfold
regression -- because it measured only the repository call, stopping before projection,
serialization and the response buffer, and measured GROWTH after an autorelease drain, which
cannot see a peak at all. The peak is the number that matters on a machine with 4 GB, because
exceeding it means swapping to a spinning disk. `MemoryFootprint.peak` samples it, and
`thousandMessagePagePeakBudget` asserts the whole path against a recorded baseline with stated
slack. **Record the machine, OS, architecture and build beside any number quoted from a
measurement**; the concurrency figures in `Settings.chatDatabaseReaders` had none, and were
twenty times off when re-measured.

**Nothing here has ever been measured on x86_64.** Every number in this document comes from
Apple silicon, and a large share of installs are 2012-2017 Intel Macs running macOS 26 through
OpenCore Legacy Patcher. CI builds and runs arm64 only; the x86_64 slice is compiled on a
release tag and executed nowhere.

### The tactics

- **Stream, don't buffer, attachments.** A download is served in 64 KB chunks, read with
  `pread` on the NIO thread pool, so peak memory is the chunk and not the file. NOT sendfile:
  this said `FileRegion` and a comment in the same file said the opposite. The bytes do pass
  through the heap; the bound is what holds. `Content-Length` is set, as the reference sets
  it, so a client can show progress. Never read an attachment into memory, and never
  reassemble a chunked upload whole.
- **Queries ARE materialized, and the cap is the only thing preventing a blowup.** This said
  the opposite, and it was never true: `readCursor` exists and has no callers anywhere in the
  source, while `fetchAll` appears 44 times. So the `limit ≤ 1000` cap IS load-bearing, which
  the previous wording explicitly said it must not be. Rewriting the read path around cursors
  would be a real change and nobody has made it; until then, know which of the two you are
  relying on. The serialization half is now true: `JSONValue.serialize()` writes UTF-8 bytes
  directly and no longer builds a parallel Foundation tree first.
- **Every cache gets an eviction policy, not just a TTL.** TTL-only trimming lets a cache grow
  without bound under sustained load, because entries arrive faster than they expire. Two
  corrections to what this used to claim. The byte budgets are real on DISK and are COUNTS in
  memory: `BoundedCache` caps entries, not bytes, so a cache of 20,000 fingerprints is 15 MB
  and nothing in its declaration says so -- measure the entry and put the number in the
  comment, as `ChangeDetector` now does. And of the five caches this list named, the message
  cache and the avatar thumbnail cache do not exist; the ones that do are the contact index,
  the attachment conversion cache, the attachment metadata reader, the blurhash cache and the
  socket replay ring.
  - **A TTL that nothing sweeps is not an eviction policy.** `BoundedCache.trim()` had no
    callers at all, so every TTL in the server was decorative and only the count cap ever
    reclaimed: a quiet server held every fingerprint it had ever taken. If a cache declares a
    TTL, something has to call `trim()` on a schedule.
  - **The rule applies to caches on DISK, and those are the ones that get missed.** An in-memory
    cache is bounded by a restart whether or not anyone wrote a policy; a disk cache is not, so
    an unbounded one is a slow leak that survives everything. `AttachmentConversion` was exactly
    this: one entry per image or voice note any client ever fetched, plus one per requested size
    of the same photo, keyed by hash, checked for staleness, and never deleted. It now sweeps to
    a size and age budget, triggered by an `IntervalGate` after a conversion is WRITTEN (the
    only moment the cache can grow) so the budget never costs a directory scan per download.
    A sweep must also match its own filenames rather than deleting whatever it finds: the cache
    directory is injectable, and the default sits under Application Support beside things that
    are not ours.
- **`DatabaseQueue` over `DatabasePool`** by default: one SQLite connection, not N. Pooling is an
  opt-in setting for powerful machines.
- **Change detection never polls the table on a quiet Mac.** File events are the trigger; the
  30-second backup asks `PRAGMA data_version` (a shared-memory read) and queries only when it
  moved. The seven-day reconcile is gated the same way. A timer that queries unconditionally
  is the thing that pinned CPU on old hardware, and it must not come back. When it does query,
  it reads fingerprints (ten narrow columns, keyset-paged on the date index) and hydrates full
  rows only for what changed. See [`database.md`](database.md#change-detection).
- **`BoundedCache` evicts in O(1).** Insertion order is a queue with a head index and
  tombstones, not an array searched and shifted per removal. The detector evicts thousands of
  fingerprints per reconcile pass; the linear version made that quadratic.
- **Autorelease pool discipline** in every long enumeration. The classic Foundation footgun;
  shows up as sawtooth growth. Applied in the contacts ingest, which is the only enumeration
  that currently has it -- this used to claim attachment scans and message batches too, and
  neither does. Whether they need it is a question nobody has measured; the claim that they
  already had it is what stopped anyone asking.
- **Value types and `Sendable` structs** for domain models. The reason given here -- that this
  stops serialization allocating a parallel dictionary representation of every message -- did
  not follow and was not true: serialization built exactly that, as a tree of boxed Foundation
  objects, until `JSONValue.serialize()` was rewritten to emit bytes. Value types are still
  the right default; they were never what prevented that.
- **Bounded concurrency on fan-out**: per-token FCM sends and webhook dispatch run through a
  limited task group, never unbounded `Promise.all`-style parallelism. Attachment conversion
  was named here for a long time with no limiter of any kind behind it -- no semaphore, no task
  group, no gate -- so N concurrent downloads meant N full-resolution decodes at 15 MB each. It
  goes through `ConversionGate` now, and a test asserts the converter actually reaches it,
  because a claimed limiter nothing calls is indistinguishable from no limiter.

If you add a cache, a fan-out, or a query that can return an unbounded number of rows, one of the
above applies to it.

---

## Never construct `Process`

[`Sources/BBCore/Subprocess.swift`](../../Sources/BBCore/Subprocess.swift) is the only place that
runs a child process to completion. Nine modules used to build their own `Process()`, each
independently re-deciding the same four things:

- whether to drain the pipe before waiting (**getting it wrong deadlocks past 64 KB**)
- whether to detach stdin (`unzip` prompts when an archive contains a name that already exists)
- whether to have a timeout at all (**three of them did not**)
- whether the blocking wait happens on a cooperative-pool thread

`Subprocess.run` is async and takes a **required** timeout, no default, deliberately, so the
decision is made once per call site rather than forgotten. `runSynchronously` exists for the one
shape that cannot be async, a default argument. `launch` starts something and does not wait.

**`BBProxy/DaemonProcess` is the exception and stays one.** Supervising a long-running tunnel
needs streaming output, readiness signals, its own process group and a termination handler, none
of which belong in a run-to-completion helper.

---

## Five traps `DaemonProcess` surfaced

Recorded because each is a **general** async trap, not a detail of that file. A mocked process
would have hidden all five.

1. **A cancelled task suspended on a continuation is never resumed.** `withThrowingTaskGroup`
   waits for every child before returning, so racing a wait against a timeout deadlocks the group
   unless the cancellation handler resumes the continuation itself. The readiness timeout appeared
   to work and in fact waited for the process to exit.
2. **Registering a waiter asynchronously races the thing it waits for.** The continuation is
   installed from a detached task, and a fast daemon prints its URL inside that window: the match
   was discarded and a healthy tunnel timed out. Early signals must be buffered.
3. **When you buffer one edge of a race, buffer both.** Trap 2 was solved for the success case;
   the same window drops a *termination*. A daemon that dies in milliseconds (bad authtoken, port
   already forwarded) exits before the waiter exists, so nothing resumes it and the caller waits
   out the **entire** readiness timeout and then reports the wrong reason. Found by running sixty
   early-exit daemons concurrently (hit up to 20 in 60); invisible in a serial test.
4. **Handing bytes to an actor through a `Task` loses them.** A readability handler that reads
   `availableData` synchronously and forwards it with `Task { await ingest(…) }` loses the output
   of a process that prints and exits: termination is handled first, and the drain finds a pipe the
   handler already emptied, so the failure is reported with **no output at all**, the one thing
   the user needed. Capture into a lock-protected buffer, holding the lock **across the read** as
   well as the append; locking only the append leaves the same race in a smaller window.
5. **Never signal a process *group* you did not create.** `Process` does not put its child in a new
   group, so `kill(-getpgid(pid), …)` signals the server's own group: under a test runner, the
   test runner. Catching a daemon's children needs `posix_spawn` with `POSIX_SPAWN_SETPGROUP`;
   short of that, SIGTERM to the child is correct, and all three tunnel binaries clean up their own
   children on it.

Also from that investigation: **a handler released only in `stop()` leaks when the process exits
on its own.** Every crash left a dispatch source and the pipe's read descriptor alive for the life
of the server. Release on the termination path too.

Known and **not** fixed: the drain blocks while an orphaned grandchild holds the pipe's write end,
which `cloudflared` can produce.

---

## Async boundaries that have already bitten

- **`NSAppleScript` pumps a nested run loop**, re-entering the executor on the same thread. Passing
  a cache `inout` across that boundary made the second entry take exclusive access again and the
  Swift runtime trapped, on the ordinary path of a non-SIP user sending two messages close
  together. See [`imessage.md`](imessage.md#applescript-is-osakit-not-a-shell-out).
- **`performSelector:onThread:waitUntilDone:YES` parks a cooperative-pool thread** for the length
  of the call. Post with `NO` and bridge with `withCheckedContinuation`.
- **GRDB's async `read` silently resolves to the synchronous overload** when the closure's result
  is not `Sendable`: it blocks while still reading as `await`. This is why `AppDatabase` does not
  expose its queue. See [`database.md`](database.md).
- **`EventBus.emit` queues and returns.** Each sink drains its own lane with a per-event
  timeout (30s default), so the message poller never waits on a webhook. Do not spawn a
  detached task to emit; the bus already does not block.

---

## Locks

`OSAllocatedUnfairLock<State>` for anything shared across threads that an actor cannot own
(`Subprocess.ExitWaiter`, `ManualClock`, `LoggingSystemBootstrap`, the helper's socket client).
It is `Sendable` on its own, so the type that holds it needs neither `@unchecked` nor
`nonisolated(unsafe)`. A completion block that has to be awaited is a `ResumeOnce`
(`Helper/HelperShared`). `NSLock` and `nonisolated(unsafe) var` are the smell; the six sites
that had them were converted in one pass and the remaining three statics are write-once at load.

## The wiring lesson

> A phase is not done when its module is tested. It is done when something in the composition root
> calls it **and a test asserts that call exists.**

`Tests/CompositionTests/EventDeliveryWiringTests.swift` is the pattern: it asserts *wiring*
rather than behaviour, because behaviour was never the part that was broken.

Three defects were reachable only by booting the server, and none had any test that could have
found them: the `AppleScriptRunner` re-entrancy trap, a `ChangeDetector` fault, and TLS hostname
selection: where a SAN dNSName is an ASN.1 IA5String and the macOS default computer name is
`<Name>’s MacBook Pro` with a **U+2019 apostrophe**, so certificate generation threw on a stock
Mac and HTTPS silently degraded.

**When you finish a module, add the wiring test before you call it done.**
