# Network transitions — plan

The server does not know when the network changes, and it has no way to find out. This is the
plan for giving it one, and for deciding what may act on it.

**Status: not built.** Nothing in this document exists. The recorded symptom is `TODO.md`
§ "A pinned bind address that disappears retries ten times and gives up".

---

## 0. What is true today

**MEASURED — there is no network observation anywhere in the server.** `NWPathMonitor`,
`NWPath` and `NSWorkspace.didWakeNotification` have zero hits outside the SwiftUI app. Nothing
below the app knows that an interface came or went, that a Mac woke, or that the route to the
internet changed.

What stands in for it is the registry's supervised restart: a service that throws is retried on
a bounded backoff and then left alone. Those bounds, computed from
`RetryPolicy.delay(forAttempt:)` (`BBCore/AsyncPrimitives.swift:85`, ×2 per attempt, capped):

| Service | Policy | Gives up after |
|---|---|---|
| `HTTPService` | base 1s, max 30s, 10 attempts | **2.5 minutes** |
| `ProxyService<…>` ×6 | base 5s, max 120s, 10 attempts | **10.6 minutes** |
| `LicenseService` | `.never` — the daily timer is the retry | **up to 24 hours** |

So the failure is not that retrying is wrong. It is that **the retry window is a guess about
how long a network takes to come back**, and the guess is wrong in both directions: too long
for a Wi-Fi blip, far too short for a router that reboots while nobody is home.

### The three things that actually break

1. **A pinned bind address that disappears.** `bind_address` set to a LAN IP, and the address
   goes with a Wi-Fi drop, a dock change, a VPN, or a DHCP lease. The listener cannot bind,
   retries for 2.5 minutes, and stops. A network back at minute four leaves the server bound to
   nothing until somebody restarts it. **This is the recorded TODO and the worst of the three**,
   because it is silent and the machine is usually headless.
2. **Tunnels after a real outage.** Ten minutes of backoff covers a blip. It does not cover a
   router rebooting, an ISP outage, or a lid closed overnight.
3. **A license refresh that fails on a dropped connection** waits up to a day. Harmless inside
   the seven-day window (§3.2 of `SUBSCRIPTION_PLAN.md`) and worth fixing because it is free.

---

## 1. Polling or listening

Both were considered. They are not equally good, and it is worth being precise about why,
because the codebase already contains the polling answer.

**A bounded backoff IS a poll.** `HTTPService` asking the kernel to bind every few seconds for
2.5 minutes is a poll with a timeout, and it has both of a poll's failure modes: it asks when
nothing has changed, and it stops asking before something does.

**The OS already knows.** `NWPathMonitor` (Network.framework, macOS 10.14+, comfortably under
the Sonoma floor) reports the current path and calls back on every change: an interface
appearing or disappearing, a route changing, the whole path going unsatisfied. It is
dispatch-queue based and needs no run loop, so it works in the headless CLI exactly as it does
in the app.

**So: listen.** Not because timers are inelegant — the app's `CLAUDE.md` already bans them for
its own reasons — but because the information exists, is free, and is more accurate than any
interval we could pick. A poll frequent enough to feel responsive is mostly wasted work; one
cheap enough to ignore is too slow to matter.

**Keep the backoff anyway.** The two are not alternatives. Backoff handles "this failed for a
reason that has nothing to do with the network" (a port already in use, a daemon that crashed);
the path signal handles "the reason it failed has just stopped being true". Removing the
backoff and relying on the signal alone would leave a service dead after a failure the network
never caused.

---

## 2. The trap: `.satisfied` does not mean usable

The single thing most likely to make a naïve version of this worse than nothing.

`NWPath.status == .satisfied` means the system believes a route exists. On a Mac waking from
sleep, or associating with Wi-Fi, that becomes true **before** DHCP has finished, before DNS
resolves, and before the default route is real. A reconnect fired on the first `.satisfied`
will fail, burn a retry, and — with the current policies — may exhaust the budget on exactly
the wake it was meant to fix.

Three defences, all required:

- **Debounce.** Coalesce transitions over a short window (**start at 2 seconds**; measure).
  Waking a MacBook produces a burst of path changes as interfaces come up in sequence, and
  every one of them would otherwise be an independent reconnect storm.
- **React to the EDGE, not the level.** What matters is unsatisfied → satisfied. A path that was
  already satisfied and changed interface is a different event (§5).
- **Let the retry fail cheaply.** The signal grants an attempt; it does not promise success. The
  backoff still applies, so a too-early attempt costs one cycle rather than the budget.

---

## 3. Two different dependencies, and why the manifest cannot tell them apart

The tempting design: derive network-dependence from the `.network(hosts:)` entitlement a
service already declares. It is declarative, plugin-expressible, and needs no new manifest
field on a frozen surface.

**It does not work, and the reason is worth recording so nobody re-proposes it.**
`BuiltInManifests.http` does **not** declare `.network`, correctly: the HTTP service *serves*,
it does not make outbound connections. So the entitlement answers "does this call out", and the
service with the worst network-transition bug would be excluded from its own fix.

There are two distinct dependencies and they want different reactions:

| Dependency | Who has it | What the signal must carry |
|---|---|---|
| **A local interface with this address exists** | `HTTPService` (bind address) | the set of local addresses |
| **The internet is reachable** | the six proxies, `LicenseService`, push | path satisfied, and to where |

So the observer publishes both, and each service decides for itself. No manifest change, no new
entitlement kind, and the frozen surface stays frozen.

---

## 4. The rule that keeps this from being worse than the problem

**The signal is permission to retry. It is never an instruction to restart.**

A Mac moving from Wi-Fi to Ethernet, or bringing up a VPN, produces a path change while
everything is working perfectly. Restarting six tunnels and an HTTP listener because the route
changed would turn a transition nobody noticed into a visible outage — and `cloudflared` and
`ngrok` do their own reconnection, so tearing them down discards recovery already in progress.

Concretely: on a qualifying transition, act **only** on services that are already broken.

| Service state | On network return |
|---|---|
| `.failed` | **Restart.** This is the case the whole plan exists for, and it is the only one |
| `.running` | Nothing. It is working; a route change is not its business |
| `.degraded` | Nothing. Overloaded: `PrivateAPIGatedService` reports it for a Mac with no helper |
| `.inactive` | Nothing. It means deliberately not running, including "switched off" |
| `.stopped` | Nothing. No instance exists to restart |
| `.starting` | Nothing. Let the attempt in flight finish |

`ServiceHealth` carries all six (`BBServiceKit/Service.swift`) and `ServiceRegistry.health()`
reports them, so this reads existing state rather than adding any.

**This table was wrong when it was written, and the corrections are the useful part.** It was
drafted against an assumed mapping rather than against `ServiceRegistry`, and two rows were
inverted:

- It read `.inactive` as "retries exhausted" and `.stopped` as "switched off". It is the other
  way about. A service someone switched off reports `.inactive(reason: "switched off")`; so
  does one missing a `.required` permission, or one whose `canRun` declined. `.stopped` just
  means no instance. Restarting on `.inactive` would have restarted precisely what this
  section exists to protect, arrived at through this section's own table.
- It expected exhaustion to produce a state of its own. It does not: `supervise` gives up,
  logs and alerts, and leaves the instance in place, so the registry goes on reporting
  whatever the service says about itself.

`.degraded` was not in the table at all, and it was the state the recorded bug actually
produced — `HTTPService` reported `.degraded("not listening")`. A recovery pass written from
the original table would have done nothing for the one bug it was written for. That is why
`HTTPService` now reports `.failed` when it is not listening: `.degraded` means running but
not fully functional, and it could not carry both meanings for this and for `APIReachability`.

`NetworkRecoveryTests` pins each row, including the ones that must NOT restart.

---

## 5. Sleep and wake

Related, and probably **not a second signal**.

A Mac that sleeps loses its interfaces; waking brings them back, which is itself a path
transition. So `NWPathMonitor` likely covers wake without `NSWorkspace.didWakeNotification` —
which matters, because `NSWorkspace` is AppKit and needs a run loop, and the headless CLI has
neither. The lower-level alternative (`IORegisterForSystemPower`) is real but is a C callback
API and worth avoiding if the path monitor already answers.

**UNVERIFIED — this needs measuring before it is designed around.** The specific question: on
wake from a lid close, does `NWPathMonitor` deliver an unsatisfied→satisfied edge, or does it
deliver a satisfied path that was satisfied before sleeping? If the latter, wake needs its own
signal after all.

Note `auto_caffeinate` does not remove the question: it is off by default, and it prevents
*idle* sleep — a closed lid still sleeps.

---

## 6. Shape

**`NetworkPathObserver`, in `BBSystem`.** That module already owns the machine-facing
collaborators (`MachineIdentity`, `Permissions`, `SystemInfo`) and already answers "what are
this Mac's addresses", which is half of what the observer publishes.

```
NetworkPathObserver          wraps NWPathMonitor, debounces, publishes NetworkPath
  -> NetworkPath             { isSatisfied, isExpensive, interfaces, localAddresses }
  -> changes() -> AsyncStream<NetworkTransition>
```

`NetworkTransition` carries the edge and the new path, because a consumer needs both: *what
changed* decides whether to act, *what it is now* decides what to act on.

**One subscriber, not seven.** A `NetworkRecoveryService` in the composition root follows the
stream and asks the registry to restart the services that are broken. Rationale: the registry
already owns restart ordering and dependency propagation, and seven services each subscribing
would be seven places to get the "only if broken" rule wrong — and seven independent reactions
to one event.

The exception is `LicenseService`, which does not want a restart but an immediate refresh. It
can take the stream directly, or the recovery service can nudge it; decide when writing it.

**Follows the existing stream convention.** `ServiceRegistry.healthChanges()`,
`PrivateAPIRuntime.states()` and `AccessControlService.changes()` are the pattern the app's
guide names, and this is the same shape one layer down.

---

## 7. What can go wrong, and the answer

| Risk | Answer |
|---|---|
| **Flapping** — a marginal connection producing transitions every few seconds | Debounce, plus a floor between recovery attempts (**start at 30s**) |
| **Thundering herd** — six tunnels restarting at once into a network that just came up | Restart in the registry's declared dependency order, which it already does, and let each service's own backoff space its retries |
| **Firing too early** (§2) | Debounce; and the attempt failing costs one backoff cycle, not the budget |
| **Restarting healthy services** (§4) | Only `.failed` and `.inactive` are touched |
| **A captive portal** — path satisfied, internet not | Out of scope. It looks identical to a working network from here, and a probe that says otherwise is a second thing to get wrong |

---

## 8. Testing

The observer is a wrapper over an OS callback, so the design has to put the decisions somewhere
a test can reach — the same reason `SubscriptionPolicy` lives off the view.

| Test | Asserts |
|---|---|
| `NetworkTransitionTests` | Edge detection from a scripted sequence of paths, with no clock: unsatisfied→satisfied fires, satisfied→satisfied with a new interface does not |
| `NetworkPathObserverTests` | The debounce, on a `TestClock`: a burst inside one window produces ONE evaluation and ONE transition, carrying the SETTLED state rather than the first |
| `NetworkRecoveryPolicyTests` | The §4 table, exhaustively: every `ServiceHealth` case maps to act/do-nothing, driven by `ManualClock` for the rate floor |
| `CompositionTests` | The observer is constructed, the recovery service is registered, and it is not registered twice |

**A timing test moves a clock, never waits for a margin.** The observer's debounce sleeps on
an injected clock (`NetworkPathObserver.init(…clock:…)`), and `NetworkPathObserverTests` drives
it with a `TestClock`. Each change in a burst is fed once the previous one's window is parked on
the clock, so the pump has provably consumed it; the window is closed with `advance(by:)`; and
"nothing more arrives" is shown by advancing past every window that could still be pending,
which is exact where a wall-clock quiet interval could only be probable. The baseline is STATED
(`startingFrom:`) rather than fed, because a fed baseline races the burst after it into one
window, and the first observation is never a transition.

**`NWPathMonitor` itself is not unit-testable** and should not be faked. The observer takes the
path values as input; a test scripts them. Whether the OS delivers what we expect is a question
for a run on a real machine, and §5 already names the one that has to be measured.

---

## 9. Order

1. ~~**`NetworkPathObserver` + `NetworkTransition`, with tests.**~~ Built. Publishes, and now
   has one consumer.
2. ~~**`NetworkRecoveryService`**~~ Built, acting only on `.failed` — see §4 for why the
   original `.failed`/`.inactive` was wrong. It restarts every failed service rather than the
   HTTP one specially, because the rule reads health and needs no per-service knowledge.
3. **The proxies** need nothing: they are services, they report `.failed`, and they are
   already covered by the same rule. What is left is watching whether that is too eager for a
   tunnel that reconnects on its own.
4. **`LicenseService`**, last and optional: an immediate refresh instead of waiting a day.

**Still outstanding, and it is the measurement, not the code.** The observer's `debug` log
has not been watched on a real Mac for a day: sleep it, change networks, unplug Ethernet.
That answers §5 and calibrates both the 2-second debounce and the 30-second recovery floor,
neither of which is a measurement today. The end-to-end reproduction is also unrun: pin
`bind_address` to the current LAN IP, turn Wi-Fi off, wait three minutes, turn it back on,
and confirm the listener comes back on its own.

---

## 10. Open questions

1. **Does `NWPathMonitor` deliver a usable edge on wake?** (§5) Still unmeasured: the
   observer is built and its log has not been read over a real sleep/wake cycle.
2. ~~**Should `HTTPService` rebind, or restart?**~~ Restart, as planned: it reuses the
   registry's ordering and dependent propagation, and the listener does not grow a second way
   to change its address. Revisit only if dropping connected clients on a recovery turns out
   to matter more than the simplicity.
3. **Does a path change that keeps the path satisfied — Wi-Fi to Ethernet — need anything?**
   For `bind_address` it might: the pinned address may now be on the wrong interface. Deferred
   until the step-1 log shows how often it actually happens.
4. **Should the registry own this instead?** A `NetworkDependentService` protocol, or the
   registry retrying exhausted services on a signal, would be more general. Rejected for now as
   speculative: two services and one symptom do not justify widening `BBServiceKit`, which is
   frozen for exactly this kind of reasoning.
