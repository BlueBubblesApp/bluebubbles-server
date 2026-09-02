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

These are asserted in CI on a fixture dataset (`Tests/BBIMessageTests/MemoryBudgetTests.swift`,
`Sources/BBCore/MemoryFootprint.swift`). The numbers are proposed rather than measured on real
hardware — **the point is having a number CI can fail on**, so adjust deliberately rather than
raising one to make a test pass.

### The tactics

- **Stream, don't buffer, attachments.** NIO `FileRegion` (sendfile), so a 500 MB video never
  enters the heap. Never read an attachment into memory, and never reassemble a chunked upload
  whole.
- **Cursor, don't materialize, queries.** `Row.fetchCursor` with a streaming JSON encoder writing
  directly to the response body — never build `[[String: Any]]` and then serialize it. The
  `limit ≤ 1000` cap is a backstop, and must not be the only thing preventing a blowup. Use
  `ReadOnlyDatabase.readCursor`.
- **Every cache gets a byte budget and an eviction policy, not just a TTL.** That covers the
  message cache, the contact index cache, avatar thumbnails, the attachment cache, and the socket
  replay ring. TTL-only trimming lets a cache grow without bound under sustained load, because
  entries arrive faster than they expire.
  - **The rule applies to caches on DISK, and those are the ones that get missed.** An in-memory
    cache is bounded by a restart whether or not anyone wrote a policy; a disk cache is not, so
    an unbounded one is a slow leak that survives everything. `AttachmentConversion` was exactly
    this: one entry per image or voice note any client ever fetched, plus one per requested size
    of the same photo, keyed by hash, checked for staleness, and never deleted. It now sweeps to
    a size and age budget, triggered by an `IntervalGate` after a conversion is WRITTEN — the
    only moment the cache can grow — so the budget never costs a directory scan per download.
    A sweep must also match its own filenames rather than deleting whatever it finds: the cache
    directory is injectable, and the default sits under Application Support beside things that
    are not ours.
- **`DatabaseQueue` over `DatabasePool`** by default — one SQLite connection, not N. Pooling is an
  opt-in setting for powerful machines.
- **Autorelease pool discipline** in every long enumeration (contacts, attachment scans, message
  batches). The classic Foundation footgun; shows up as sawtooth growth.
- **Value types and `Sendable` structs** for domain models, so serialization does not allocate a
  parallel dictionary representation of every message.
- **Bounded concurrency on fan-out** — per-token FCM sends, webhook dispatch and attachment
  conversion all run through a limited task group, never unbounded `Promise.all`-style
  parallelism.

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

`Subprocess.run` is async and takes a **required** timeout — no default, deliberately, so the
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
   installed from a detached task, and a fast daemon prints its URL inside that window — the match
   was discarded and a healthy tunnel timed out. Early signals must be buffered.
3. **When you buffer one edge of a race, buffer both.** Trap 2 was solved for the success case;
   the same window drops a *termination*. A daemon that dies in milliseconds — bad authtoken, port
   already forwarded — exits before the waiter exists, so nothing resumes it and the caller waits
   out the **entire** readiness timeout and then reports the wrong reason. Found by running sixty
   early-exit daemons concurrently (hit up to 20 in 60); invisible in a serial test.
4. **Handing bytes to an actor through a `Task` loses them.** A readability handler that reads
   `availableData` synchronously and forwards it with `Task { await ingest(…) }` loses the output
   of a process that prints and exits: termination is handled first, and the drain finds a pipe the
   handler already emptied — so the failure is reported with **no output at all**, the one thing
   the user needed. Capture into a lock-protected buffer, holding the lock **across the read** as
   well as the append; locking only the append leaves the same race in a smaller window.
5. **Never signal a process *group* you did not create.** `Process` does not put its child in a new
   group, so `kill(-getpgid(pid), …)` signals the server's own group — under a test runner, the
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
  Swift runtime trapped — on the ordinary path of a non-SIP user sending two messages close
  together. See [`imessage.md`](imessage.md#applescript-is-osakit-not-a-shell-out).
- **`performSelector:onThread:waitUntilDone:YES` parks a cooperative-pool thread** for the length
  of the call. Post with `NO` and bridge with `withCheckedContinuation`.
- **GRDB's async `read` silently resolves to the synchronous overload** when the closure's result
  is not `Sendable` — it blocks while still reading as `await`. This is why `AppDatabase` does not
  expose its queue. See [`database.md`](database.md).
- **`EventBus.emit` blocks until every sink finishes or times out** (30s default). Nothing
  buffers on the caller's behalf, so **the message poller and anything else that must not stall
  emits from a detached task.** Delivery latency is a sink's problem, never the detector's.

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

`Tests/CompositionTests/EventDeliveryWiringTests.swift` is the pattern — it asserts *wiring*
rather than behaviour, because behaviour was never the part that was broken.

Three defects were reachable only by booting the server, and none had any test that could have
found them: the `AppleScriptRunner` re-entrancy trap, a `ChangeDetector` fault, and TLS hostname
selection — where a SAN dNSName is an ASN.1 IA5String and the macOS default computer name is
`<Name>’s MacBook Pro` with a **U+2019 apostrophe**, so certificate generation threw on a stock
Mac and HTTPS silently degraded.

**When you finish a module, add the wiring test before you call it done.**
