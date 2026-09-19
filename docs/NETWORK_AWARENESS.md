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
| `LicenceService` | `.never` — the daily timer is the retry | **up to 24 hours** |

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
3. **A licence refresh that fails on a dropped connection** waits up to a day. Harmless inside
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
| **The internet is reachable** | the six proxies, `LicenceService`, push | path satisfied, and to where |

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
| `.running` | **Nothing.** It is working; a route change is not its business |
| `.failed` | Restart. This is the case the whole plan exists for |
| `.inactive` (retries exhausted) | Restart. The reason it gave up may have just gone away |
| `.stopped` (switched off) | Nothing. A person turned it off |
| `.starting` | Nothing. Let the attempt in flight finish |

`ServiceHealth` already carries all five (`BBServiceKit/Service.swift`), and
`ServiceRegistry.health()` already reports them — so this reads existing state rather than
adding any.

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

The exception is `LicenceService`, which does not want a restart but an immediate refresh. It
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
| `NetworkPathObserverTests` | The one claim only real time supports: a burst inside the debounce window produces ONE transition, carrying the SETTLED state rather than the first |
| `NetworkRecoveryPolicyTests` | The §4 table, exhaustively: every `ServiceHealth` case maps to act/do-nothing, driven by `ManualClock` for the rate floor |
| `CompositionTests` | The observer is constructed, the recovery service is registered, and it is not registered twice |

**A timing test waits for a signal, never for a margin.** `NetworkPathObserverTests` failed
intermittently under the full parallel run and passed every time on its own, because both of its
waits were guesses about SCHEDULING written as guesses about time. A sleep does not make the pump
run: when it had not, a fed baseline and the burst after it landed in one debounce window, the
whole lot evaluated as the first observation — which is never a transition — and nothing was
published. The baseline is STATED now (`NetworkPathObserver.init(…startingFrom:)`) and the
transition is WAITED for, with `settledEvaluations` as the signal that the debounce has actually
fired. Only the "and nothing more arrived" window is still a sleep, because that claim is about
elapsed time and no signal can stand in for it. Widening a margin was tried first and is what
this replaces.

**`NWPathMonitor` itself is not unit-testable** and should not be faked. The observer takes the
path values as input; a test scripts them. Whether the OS delivers what we expect is a question
for a run on a real machine, and §5 already names the one that has to be measured.

---

## 9. Order

1. **`NetworkPathObserver` + `NetworkTransition`, with tests.** Publishes, nothing consumes.
   Log the transitions at `debug` and **run it on this Mac for a day**: sleep it, change
   networks, unplug Ethernet. That log answers §5 and calibrates the debounce, and it is the
   step that prevents designing around a guess.
2. **`NetworkRecoveryService`**, acting only on `.failed`/`.inactive`. The HTTP bind case first,
   because it is the recorded bug and the easiest to reproduce: pin `bind_address` to the
   current LAN IP, turn Wi-Fi off, wait three minutes, turn it back on.
3. **The proxies**, once the HTTP case has been watched for a while.
4. **`LicenceService`**, last and optional: an immediate refresh instead of waiting a day.

Steps 2–4 are each small. Step 1 is where the real work is, and most of it is watching.

---

## 10. Open questions

1. **Does `NWPathMonitor` deliver a usable edge on wake?** (§5) Measured in step 1.
2. **Should `HTTPService` rebind, or restart?** Restarting is simpler and reuses the registry.
   Rebinding is less disruptive to connected clients but means the listener grows a second way
   to change its address. Start with restart.
3. **Does a path change that keeps the path satisfied — Wi-Fi to Ethernet — need anything?**
   For `bind_address` it might: the pinned address may now be on the wrong interface. Deferred
   until the step-1 log shows how often it actually happens.
4. **Should the registry own this instead?** A `NetworkDependentService` protocol, or the
   registry retrying exhausted services on a signal, would be more general. Rejected for now as
   speculative: two services and one symptom do not justify widening `BBServiceKit`, which is
   frozen for exactly this kind of reasoning.
