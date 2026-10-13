# Subscription tiers: implementation plan

Machinery for a paid tier: an entitlement a server holds, a request-time gate that can refuse
a route with **402 Payment Required**, and a client-facing way to find out about it before
being refused.

> **Status note.** This document is the implementation plan, written before anything was
> gated. The mechanism shipped as described, and gating decisions have since been taken on
> top of it. Where the plan and the code disagree, **the code is authoritative**; the summary
> immediately below is kept in step with it.

## What is actually gated, and what it costs

Shipped prices, and the only place in this document that states them:

| Plan | Price |
| --- | --- |
| Monthly | **$3 / month** |
| Yearly | **$30 / year** |
| Lifetime | **$55**, one payment |

The fee and tax analysis in the sections below was worked at **$1/month and $12/year**, the
candidate prices at the time. Its *conclusions* stand -- annual billing collapses the fee
burden, and a merchant of record is worth its cut -- but read the absolute figures as the
reasoning that led here, not as the current prices.

**Gated today** (`minimumTier: .pro`):

- **11 of 23 private-API capabilities**, in
  `Sources/BBPrivateAPICatalog/CapabilityCatalog.swift`: stickers, sticker reactions,
  pinning, muting, spam and junk, screening unknown senders, FaceTime from a client, Find My,
  Send Later, polls, and conversation backgrounds.
- **One route group**, `sendLater`, in `Sources/BBHTTPAPI/RouteTable.swift`.
- **No service manifest.** The rule in the services section still holds.

The original plan said the first gate would land on new surface and never on anything a
client could already reach. That is not what happened: several gated capabilities --
stickers, pinning, muting, Find My -- were reachable before the tier existed, so an existing
user will see features they had become paid. That is a product decision, taken knowingly, and
it belongs in the release notes rather than being discovered.

Terminology in this document follows the repository's British spelling: a **license** is the
thing you hold, and to **license** is the verb. `LICENSE.md` and `COMMERCIAL.md` use the
American spelling because they are legal documents that quote a license by its published
name; that inconsistency is pre-existing and is not worth fixing.

---

## 0. The gate is bypassable, and that is fine

Stated once, up front, so nobody spends a week trying to solve it.

`swift/` is source available under PolyForm (`LICENSE.md`). Every check in this document runs
on the user's own machine, on the user's own copy of the source. Anyone who wants to can read
the gate, delete it, rebuild, and run their own build. There is no point at which a
BlueBubbles-controlled server is asked to permit anything, and there is not going to be one:
Firebase is the user's own project (`BBPushKit/FirebaseProvisioner.swift`), and ngrok,
Cloudflare and zrok are the user's own accounts (`BBProxy/Tunnels.swift`). Nothing here
changes that, and nothing here is trying to.

**That is an accepted outcome, not a problem to be engineered around.** Someone who would
rather patch a Swift file, keep an arm64e helper build working and re-do it on every release
than pay a few dollars a month is welcome to. The subscription is priced so that subscribing is
comfortably the path of least effort: **$3 a month**, or $30 a year, and at that price the
proposition is "support the project and the features are just on", not "defeat this if you
can". A person who chooses the other path was never going to be revenue.

One exception is worth naming, because it is the only one: a feature whose *work* happens on
our infrastructure (metered AI, or anything sold by the credit) is genuinely enforceable,
since the thing being bought is not in the build at all. §5.6 covers that shape. Everything
else in this document is local, and local means bypassable.

**Four rules follow, and they are the whole of the security posture:**

1. **Build the gate, do not build anti-tamper.** No binary self-checks, no obfuscation, no
   validating our own signature. It is real complexity, it breaks legitimate from-source
   builds, and it delays a determined bypass by an afternoon.
2. **The gate is honest, not defensive.** It refuses cleanly, explains why, and points at
   the purchase page. It never tries to detect that it has been tampered with, and it never
   punishes a machine it is suspicious of.
3. **Price and describe the tier as supporting the project.** Not as access control. The
   sentence a user reads should make sense to somebody who knows the source is public.
4. **Nothing here may degrade an unlicensed server.** Most users will never pay and must
   never notice this exists. §1.4 turns that into a rule with teeth.

---

## 1. Decisions that shape everything else

Seven, and the rest of the document is their consequences.

### 1.1 The gate runs at request time, not composition time

`FeatureFlag` decides which route **groups are mounted**: `application: .composition`
(`BBSettings/FeatureFlags.swift:71`), resolved once in `ServerComposition.routeGroups`
(`ServerComposition+Routes.swift`). A route in an unmounted group **404s**.

That is exactly wrong for a subscription. A 404 tells a client the endpoint does not exist,
which is indistinguishable from an old server, and it is the one answer that cannot carry
"you need a license". A gated route must be **mounted, routed, authenticated, and then
refused** with a status and a body that explain themselves.

So the subscription gate is a request-time stage, modelled on `PrivateAPIStage`
(`BBHTTPAPI/Middleware.swift:198`): a struct holding an async closure, consulted in the
dispatch chain at `HTTPServer.swift:339–360`. **Never a feature flag, never a composition
decision.**

### 1.2 Tiers are ordered data, and there is more than one from day one

One tier ships (`pro`). The type does not know that. A tier is a value with a rank, tiers
compare, and a route asks for a *minimum* tier. There is no `isPro` boolean anywhere in the
codebase: that is the shape that has to be torn out later, and it is cheaper to not write it.

A route also never names a *feature*, only a minimum tier. Feature-level entitlements are
carried in the token so the vendor side can do per-customer grants later, but the route table
expresses one thing: the floor.

A whole **service** can carry a floor too: a connection method or an integration that is part
of the paid tier. That is a different gate with different failure modes, and §5.5 covers it.

### 1.3 v1 is never gated, and a test enforces it

Backwards compatibility, not license policy: a shipped client calling a route that worked
last week and getting a 402 is a broken client, and clients are not under our control
(CLAUDE.md rule 1).

Mechanically: **no group in `RouteTable.groups` may carry a tier.** `RouteTable.groups` is
exactly the Node-parity table, and `RouteTableTests.swift:70` already asserts every group in
it is `apiVersion == 1`. One more assertion in the same file pins this and makes the rule
impossible to violate by accident. Gated routes live in `AdditiveRoutes` at
`RouteTable.latestVersion`, like every other new surface.

This also means **the gate can never fire on a default-configured server**, since a
default-configured server serves the v1 table plus the additive groups, none of which will
carry a tier when this lands.

### 1.4 Fail open on everything ungated. Fail closed on the gated surface.

A license that cannot be verified (no network, our issuing endpoint down, a corrupt cached
token, a clock that jumped) must have **no effect on anything ungated**. Messaging,
notifications, the socket, the UI: untouched, always.

**On the gated surface the rule is the opposite: unverifiable means refused** (§3.2). An
entitlement nobody can confirm is not an entitlement, and "unreachable" must not be a way to
hold paid features indefinitely. This is only a proportionate rule because of §1.3; base
functionality is never gated, so the worst case is a server that still does everything it did
before the subscription existed, minus the extras.

The blast radius of every failure mode in this document is therefore "the gated routes refuse,
with an accurate reason". A licensing subsystem that can take down a home messaging server is a
worse product than no subscription at all, which is why the one carve-out to failing closed is
a **load-bearing service that is already running** (§5.5), and that carve-out exists to avoid a
deadlock rather than to be generous.

Corollary: **the license check never blocks startup and never makes a network call on the
request path.** The stage reads an already-verified in-memory value. Refresh happens on a
timer in a service, off the request path entirely.

### 1.5 The license is per server, never per client

One Mac, one license. Never per connected client, per device token, per address, or per
enrolled principal.

This is the multi-client rule stated in `.claude/docs/api.md` and enforced everywhere else in
this codebase: several people share one server through one tunnel, and an entitlement keyed to
a client would lock out everyone but whoever activated it. Seats, if they ever exist, count
*Macs*, and the vendor's activation limit is what counts them.

### 1.6 The trust anchor is our own key, not the payment vendor's API

The server verifies an **Ed25519-signed entitlement token issued by us**, not a vendor API
response. Reasons, in order of weight:

- **The vendor becomes swappable.** The wire format, the settings keys, the cached token and
  every test are written against our claims. Changing payment provider is a change to one
  serverless function.
- **No vendor API key ships to users.** Vendor license-validation APIs authenticate with an
  account key. Embedding one in a source-available macOS app publishes it.
- **Offline verification.** A signed token with an expiry can be checked with no network at
  all, which is what lets the refresh margin in §3.2 work without a call on the request path.
- **We define the vocabulary.** Tiers, feature ids and refresh windows are ours, not whatever a
  vendor's license metadata field happens to allow.

`BBUpdates/AppcastSigning.swift` already does precisely this shape of verification: Ed25519
over bytes, public key in the binary, private key never shipped, for Sparkle appcasts. It is
the working precedent to copy, and §4 says what to share and what to duplicate.

### 1.7 A refusal is discoverable before it happens

CLAUDE.md's Private API rule: "make the capability discoverable before a client tries."
Same here. A client must be able to ask what the server's tier is and what it unlocks, and
get an answer, before it calls anything gated. §7.

---

## 2. Vendor: annual billing first, Creem second, behind our own signing endpoint

> **Status, 2026-09-18.** The vendor is **Creem**. Everything below still records how the
> choice was reasoned, and the reasoning held — but the conclusion it reached did not survive
> contact with an underwriter, so read §2.1 to §2.4 as the method and this note as the outcome.
>
> Lemon Squeezy **declined the store application**. Not for a listed prohibited product: their
> letter cites "the totality of data" and the rules Stripe, PayPal and the card networks impose
> on them, which is underwriting rather than policy. Best guesses, in order — the application
> pointed at a site for free open-source software with no visible paid offering and no pricing
> page; a reviewer spending a minute on BlueBubbles sees software built around Apple's iMessage
> and may read it as unlicensed IP; and the public site foregrounds donations, which are
> prohibited "without substantive product". There is reportedly no appeal.
>
> Paddle was the runner-up here on price and is now the worst fit on capability: **Paddle
> Billing has no license-key validation API at all** (Classic did), so it would mean bolting on
> a separate licensing vendor. Creem is a merchant of record at **3.9% + 40¢** — cheaper than
> Lemon Squeezy's 5% + 50¢ — with license keys, activation limits, and a validate/activate/
> deactivate API whose shape is close enough to Lemon Squeezy's that the issuer was a one-file
> change. Polar is the fallback if Creem also declines; Stripe directly is the floor, since it
> is self-serve and cannot decline, at the cost of building license issuance and becoming the
> merchant of record for VAT.
>
> **This cost one file**, which is the clause in §1.6 doing its job before a single payment was
> taken. No shipped server would have noticed. Two things did change with the vendor and are
> written up in `Tools/license-worker/README.md`: Creem's endpoints need an account API key, so
> the Worker is now structurally required rather than merely advisable; and activation is a
> prerequisite of validation rather than bookkeeping, which makes the KV namespace load-bearing.

### 2.1 The comparison

Two things decide this, and the API is neither of them.

**First, who is the merchant of record**: who is legally liable for collecting and remitting
sales tax and VAT in every jurisdiction a customer buys from. A non-MoR processor leaves that
entirely with you, and for digital goods sold internationally it is a serious ongoing
obligation for one person.

**Second, and at this price the dominant one: the fixed per-transaction fee.** Every fee
schedule is a percentage *plus* a flat amount. At $1 the percentage is noise and the flat
amount is everything.

At **$1/month, billed monthly**, on an international card (which most BlueBubbles users will
be):

| Service | MoR | Fee on $1 | You keep | Notes |
|---|---|---|---|---|
| **GitHub Sponsors** (personal → personal) | No | **$0.00** | **$1.00** | GitHub charges no fee on sponsorships from personal accounts. See the caveats below; they are real |
| **Creem** | Yes | 3.9% + $0.40 = $0.44 | **$0.56** | Cheapest conventional MoR. Young company |
| **Patreon** (new creator) | Yes | 10% + 2.9% + $0.30 = $0.43 | **$0.57** | The old sub-$3 micropayment rate is gone for anyone starting after Aug 2025 |
| **Paddle** | Yes | 5% + $0.50 = $0.55 | **$0.45** | All-inclusive: no surcharge for international, PayPal or subscriptions |
| **Polar** (new accounts) | Yes | 5% + $0.50 + 1.5% intl ≈ $0.57 | **$0.43** | The 4% + $0.40 rate is grandfathered to pre-May-2026 orgs or paid plans |
| **Lemon Squeezy** | Yes | 5% + 0.5% sub + 1.5% intl + $0.50 = $0.57 | **$0.43** | Surcharges stack on the headline rate |
| **Gumroad** | Yes | 10% + $0.50 + processing | **~$0.37** | Worst of the set at this price |
| **Stripe Managed Payments** | Yes | 6.4% + $0.30 = $0.36 | **$0.64** | Stripe's own MoR, built from the Lemon Squeezy acquisition. Best MoR at $1: its fixed fee is 30¢, not 50¢ |
| **Stripe** (direct) | **No** | 2.9% + $0.30 = $0.33 | **$0.67** | You remain the VAT/sales-tax registrant. That is the whole reason to use an MoR |

**Nothing on that list is acceptable at $1/month billed monthly.** The best conventional MoR
keeps 56% of a dollar, and the one people would reach for first keeps 43%.

Now the same products, **billed annually at $12**:

| Service | Fee on $12/yr | You keep | Effective rate |
|---|---|---|---|
| Creem | 3.9% + $0.40 = $0.87 | **$11.13** | 7.2% |
| Paddle | 5% + $0.50 = $1.10 | **$10.90** | 9.2% |
| Stripe Managed Payments | 6.4% + $0.30 = $1.07 | **$10.93** | 8.9% |
| Lemon Squeezy | 7% + $0.50 = $1.34 | **$10.66** | 11.2% |

**That is the finding.** Moving from $1/month to $12/year takes the fee from ~55% to ~9%, on
the *same vendor*, for the same money from the same customer. No vendor switch available comes
close: the gap between the best and worst MoR on the monthly plan is about 19 points, and
switching cadence is worth about 46. Annual billing also removes eleven card-expiry failures a
year, which at this price is otherwise the main way subscribers are lost.

**On fees alone the ranking is:** bill annually (worth ~46 points), then Creem, then Paddle,
then Lemon Squeezy. But once cadence is settled the vendor gap collapses: at $12/year Paddle
nets $10.90 and Lemon Squeezy $10.66, a difference of **24¢ per customer per year**. That is
not enough to decide anything, so §2.2 decides it on integration cost instead.

> Verify every figure before committing. These schedules change: Polar raised its rate in
> May 2026, Patreon withdrew its micropayment tier for new creators in August 2025, and
> Gumroad has added and removed fixed fees more than once. **Nothing below §2 depends on
> which row wins.**

### 2.2 Paddle vs Lemon Squeezy, on integration rather than price

Three differences that matter, and the fee is not among them.

**1. License keys: Lemon Squeezy has them; Paddle Billing does not.**

This is the big one, because it decides whether the signing function (§2.5) is stateless.

| | Lemon Squeezy | Paddle Billing |
|---|---|---|
| Key generation | Automatic, per order | **Yours to build** |
| Validation | `POST /v1/licenses/validate` returns status, expiry and activation count | **Yours to build** |
| Activation limits | Built in, configurable per license, `null` for unlimited | **Yours to build** |
| Deactivation | `POST /v1/licenses/deactivate` by instance id | **Yours to build** |
| What the function stores | **Nothing** | A key → subscription table, kept current from webhooks |

Paddle Classic had license keys; Paddle Billing, the current product, dropped them. Paddle
offers *delivery* of codes (webhook fulfilment, or uploading a list) but generating,
storing and validating them is yours.

Concretely, against this plan's design:

- **With Lemon Squeezy the function is stateless.** Receive a key, `POST` it to the license
  API, map the variant onto a tier, sign, return. No database, no webhook endpoint required
  for the happy path, nothing to reconcile. The "roughly thirty lines" in §2.5 is accurate.
- **With Paddle you are running a small stateful service.** A datastore, a webhook receiver
  with signature verification and idempotency, subscription lifecycle handling
  (`subscription.updated`, `.canceled`, `.past_due`), key generation, and an answer for what
  happens when a webhook is missed. Several hundred lines, and it is a thing that can break
  at 3am rather than a pure function.

Lemon Squeezy's license API also happens to model §1.5 and §3.3 exactly: one license, an
activation limit counting Macs, an instance id per activation. With Paddle that is a schema
to design.

**2. Onboarding: Paddle reviews you; Lemon Squeezy mostly does not.**

Paddle approval typically runs 3–7 business days, and multiple rejection cycles are commonly
reported by indie developers. They check that the legal entity name matches the website
exactly, that privacy and refund policies are reachable from the checkout flow, and for some
categories they ask for prior payment-processing history. None of it is unreasonable; it is
simply a gate that can cost two or three weeks. Lemon Squeezy is self-serve and fast.

> **Wrong, and it is the claim that decided this section.** Lemon Squeezy reviews store
> applications and declined ours outright (see the status note at the top of §2); reported
> timelines run one to four weeks with no published SLA. "Self-serve and fast" was an
> assumption written down as a fact, and it is corrected in place rather than deleted, because
> the shape of the mistake is worth keeping: an unverified claim about a vendor's PROCESS, in a
> comparison that was otherwise careful about their fees and their APIs. Every MoR underwrites,
> because the card networks make them.

**3. Longevity points the other way: Lemon Squeezy is on a migration path.**

Stripe acquired Lemon Squeezy in 2024. In January 2026 the first integration milestone was
announced as **Stripe Managed Payments**, which shipped into Stripe's own API in April 2026 as
a flag on Checkout Sessions; Lemon Squeezy's CEO has publicly called it "the future" and said
the intent is to give Lemon Squeezy users an easy path onto it. **No shutdown date has been
announced and new signups are still open**, and the product still has its own dashboard, API
and MoR model, but it is more plausibly a waypoint than a destination.

**Recommendation: Lemon Squeezy, and the longevity risk is already handled.**

The stateless integration is worth far more than 24¢ per customer per year. Building and
operating a license database to save that is a bad trade for one developer at any subscriber
count worth planning for: at 1,000 subscribers the saving is $240 a year, which is less than
the cost of one incident.

**And §1.6 is what makes this a low-stakes choice.** The server verifies *our* Ed25519 token
and has never heard of a vendor. Everything vendor-specific lives in one file on one Worker.
Moving to Paddle, or onto Stripe Managed Payments when Lemon Squeezy's path arrives there, is
a rewrite of that file plus a re-issue of tokens: the Swift side, the wire format, the
settings keys and every test in §10 are untouched. That was the point of the decision, and
this is where it pays.

Revisit when subscriber count reaches a few thousand; §2.4 works out where the arithmetic
actually turns.

### 2.3 What the merchant-of-record fee actually buys

Worth quantifying, because "handles tax for you" undersells it and the numbers decide whether
the 5% is a bargain or a waste.

**VAT is not a small number.** The EU average standard rate is **21.9%**, ranging from 17%
(Luxembourg) to 27% (Hungary); the UK is 20%. The 10% figure people have in mind is
Australia's GST or Japan's consumption tax, not Europe.

**It applies to a US seller from the first sale.** Since 2015, VAT on digital services sold to
an EU consumer is charged at the **customer's** local rate, and there is **no registration
threshold for sellers established outside the EU**: it is due on the first €1. The mechanism
is the non-Union OSS: register in one member state, charge each customer their own country's
rate, file one quarterly return. The UK, Norway, Switzerland, Australia, Japan and a growing
list of others run their own equivalents, each with its own registration.

**Domestically it is much lighter, with one trap.** US economic nexus is generally $100,000 or
**200 transactions** per state (California $500k; New York $500k *and* 100 transactions;
Illinois dropped its transaction threshold entirely in January 2026). At $3 a month the
revenue thresholds are far away, but **200 transactions is not**, and monthly billing
generates twelve times as many transactions per customer as annual does. That is a second,
independent argument for the cadence decision in §2.1. The home state is taxable from the
first sale regardless, and whether a self-hosted server license is a taxable digital good
there varies by state.

**"But this audience is mostly American" is true, and it does not help as much as it looks.**
The green-bubble problem that drives BlueBubbles adoption is disproportionately American, and
US iPhone share (~59%) is the highest of any large market. But the non-US remainder is not a
rounding error: Canada sits at 53–60%, Great Britain around 57%, and Japan around 69%. An
English-language Mac tool with a GitHub audience will plausibly run 20–35% non-US.

The problem is that **VAT liability is binary per jurisdiction, not proportional to revenue.**
One EU customer does not create 1% of an obligation: it creates the whole one: register for
non-Union OSS, charge the right national rate, file quarterly, forever. A mostly-American
customer base reduces the money at stake and changes the compliance work not at all.

So "no VAT" is only true if non-US customers are actively **refused**. That is a legitimate
option, and it is more expensive than the MoR fee. At $12/year, Stripe direct nets $11.35
against Lemon Squeezy's $10.66, so selling US-only beats a global MoR **only while non-US
customers are under roughly 5% of the potential base.** At a plausible 25% the comparison is
$8.51 against ~$10.75 per potential customer: the merchant of record is about 26% *ahead*,
because its fee is smaller than the revenue geo-blocking throws away.

The third path (sell worldwide through Stripe direct and simply not register) is
non-compliance rather than a strategy. Plenty of small sellers do it and enforcement at this
scale is unlikely; the exposure nonetheless accrues, is personal, and is exactly the kind of
thing that surfaces later at the worst moment. It is named here so the choice is made
deliberately rather than by default. **Recommended: sell globally through a merchant of
record.**

**And US-only would not mean tax-free anyway: Maryland in particular.** The home state is
taxable from the first sale, with no threshold to hide behind, and **Maryland taxes digital
products at 6%** for individual consumers: subscriptions, digital codes, apps and paid online
access are all explicitly in scope. Maryland additionally introduced a **3% tax on data and IT
services** (NAICS 518, 519, 5415, 5132) effective 1 July 2025, and repealed the customised
software exemption at the same time.

Which of those two rates a BlueBubbles subscription falls under is **not obvious**: a license
unlocking features in software the customer self-hosts could be read as a 6% digital product
sold to a consumer, or as 3% software-publishing/IT services. That ambiguity, on the seller's
own home state, from the first dollar, is a merchant of record earning its fee **before a
single international customer exists**. It is also a specific question worth putting to a
Maryland accountant.

**The mitigation that changes the arithmetic: price tax-exclusive.** Every MoR lets you choose
whether the displayed price includes tax. Tax-exclusive means a German customer is charged
$1 + 19% and your revenue is untouched; tax-inclusive means the VAT comes out of your dollar
and a $1 subscription nets about 83¢ before platform fees. **Decide this deliberately**: it
is a larger swing than the entire vendor comparison above.

So the 5% is buying registration, collection at ~50 different rates, filing, remittance and
liability across every jurisdiction a customer might live in. For one developer selling a $1
subscription internationally, that is cheap. Doing it yourself is not a fee you save; it is a
quarterly obligation you acquire.

**Which is why Stripe direct is not the bargain its 2.9% + 30¢ suggests.** It is not a
merchant of record. Stripe Tax will *calculate* the right rate for about 0.5% per transaction,
but you remain the registrant, you file the returns, and the liability is yours. **Stripe
Managed Payments** is the real comparison: Stripe's own MoR, built out of the Lemon Squeezy
acquisition, and at this price point it is genuinely competitive (§2.1), because its fixed fee
is 30¢ rather than 50¢. It is worth checking availability in the Stripe dashboard, since it is
rolling out primarily to US businesses in good standing.

**It does not change the §2.2 recommendation, though**, and for exactly the reason given
there: neither Stripe nor Stripe Managed Payments has native license keys. Choosing either
means building and operating the key store, the webhook receiver and the subscription
reconciliation that Lemon Squeezy's license API removes entirely. The fee is a rounding error
against that; the state is not.

> **A note on GitHub Sponsors, since the accounts look reusable and are not.** GitHub Sponsors
> pays out through a Stripe Connect **Express** account that GitHub controls: you cannot sign
> into it as an ordinary Stripe account or charge your own customers through it, and creating
> a normal Stripe account on the same email address fails outright. A subscription business
> needs its own separate Stripe account regardless of what Sponsors is already using.

> None of the above is tax advice, and the stakes are high enough to be worth an accountant's
> hour before the first sale; particularly on home-state taxability and on whether to price
> tax-inclusive.

### 2.4 Why not self-host licensing entirely and use a bare processor

A fair question, since §2.5 already puts a function of ours in the path: why not go further,
generate and store the keys ourselves, and take payment straight through Stripe or PayPal at
2.9% + 30¢ instead of a merchant of record's 5.95% + 50¢?

**The infrastructure objection is not the answer.** It really is negligible: an Oracle Cloud
Always Free instance, or a Worker with a D1 database, runs at $0–300 a year. That part of the
intuition is correct.

**The cost is that dropping the merchant of record makes us the merchant of record.** Every
obligation in §2.3 lands back on us: Maryland registration and filing from the first sale,
non-Union OSS for the EU, a separate UK registration, and the rest, forever.

At 1,000 subscribers billed annually the fee saving is:

| Tier | LS fees | Stripe fees | Saving | After tax |
|---|---|---|---|---|
| $2/mo | $1,928 | $1,104 | $824 | $508 |
| $3/mo | $2,642 | $1,506 | $1,136 | $701 |
| $5/mo | $4,070 | $2,310 | $1,760 | $1,086 |

And every way of discharging the obligation it creates costs more than the saving:

- **Geo-block to US-only.** Losing ~30% of subscribers costs about **$9,100 a year** at $3/mo
  : eight times the saving.
- **Buy compliance.** Stripe Tax calculates for ~0.5% per transaction but does not file or
  take liability; registration and filing services for a small seller run **$1,500–6,000 a
  year**, more than the saving on its own.
- **Do it yourself.** 20–40 hours a year of registrations and quarterly filings works out to
  roughly **$38/hour** at $3/mo, before the build, the support load, or the liability.

**Plus the §2.2 build, which does not go away:** key generation, storage, activation limits,
a webhook receiver with signature verification and idempotency, subscription lifecycle,
dunning for failed cards, refunds, a "I lost my key / I have a new Mac" portal, and
reconciliation for missed webhooks. Support for all of it arrives at our inbox rather than a
vendor's. PayPal is no better here and is worse on fees (3.49% + 49¢ standard); it solves no
part of the tax question either.

**Where it does flip, and it is not far away.** Against a ~$3,000/year tax service, on fees
alone:

| Tier | Saving per subscriber | Break-even |
|---|---|---|
| $2/mo | $0.82/yr | ~3,600 subscribers |
| $3/mo | $1.14/yr | ~2,600 subscribers |
| $5/mo | $1.76/yr | ~1,700 subscribers |

So this is a **revisit-later decision, not a never decision**: earlier than the "tens of
thousands" §2.2 guesses at. The trigger to reopen it is a few thousand paying subscribers,
and §1.6 means reopening it costs one file.

### 2.5 The signing endpoint

One serverless function (Cloudflare Worker, Vercel, whatever; it is roughly thirty lines)
sits between the server and the vendor:

```
BlueBubbles server                   our function                     the vendor
  POST /v1/entitlement       ->
    { license_key, machine_id,           validate key         ->
      server_version }                                        <-   status, expiry, variant
                             <-   Ed25519-signed token
```

It holds the vendor API key and our private key; neither ever leaves it. It maps a vendor
product/variant onto **our** tier vocabulary, and signs. That mapping living server-side is
what makes a repriced or renamed product a config change rather than a client release.

**The no-function fallback**, if running even that is unwanted: call the vendor's
validate endpoint directly from the Mac and cache the result. It works, and it costs three
things: a vendor API key shipped in a source-available app, a locally cached result with no
signature over it, and a wire format welded to one vendor. Take it only as a deliberate
trade; §4 onwards is unchanged either way, since everything downstream of `EntitlementToken`
is identical.

---

## 3. The entitlement token

Compact JWS-style (`base64url(header).base64url(claims).base64url(signature)`) verified
with `Curve25519.Signing.PublicKey.isValidSignature`, exactly as
`AppcastSigning.verify(_:signature:publicKey:)` does.

### 3.1 Claims

| Claim | Type | Meaning |
|---|---|---|
| `v` | int | Claim-format version. Present from the first token so a format change is not a flag day |
| `sub` | string | Opaque customer id from the vendor. **Never an email address**: it is stored on disk and appears in logs |
| `tier` | string | `pro`. The tier id, matching `SubscriptionTier.id` |
| `feats` | [string] | Feature ids granted beyond the tier floor. Empty in practice at first; exists so a one-off grant does not need a new tier |
| `machine` | string | SHA-256 of the hardware UUID. Binds the token to this Mac |
| `iat` / `exp` | int | Issued-at and expiry, epoch seconds. `exp` is short; see below |
| `sub_end` | int? | When the *subscription* period ends, as the vendor understands it. Distinct from `exp`, and this is what a user is shown |
| `jti` | string | Token id, for support and for de-duplicating a replayed refresh |

`exp` and `sub_end` being different is the load-bearing part. `exp` is a **refresh interval**
(≈ 7 days): it is short so that a cancellation stops working reasonably promptly. `sub_end` is
the **subscription's own end date**: it is what the UI shows and what the 402 body reports,
because "your token expired 3 days ago" is meaningless to a person while "your subscription
ended on 14 March" is actionable.

### 3.2 Lifetimes

**An unverifiable entitlement is not an entitlement.** If the license cannot be confirmed, the
gated features stop. There is no extended offline grace, and the reason that is an acceptable
choice here (where it would not be in most products) is §1.3: **base functionality is never
gated.** A server that cannot reach the license endpoint keeps sending and receiving messages,
keeps its notifications, keeps its socket, keeps everything it had before the subscription
existed. What it loses is the extras. That is a proportionate consequence, and it closes the
obvious bypass of simply never letting the server reach the network again.

| Window | Value | Behaviour |
|---|---|---|
| Refresh cadence | every 24 h, and on wake | Attempt a refresh. A single failure means nothing and is logged at debug |
| Token validity (`exp`) | 7 days | The operational margin, not a grace period. With daily refresh it takes **seven consecutive days of failure** to exhaust it |
| Warning | 3 and 5 days of failed refresh | A `UserAlert` naming the problem and what to check, **before** anything stops |
| Past `exp` | immediately | Gated routes refuse with `validation_unavailable` (§6): deliberately **not** `license_expired`, because we do not know that it expired |

The seven days are deliberate and are not generosity. They absorb the things that legitimately
interrupt a refresh without indicating anything about the subscription: a Mac asleep for a
weekend, a router rebooted, a transient failure at our endpoint, a DNS blip. Anything shorter
turns ordinary infrastructure noise into support tickets. Anything longer starts to be a
loophole rather than a margin.

Note what this does **not** need to accommodate: a genuinely offline BlueBubbles server barely
exists. The server already needs the network to reach clients through a tunnel and to talk to
Apple. If it cannot reach our license endpoint for a week, something is wrong that the operator
needs to know about anyway, which is what the day-3 and day-5 alerts are for.

**The cost of this choice, stated plainly: our uptime becomes our customers' uptime.** A
week-long outage of the signing endpoint would take paid features away from every subscriber.
That is an argument for the endpoint being trivially simple and boringly hosted (§2.5), and for
watching it, not for widening the window.

Every window above is a constant in one file, and every one of them is asserted by a test
driving `ManualClock` (`BBCore/Clock.swift:29`).

### 3.3 Machine binding and seats

`machine` is a hash of the hardware UUID, so a token lifted to another Mac fails verification.
Seat *counting* is the vendor's job (the activation limit on a license) not ours; the server
never sees how many other Macs exist. Re-activating on a rebuilt Mac is a support operation on
the vendor dashboard, and §12 has the open question about how much self-service that needs.

**One license key, many tokens.** The purchased artefact is the **key**; a token is what one
machine gets when it activates that key. So a customer with two Macs, or a Mac plus a guest VM,
activates the same key twice and each install holds its own machine-bound token. The vendor's
activation limit is therefore the real unit of "how much does this license cover", and it is
enforced where it cannot be patched out.

It also means a license can span more than one **reader**: nothing here assumes the server is
the only thing that verifies a token. No second application is planned; this is a property of
the model rather than a commitment:

- Every app verifies against the **same embedded public key**: no new crypto, no second trust
  anchor.
- `tier` and `feats` are read by whoever cares. A higher tier, or a feature id, can unlock a
  capability in a different application entirely; each app decides what the claims mean to it.
  There is deliberately **no audience claim**: a token says what was bought, not who may read
  it.
- Co-located apps share the cached token rather than each holding a copy. The token is signed,
  not secret (§8), so a shared file is adequate; only the **key** needs the Keychain. Refresh is
  idempotent, so whichever app is running may perform it.

Note the honest limit: `machine` is checked by code the user controls. It stops casual key
sharing between friends. It stops nothing else.

---

## 4. Module layout

Two new targets. The split is not gratuitous: `BBHTTPAPI`'s dependency list is deliberately
minimal and its `Package.swift` entry (line 342) records that it once declared six domain
modules it did not import, "dead edges that quietly permitted exactly what the header of
HTTPServer.swift says must not happen". The HTTP layer must be able to name a tier without
gaining a path to settings, persistence or the network.

### `BBLicense`: the vocabulary. Leaf.

Depends on `BBCore` only (for `BBClock`). No network, no storage, no settings.

```
SubscriptionTier        id, rank, display name; Comparable; Tier.all
EntitlementID           string-backed, like PermissionID
EntitlementToken        the parsed claims
LicenseStatus           .none | .active(Entitlement) | .expired(at:) | .revoked | .unverifiable(since:, reason:)
                        (no .grace case - past `exp` the status IS .unverifiable, and that refuses)
LicenseRefusal          the 402 reason enum (§6). Owns its wire string and its sentence
TokenVerifier           Ed25519 verification and claim decoding. Pure, synchronous, total
```

`BBHTTPAPI` gains a dependency on `BBLicense`, and nothing else changes in its graph.

### `BBLicensing`: the machinery.

Depends on `BBLicense`, `BBCore`, `BBSettings`, `BBDiagnostics`, `Crypto`, `Logging`.

```
LicenseStore            reads/writes the cached token; the only thing that touches storage
EntitlementClient       talks to the signing endpoint; one POST, typed result
LicenseEvaluator        cached token + clock -> LicenseStatus. Where every window in §3.2 lives
```

`LicenseEvaluator` is where the tests point. It takes a token and a `BBClock` and returns a
status; it does no I/O, so the whole of §3.2 is testable without a network or a sleep.

**On sharing Ed25519 helpers with `BBUpdates`:** `AppcastSigning.publicKey(fromBase64:)`
(line 64) is fifteen lines that `TokenVerifier` wants verbatim. Do **not** make `BBLicensing`
depend on `BBUpdates` to get them: that is a dependency from licensing onto the updater for a
base64 decode. Either duplicate the fifteen lines with a comment pointing at the original, or
lift them into `BBCore` and have both call it. Prefer the lift if it is the second copy;
prefer duplication if lifting drags `Crypto` into `BBCore` for one function. Decide when
writing it, and say which in the file header.

`python3 Tools/package-graph/check.py` must pass: it fails on a declared-but-unused
dependency as readily as on a missing one.

---

## 5. The gate

### 5.1 Declaring it on a route

A tier is a *value*, not a flag, so it does not go in the `RouteRequirements` OptionSet
(`RouteTable.swift:38`): an OptionSet cannot carry a payload, and a bit per tier collapses
the ordering that §1.2 exists to preserve.

New optional field on both `RouteDefinition` and `RouteGroup`, defaulting to `nil`:

```swift
public let minimumTier: SubscriptionTier?
```

Group and route combine the way requirements already do at `HTTPServer.swift:339`
(`group.requirements.union(route.requirements)`): here, the **higher** of the two wins, so a
group-level floor cannot be lowered by a route.

Declaring one then reads:

```swift
.init(.post, "call", .faceTimeStartCall, minimumTier: .pro)
```

**BUILT.** `Tests/CompatibilityTests/SubscriptionGateTests.swift` pins two things: the
permanent rule that no v1 group or route may ever carry a tier (§1.3), and the premium set as
an explicit list, so adding or removing a group from the paid tier requires editing that list
in the same commit where a reviewer can see it.

**The gated set**, decided 2026-09-16, narrowed 2026-09-18 — nine additive groups:

| Premium | Free, and why |
|---|---|
| `sendLater`, `appMessages`, `polls` | `auth` — how a client authenticates at all |
| `stickers`, `stickerLibrary` | `hydration` — a payload codec |
| `chatPinning`, `chatControls` | `alerts` — the server reporting its own health |
| `faceTime`, `faceTimeIncoming` | `contactAvatar`, `contactCard` — contact data |
| | `webhookEditing` — administration |
| | `findMy` — see below |

**Find My came out of the paid set on 2026-09-18, and the reason generalises.** v1 already
reads devices and friends, for nothing, and no v1 route may ever declare a tier. The additive
group is the same act done better — a status probe, a per-friend refresh where v1 could only
refresh them all, and a request to share so there is something to look at. A tier on that
charges for a finer-grained version of a free call, which reads as taking something away, and
the single "Find My" capability card spanning both halves said so in as many words: a premium
badge over a feature people already had. **A capability card is one claim about one feature.
If a card covers free and paid surface at once, the split is wrong, not the label.** The same
mistake shipped once already as a paid capability titled "Scheduled messages", which is this
server's own free feature.

`findMySharing` left the set for a different reason: it is `#if DEBUG` now and not in a
release build at all. It shares this Mac's own position — there is no call that sets a
location — so a server in somebody's house can share that house, permanently. That is not a
feature to sell; it is a way to publish the operator's home address. The helper contract keeps
the calls so it is a route declaration away if setting a location ever becomes possible.

### 5.2 The stage

`LicenseStage`, in `BBHTTPAPI/Middleware.swift`, beside `PrivateAPIStage` and shaped like it:
a `Sendable` struct over an async closure, resolved at call time rather than captured, for the
same reason its neighbour gives: the answer changes while the server runs.

```swift
public struct LicenseStage: Sendable {
  private let status: @Sendable () async -> LicenseStatus
  public func check(_ required: SubscriptionTier?) async throws { … }
}
```

`check` returns immediately when `required` is nil, which is every route on the day this
lands.

### 5.3 Where it sits in the chain

`HTTPServer.swift:339–360`, immediately **after** authentication and scope authorisation and
**before** `requirements.contains(.privateAPI)`:

```
admit (blocklist) -> authenticate -> authorize(scope) -> LICENSE -> privateAPI -> handler
```

Two orderings matter and both have a reason:

- **After authentication.** An unauthenticated prober learns nothing about what this server
  pays for. It gets a 401, exactly as it does for everything else. License state is not
  public information.
- **Before the Private API check.** A license problem is the more actionable of the two and
  is true regardless of whether a helper happens to be connected. A user who is both
  unlicensed and has no helper should be told about the license, because that is the one they
  can fix by deciding something.

### 5.4 The response

New error type, in `BBSerialization/WireTypes.swift:35`:

```swift
case paymentRequired = "Payment Required"
```

Adding a case to that public enum breaks exhaustive switches inside the module; the compiler
finds them all. It is safe with respect to the contract because it is only ever emitted by
routes that carry a tier, and no v1 route ever will (§1.3).

New `HTTPError` conformer in `BBHTTPAPI/HTTPErrors.swift`. It needs nothing special from the
renderer: `ErrorRenderer.render` (`Middleware.swift:247`) already returns any `HTTPError`'s
own status and envelope, `data` included.

```jsonc
{
  "status": 402,
  "message": "This feature requires a BlueBubbles subscription",
  "error": {
    "type": "Payment Required",
    "message": "Your subscription ended on 14 March 2026"
  },
  "data": {
    "reason": "license_expired",
    "required_tier": "pro",
    "current_tier": null,
    "subscription_ended_at": 1773446400000,
    "purchase_url": "https://bluebubbles.app/…"
  }
}
```

**There is no `manage_url`, and that is the decision rather than an omission.** Creem mints a
billing portal link per customer, from a customer id its license response does not carry, so
there is no URL a server could put here; and hard-coding the vendor's own domain is what §1.6
exists to avoid — a processor change would strand every installed server on a dead link. A
customer who needs to change a card or cancel does it from the receipt the vendor emailed
them. If a stable self-serve page is ever wanted, it is a page on our own domain that looks
the customer up and redirects, not a vendor URL compiled into a release.

Notes on the body, each of which is a decision:

- **`data` is snake_case**, per `docs/NAMING.md`: this is v2-only surface, so the v2 rule
  applies with no inherited-entity carve-out.
- **`message` is the sentence, `error.message` is the detail.** That is the envelope contract
  and getting it backwards is a bug this codebase has already had once
  (`HTTPErrors.swift:3–10`).
- **`error.message` differs per reason** and is written for a person to read in a client's
  error toast. It is generated from `LicenseRefusal`, which owns both the wire string and the
  sentence, so the two can never disagree.
- **Timestamps are epoch milliseconds**, matching every other date this API emits.
- **`current_tier` is null when unlicensed** and is the held tier when the refusal is
  `tier_insufficient`. It is what lets a client say "you have Pro, this needs Studio" without
  a second request.
- **No license key, no `sub`, no `jti`.** Nothing identifying goes on the wire; a client that
  can read a 402 is not necessarily the person who bought the license.

---

### 5.5 Gating a whole service, not a route

Some paid capabilities are not an endpoint. They are a **service**: a connection method, an
integration, a background capability that runs or does not. A registry service has no request
to refuse, so §5.1–5.4 do not reach it and it needs its own rules.

**The hook already exists.** `GatedService.canRun()` (`Service.swift:136`) is exactly this
question, and the registry already records `ServiceHealth.inactive(reason:)`
(`Service.swift:18`) when the answer is no, so a gated service that declines reports *why*
rather than looking broken. Connection methods already work this way: `ProxyService.canRun()`
(`ProxyService.swift:253`) answers "am I the selected method", and all but one decline.

#### The sharp edge, which is the whole reason this needs a section

**A connection method is how clients reach the server.** If a license lapses and `canRun()`
flips to false, the registry stops the service, the tunnel drops, `server_address` goes stale,
and **every client loses the server entirely.**

That is not a feature being refused. That is the product breaking, on a machine that is very
often headless and in a cupboard, for someone who may be travelling. It is the worst possible
violation of §1.4, and the naïve implementation causes it.

**So the rule: gate adoption, never continuation: for anything load-bearing.**

That means two questions per service rather than one:

| Question | When | License-aware? |
|---|---|---|
| May this start? | Before starting, and when a user selects it | **Yes** |
| Must a lapse stop it? | Per-service policy | **Only if stopping is safe** |

And services split accordingly:

| Kind | Stopping it means | On lapse |
|---|---|---|
| **Load-bearing**: clients cannot reach the server, or messages stop | a connection method, the HTTP service, push | **Keeps running.** Raise an alert, never stop; see the deadlock note below. Honour system, exactly as §0 accepts |
| **Additive**: nothing critical degrades | an optional integration, a background extra | Stops, reporting `.inactive(reason: "requires <tier>")` |

An unlicensed server that has never used the capability simply never starts it. A licensed
server whose subscription lapses keeps what it has and is told, loudly and repeatedly, that it
has lapsed. Given §0, that trade is not even close: the alternative is bricking someone's
messaging over a $3 renewal.

**This is the one carve-out to §1.4's fail-closed rule, and it exists to avoid a deadlock
rather than to be lenient.** The license is refreshed over the network. If a gated connection
method stopped whenever the license could not be confirmed, then a network problem would drop
the tunnel, and with the tunnel down, the server may be unable to reach the license endpoint
to recover, and the operator may be unable to reach the server to fix it. The failure would be
self-sustaining, on a headless machine, from anywhere but the same room. **A gated service that
sits on the path used to verify the license can never be gated on that verification
succeeding.** Everything else fails closed as §3.2 says.

#### Never auto-switch away from a gated connection method

If a gated method cannot start, the server must **not** silently fall back to another one.

Two reasons, and the first is a security argument rather than a usability one. **Connection
methods differ in exposure.** Falling back from a private, identity-gated tunnel to LAN, or to
a publicly addressable tunnel, changes who can reach this server, without the user asking for
that and without them being present to notice. An automatic downgrade that widens exposure is
a far worse outcome than being unreachable.

The correct behaviour is to keep the current method, refuse the change, and alert.

#### Selection is where the gate is actually felt

The failure mode to design out: someone picks a premium connection method, saves, restarts,
and the server is unreachable with nothing explaining why.

So a gated service must, per §1.7, be **visible before it bites**:

- It **appears** in the connection-method list rather than being hidden. A capability nobody
  can see is a capability nobody buys.
- It is **labelled** as requiring a tier, with the tier named.
- Selecting it without the entitlement is **refused at the moment of selection**, in the
  settings UI, with the same `LicenseRefusal` reason vocabulary as §6, not accepted and then
  silently ignored at next startup.

A gated method that manages a downloaded binary should also not fetch it for an unlicensed
server; the `ToolManager` resolution goes behind the same gate.

#### This is where the manifest field earns its place

`ServiceManifest` is frozen ("no new manifest fields for hypothetical plugin needs") but the
freeze has an explicit carve-out: **"a field a BUILT-IN service genuinely needs today is
fine"** (`ServiceManifest.swift:39`). A shipped, gated built-in service is precisely that case,
and it resolves the question §1.2 deliberately left open.

```swift
public let minimumTier: SubscriptionTier?   // nil = free, as every built-in ships today
```

On the manifest rather than in the service's code, for two reasons that matter. The manifest is
what the settings and permissions UI read **before anything runs**, which is what makes the
labelling above possible. And a third-party connection method will eventually need to express
the same thing: `ProxyServices` exists as manifest-described services precisely so a
third-party tunnel is expressible at all, and a tier it cannot declare is a tier it cannot have.

**No service is gated.** The field ships unused, and a test asserts that no built-in manifest
carries a tier: to be deleted by whoever gates the first service, in the same commit that
gates it. (Routes are a different story now -- `sendLater` carries `.pro`. Services remain
ungated.)

### 5.6 Metered features, and why they are a different mechanism

Everything above gates a **capability**: a tier either permits a thing or does not, and the
answer is a static, offline-verifiable claim in a token. Some future features are not that
shape: an AI-backed plugin, or a CRM-style credit system, where each use has a real marginal
cost to us and the question is not "may you" but "how much is left".

**These are a second mechanism, not an extension of the first.** Trying to express a balance
in the entitlement token would break every property §3 depends on: a token is static, cached,
and verified offline, and a balance is mutable, authoritative, and must never be spendable from
a cache. A server allowed to spend against a cached balance while offline can spend it twice.

#### The two mechanisms, and the line between them

| | Capability gate (§5.1–5.5) | Metering (this section) |
|---|---|---|
| Question | May this server use the feature? | How much is left? |
| Where it is answered | Locally, from the cached token | **Server-side, authoritatively, at the moment of use** |
| Offline | Works, within §3.2's margin | Impossible by construction |
| Enforceable? | No; see §0 | **Yes** |
| Failure | 402 `tier_insufficient` / `validation_unavailable` | 402 `insufficient_credits` |

Both may apply to one route: the tier gate decides whether the feature exists for this server
at all, and the balance decides whether this particular call proceeds. The tier check stays
where §5.3 puts it, in the request chain. **The balance check does not belong there**: it
belongs inside the operation, atomic with the work and with the decrement, because a check in
the middleware is a check that has already gone stale by the time the work runs.

#### Why this is the first genuinely enforceable thing in this plan

§0 is honest that a local gate is bypassable: the code is source-available, and deleting the
check is an afternoon's work. **That argument does not apply here.** Removing a metering check
from your own build gets you nothing, because the credits are not in the build: they are a
balance on our side of a network call that has to happen for the feature to work at all.

So a metered feature is the first thing described in this document where the free tier is *the
code*, not *the capability*. That is worth knowing when choosing what to build: it is the one
category where the honour system is replaced by arithmetic.

It also means §0's framing (that everything here runs on the user's own Mac and touches no
infrastructure of ours) stops being true the moment such a feature ships. That is not a
problem, but it is a change of posture that should be made deliberately: it brings uptime
obligations, per-use cost, abuse handling, and the tax and support consequences already
described in §2.3.

#### Prepaid or postpaid

Lemon Squeezy supports **postpaid metered billing**: usage is reported through their Usage
Records API and billed at the next renewal. It does not provide a prepaid balance object;
in either model **we do the counting**, and LS only invoices numbers we send it.

| | Prepaid credits | Postpaid metering |
|---|---|---|
| Bad debt | None | Ours |
| Surprise bills | Impossible | Possible, and they are how consumer goodwill dies |
| Needs a balance store | Yes | Yes, for enforcement; no, for billing |
| Fits | Consumer plugins | Business/CRM, where it is the norm |

**Prefer prepaid for anything sold to individuals.** A consumer who accidentally runs up a bill
on a messaging server they left running is a refund, a complaint, and a story. Postpaid is
appropriate where the buyer is a business that expects an invoice.

#### What this needs that does not exist yet

Recorded so it is not rediscovered later, **not** designed here:

- An authoritative balance store, per license, on our side. This is the state §2.4 says we do
  not have, and it changes that section's break-even; once we run a balance store,
  the argument for a stateless vendor integration weakens.
- **Idempotent decrements.** A retried request must not charge twice; every consuming call
  carries an idempotency key.
- A top-up path (a one-time LS product plus a webhook) or a usage-report path, and a balance
  view in the app.
- `insufficient_credits` as a `LicenseRefusal` case, with the remaining balance and a top-up
  URL in the 402 `data` payload, following §5.4.
- A decision about what happens mid-operation when a balance runs out, per feature.

**Nothing here is in scope for this plan.** It is a sketch of the second mechanism, written
down because the first mechanism's design would otherwise look like it was meant to carry
metering too, and it is not.

## 6. Telling the reasons apart

This is the part of the request that most needs to be right: the client must know whether the
user **never had** a license or **had one that lapsed**, because those are different sentences
and different buttons.

`LicenseRefusal`, in `BBLicense`, is the single source for all three columns:

| `reason` | Fires when | `error.message` reads | What a client should offer |
|---|---|---|---|
| `no_license` | No license key has ever been entered on this server | "This feature requires a BlueBubbles subscription" | **Subscribe** |
| `license_expired` | A token exists, its `sub_end` is in the past, and the vendor confirmed the subscription ended | "Your subscription ended on 14 March 2026" | **Renew**, with the date |
| `license_revoked` | The vendor reports the license disabled: refund, chargeback, manual revocation | "This license is no longer active. Please contact support" | **Contact support** |
| `tier_insufficient` | A valid license, but below the route's floor | "This feature requires the Studio plan. You have Pro" | **Upgrade** |
| `machine_mismatch` | Token verifies but `machine` is not this Mac: restored from a backup, or moved | "This license is activated on a different Mac" | **Re-activate here** |
| `validation_unavailable` | The token is past `exp` after seven days of failed refresh. We do **not** know the license is bad: only that it cannot be confirmed | "Your subscription could not be confirmed. Check this Mac's internet connection" | **Retry**, and say plainly it is probably not their fault |

The last row is the one that is easy to get wrong and expensive when wrong. A paying customer
whose Mac has been offline for a month must not be told their subscription expired. It has
not; we simply cannot see it. Distinguishing that from a genuine lapse is the entire reason
`sub_end` is a claim separate from `exp` (§3.1): with a token in hand we can say "ended on
the 14th"; with only a stale token we can say only "could not confirm".

**Reason strings are API.** Once a client branches on `no_license`, that spelling is frozen
like every other wire value in this codebase. They are snake_case, they never carry a
sentence, and a new one is additive only.

---

## 7. Discovery, so a client can avoid the 402 entirely

### 7.1 The endpoint

A new additive group, mounted unconditionally next to `AdditiveRoutes.alerts` in
`ServerComposition.routeGroups` and listed in `BBOpenAPI/RouteCatalog.swift` with
`availability: .always`. Additive groups mount unconditionally all over this table already:
`alerts`, `stickers`, `polls`, `chatControls`, and the parity test only constrains
`RouteTable.groups` (`RouteTableTests.swift:70`), so this costs nothing.

```
GET /api/v2/server/subscription     scope: .serverAdmin
```

```jsonc
{
  "tier": "pro",
  "status": "active",
  "subscription_ends_at": 1773446400000,
  "refresh_failing_since": null,
  "features": ["facetime.call_control"],
  "available_tiers": [
    { "id": "pro", "rank": 1, "name": "Pro", "purchase_url": "https://…" }
  ]
}
```

`available_tiers` is what makes one tier today and three tiers later a non-event for clients:
the list is data, and a client renders what it is given rather than hard-coding the tier it
knows about. `status` uses the same vocabulary as `LicenseStatus`.

**`server:admin` scope, and never the license key.** License state is administrative
information. The key itself is never readable back from any endpoint, ever.

### 7.2 In the app

`FeatureAvailability` (`BBCapabilities/FeatureListing.swift:21`) gains a case:

```swift
case needsSubscription(SubscriptionTier)
```

The features card then explains a locked feature exactly the way it already explains one that
needs the Private API, including the prominent call-to-action heading, which is already
implemented for that case. `FeatureListing`'s design, where the list's order, grouping and
cut-off are values rather than view logic, means the upsell screen arrives nearly free and
with the existing tests still covering it.

A license page in the app (`Sources/BlueBubblesApp/Views/`) does the rest: enter a key, see
status and renewal date, deactivate this Mac, open the vendor's management portal. Status
lives on a child model attached in `start` / detached in `stop`, per the CLAUDE.md rule for
state with its own lifetime.

### 7.3 `server/info` is not touched

Tempting and wrong. That response is diffed strictly in both directions by the parity harness
and an added key fails it (`CoreHandlers.swift:42`). Subscription state goes on the v2
endpoint above and nowhere else.

---

## 8. Settings and storage

| Key | Type | Secret | Application | Notes |
|---|---|---|---|---|
| `license_key` | String | **yes** | `.live` | Goes to the Keychain via `isSecret`, like `password` (`SettingsRegistry.swift:104`) and `ntfy_token`. Renders as `••••`. **Never loggable, never declarable by a service** |
| `license_token` | String | no | `.live` | The signed token. Not a secret: it is signed, not confidential, and it must be readable by the evaluator without a Keychain prompt |
| `license_last_check` | Int | no | `.live` | Epoch seconds of the last successful refresh. Drives the warning alerts and, with `exp`, the refusal |
| `license_endpoint` | String | no | `.composition` | Our signing function's URL. A setting so a self-hoster or a test can point it elsewhere; hidden, not rendered |

All four are `snake_case` per `docs/NAMING.md` and go in `Settings.hidden` rather than
`Settings.renderable`: they are surfaced by the license page in §7.2, not by the generated
settings form, because "paste your token here" is not a settings row.

`.live` rather than `.composition` for the first three, and that matters: entering a key must
take effect without restarting the server. Only the endpoint URL is composition-time.

Note the interaction with CLAUDE.md rule 9: `license_key` is a secret, so **no service may
declare a read of it**. `ManifestValidator` refuses a manifest naming one and `checkRead`
refuses it before entitlements are even consulted. The licensing service therefore asks the
host to perform the exchange rather than being handed the key: the same shape
`authenticateRequests` exists for (`ServiceManifest.swift:272`).

---

## 9. The refresh service

`LicenseService`, one file under `Composition/Services/`, registered in `ServerComposition`
like the rest, with its manifest in `BBBuiltIns/BuiltInManifests.swift`.

| Aspect | Decision |
|---|---|
| `GatedService.canRun()` | `false` when `license_key` is empty. An unlicensed server runs no licensing code at all, and the registry records `.inactive(reason:)` (`Service.swift:18`) so the health surface says why rather than "not started" |
| Dependencies | None. It must start whether or not the HTTP server, the proxy or the Private API came up |
| Cadence | Refresh on start, every 24 h, and on wake from sleep |
| Backoff | `RestartPolicy.backoff`, as `PrivateAPIGatedService` uses. A failing endpoint must not become a retry storm |
| Entitlements | `network(hosts:)` naming our endpoint's host and nothing else, plus `writeSettings` for the three non-secret keys. **Not** a read of `license_key`; see §8 |
| `apply(_:)` | `.restart` on `license_key` changing; `.none` on the keys it writes itself, or it restarts itself forever. The `HTTPService.liveKeys` pattern is the precedent, and the twenty-restarts-per-second bug it prevents is documented in CLAUDE.md |
| Alerts | A `UserAlert` through `BBDiagnostics` at **3 and 5 days** of failed refresh (before anything stops) and again when a subscription actually lapses. Severity `.warning`, `dedupeKey` `license.refresh`. The warnings are the whole reason failing closed is defensible: nobody should discover this by a feature vanishing. Logging must never raise one |
| Never | Blocks startup. Retries on the request path. Logs the key. Touches anything ungated |

The service's job is only to keep `license_token` fresh. Deciding what that token *means* is
`LicenseEvaluator`'s, and it is consulted synchronously from the stage.

---

## 10. Tests

| Test | Asserts |
|---|---|
| `RouteTableTests` (extended) | No group in `RouteTable.groups` carries a `minimumTier`: the v1 invariant of §1.3, permanent |
| `RouteTableTests` (extended, temporary) | No route anywhere carries a `minimumTier`. Deleted by whoever ships the first gate |
| `LicenseTierTests` | Ordering and comparison; `Tier.all` sorted by rank; a route floor satisfied by a higher tier and refused by a lower |
| `TokenVerifierTests` | A valid token verifies; a flipped byte fails; a token signed by another key fails; a truncated or non-base64 token fails without throwing anything untyped |
| `LicenseEvaluatorTests` | Every window in §3.2, driven by `ManualClock`: fresh; six days of failed refresh still entitled; **seven days refuses**; `sub_end` past; machine mismatch; clock jumped backwards. Explicitly: a single failed refresh changes nothing |
| `LicenseRefusalTests` | Every `LicenseStatus` maps to exactly one refusal reason, and every reason has a distinct sentence. **Expired and unverifiable are different reasons**: the §6 requirement, pinned |
| `LicenseStageTests` | `nil` tier passes regardless of status; a tiered route refuses with the right reason and a 402; the stage never performs I/O |
| `HTTPErrorTests` | The 402 envelope: status, `message` vs `error.message` order, snake_case `data` keys, no key or `sub` present |
| `ServiceGateTests` | A manifest with a tier declines when unlicensed and runs when licensed; a **load-bearing** service already running is NOT stopped by a lapse (§5.5): the failure that would strand a headless server; a gated method is never auto-switched away from |
| `BuiltInManifestTests` | No built-in manifest carries a `minimumTier`. Deleted by whoever gates the first service |
| `CompositionTests` | The service is registered and `canRun` is false with no key: "a module is not done until the composition root calls it and a test asserts that call exists" |
| `NamingConventionTests` | Picks up the new settings keys and reason strings automatically |
| `bb-openapi emit --check` | Regenerated after the new group lands. Infer schemas first, then emit |

The evaluator tests are the ones that matter. Everything expensive about getting this wrong:
refusing a paying customer, or telling someone their subscription expired when their Wi-Fi
died, is a wrong answer from that one pure function, and it can be tested exhaustively
without a network, a sleep, or a vendor account.

---

## 11. Phases

Each phase builds, passes, and ships on its own.

**Phase 1: vocabulary.** `BBLicense` and its tests. No dependencies on it yet. Pure types, a
verifier, an evaluator, and the full §3.2 clock matrix. Nothing else in the repository
changes.

**Phase 2: the gate, dormant.** `RouteDefinition.minimumTier`, `ServiceManifest.minimumTier`
and the service-gate policy from §5.5, `LicenseStage`, the 402 error and its envelope, the
`paymentRequired` error type, the chain wiring at `HTTPServer.swift`.
The stage is constructed with a closure that always answers `.none`. Both `RouteTableTests`
assertions from §10 pass. **A build here behaves identically to today's**, and that is
checkable: no route carries a tier, so the stage returns before it looks at anything.

**Phase 3: the vendor and the storage. DONE in the server; the issuer is outstanding.**

Built: `BBLicensing` (`MachineFingerprint`, `LicenseStore`, `EntitlementClient`,
`LicenseRuntime`), five settings, `LicenseService` with its manifest, and the runtime threaded
through `SharedServices` -> `AppContext` -> `HTTPService`.

**Enforcement is switched by `LicensePublicKey.isConfigured`.** A build with no trust anchor
cannot evaluate a license, so it composes `.unenforced` and gates nothing: enforcing would
answer 402 to every caller of a gated route with no possible remedy. Dropping a key into
`LicensePublicKey.base64` is what turns the gate on, and nothing else changes when it does.

Three shapes the plan did not anticipate, each forced by a rule already in the codebase:

- **The service never holds the license key.** `license_key` is a secret, and
  `ManifestValidator` refuses a manifest that names one. So the composition root builds
  `LicenseRuntime` (which owns the key) and the service is handed that: it can ask whether a
  key exists and ask for an exchange, and there is no method that returns the key.
- **Watching is not reading.** The service still declares `license_key` in `watchedSettings`,
  so entering one restarts it and `canRun` re-evaluates without a server restart.
  `HTTPService` watches `password` on exactly the same footing.
- **Revocation is checked before the token**, not after. A license can be revoked before this
  machine ever caches a token, when someone enters a key that was already refunded, and the
  original order reported that as `no_license` - pointing the user at the subscribe button
  instead of at support. §3.2's order is corrected accordingly.

**Outstanding, and not the server's to do:** generate the Ed25519 keypair, stand up the issuing
function, and create the vendor product. The private half must never exist in this repository.

**Phase 4: discovery. The endpoint and the features card are DONE; the license page is not.**

Built: `GET /api/v2/server/subscription` (free surface, `server:admin`, mounted
unconditionally), `SubscriptionReport` in `BBInterfaces`, a recorded fixture, and the
regenerated OpenAPI document.

`FeatureAvailability` gained `needsSubscription(SubscriptionTier)` as the plan said, but the
mapping needed a step the plan skipped. A `PrivateAPICapability` is not a route group, and most
of the catalog is free v1 surface — marking the card from the route table alone would have
claimed a subscription for `replies` and `tapbacks`. So a capability now declares its own
`minimumTier`, eleven of the twenty-three carry one, and `SubscriptionCatalogTests` fails if the
catalog and the route table disagree in either direction. Availability resolves helper first,
tier second: offering to sell a feature to someone whose Private API is not set up sells them
something that would still not work.

Two things the plan did not say:

- **The hand-written response declaration had to be deleted once the fixture existed.**
  `ResponseBodyTests` forbids a route having both, and it is right: a recorded response is
  evidence and a declaration is a claim.
- **`server:admin` but never gated.** Gating the endpoint that explains the gate would be a
  closed loop — an unlicensed server could not discover that it is unlicensed.

**The license page is built**: a `Subscription` tab in Settings, with a status card, the key
field, and what the tier covers drawn from the capability catalog rather than a list typed into
the view. `SubscriptionAccess` is a fourth facade group (not a flat member on `AppModel`, per
that file's rule), and it exposes status, refresh and remove — there is no way to read the key
back through it, because nothing anywhere returns one.

`SubscriptionPolicy` holds every sentence, off the view, because the distinction the whole
design preserves is a wording decision: `SubscriptionPolicyTests` asserts that an ENDED
subscription and one that merely could not be CONFIRMED say different things, and that the
second never contains "ended", "expired" or "lapsed". Telling a customer whose router has been
down for a week that their subscription expired is telling them something false about their own
money, and both sentences read reasonably in isolation.

Three smaller decisions worth recording:

- **Entering a key exchanges it immediately** rather than waiting for the daily timer, which
  would otherwise leave somebody watching the page say "no subscription" for up to a day with
  no way to tell whether it worked. A person pressing a button is not a poll.
- **The status is read through `ScreenModel`, keyed on the server phase.** No stream and no
  timer: this value moves on the daily refresh or when somebody on the page acts, and both
  re-read explicitly. A lapse nobody is watching reaches them through the alert centre, where
  `LicenseService` already puts it.
- **The tab declares itself bespoke.** All five license settings are hidden, so the registry
  draws nothing on it, and `AlertActionWiringTests` requires that to be stated rather than
  discovered.

**Phase 4 is complete.** What remains before any of this does anything is Phase 3's outstanding
half: the keypair, the issuing function and the vendor product.

**Phase 5: the first gate.** A separate decision, on a separate branch, on new surface only.
Go through the `add-api-route` skill, not from memory. Delete the temporary
`RouteTableTests` assertion in the same commit that adds the first `minimumTier`, so the
deletion is reviewable as part of the decision rather than as housekeeping.

---

## 12. Open questions

Listed rather than answered, because each is a product decision rather than an engineering
one, and none of them blocks phases 1–4.

1. **What the first gated feature actually is.** This plan deliberately does not choose. The
   only constraint it imposes is §1.3's: new surface, never anything a shipped client already
   calls.
2. **Monthly, annual, or a one-off purchase.** §2.1: the fixed per-transaction fee against
   a $1–2 charge is the reason this is not just a pricing preference. Decide before the first
   sale; the token format supports all three unchanged.
3. **Household multi-Mac.** Two Macs in one house running two servers is a real BlueBubbles
   configuration. Does one subscription cover it? The vendor's activation limit is the
   mechanism; the number is a pricing decision.
4. **What happens to work in flight when a license lapses.** A gated FaceTime call already
   connected, a scheduled send already queued. The stage refuses *new requests* and says
   nothing about existing state, which is the right default, but each gated feature will
   have to answer it for itself when it is gated.
5. **Manual activation for an air-gapped server.** A signed token pasted into the app, with no
   endpoint call. The token format already supports it; the UI and the support process do not.
6. **Refunds and chargebacks.** `license_revoked` exists in §6 and nothing produces it yet.
   The vendor webhook that would is part of the signing function's scope, not the server's.
7. **Whether the existing PolyForm commercial-license path and this consumer subscription
   should ever meet.** `COMMERCIAL.md` sells to companies over a size threshold; this sells to
   individuals. They are different products with different contracts, and conflating them
   would be a mistake, but a company that has bought a commercial license will reasonably
   expect the paid features to be on. Deferred, and worth deciding before the first gate.
8. **Metered features: prepaid or postpaid, and whether to take on the infrastructure at all.**
   §5.6 sketches the mechanism. The decision that matters is not technical: shipping anything
   metered changes this from software that runs entirely on the user's Mac into a service with
   uptime obligations and per-use cost. Worth deciding on purpose rather than arriving at.
9. ~~**Identifier spelling.**~~ **RESOLVED: British, throughout.** The codebase's own usage
   settled it — `behaviour` outnumbers `behavior` 70 to 8, and `cancelled` and `colour` are
   used consistently. So `License*` for types and `license_*` for wire values and settings
   keys, including the refusal reasons in §6 (`no_license`, `license_expired`,
   `license_revoked`). Those strings are API from the moment a client reads one.

---

## 13. What to update when this lands

Per the standing rule that the docs move with the architecture:

- **`CLAUDE.md`**: a row in the "Where to go" table pointing here, and a row in "Where do I
  add…?" for a gated route. If §1.3's invariant is worth promoting, it belongs in the
  numbered rules; it is a client-compatibility rule, which is rule 1's territory.
- **`.claude/docs/api.md`**: the 402, the reason table from §6, and the discovery endpoint.
  This is the document a client author reads.
- **`.claude/docs/decisions.md`**: §1's seven decisions, particularly §1.1 (why not a feature
  flag) and §1.6 (why our own key rather than the vendor's API). Both are the kind of decision
  someone will otherwise try to "simplify" later.
- **`.claude/docs/architecture.md`**: the two new modules and where they sit in the graph,
  plus the service gate and its adoption-not-continuation rule (§5.5), which belongs next to
  the existing `GatedService` description.
- **`docs/AUTH.md`**: one line distinguishing authentication (who you are), scope (what you
  may do) and entitlement (what this server has paid for). Three different questions, three
  different stages in the same chain, and they will be confused otherwise.
- **`TODO.md`**: the phases, while they are outstanding. Finished work is deleted, not struck
  through.

---

## 14. A possible future: the self-hosted organisation tier

**Not planned, not scheduled, and not in scope for anything above.** This section records the
reasoning from an exploration of a second product built on the same license machinery, so it is
not re-derived later. Several parts are settled; several are open; two are **untested
assumptions** and are marked as such.

Nothing in §1–§13 depends on this. If it never happens, nothing above changes.

### 14.1 The shape

A tier aimed at a small organisation: a team inbox served by the BlueBubbles application
itself, with accounts for employees, all self-hosted.

**One application, not two.** The web UI for message threads, contacts and customers is part of
the existing app, and the org/user/inbox state lives in `app.db` alongside everything else. VM
provisioning (§14.7) is an *administrative feature of that same app* (convenience for an admin
who wants a second number without a second Mac) not a separate product. There is no separate
orchestrator to build, install, license or support.

**Everything stays on the customer's Mac.** There is **no cloud control plane**, no backend
service of ours holding customer data, and no message content on our infrastructure at any
point.

That was a deliberate choice over the alternative (an agent registering with a hosted backend
that brokers identity and discovery). Reasons, in order:

- **It is consistent with what the product already is.** "You own the Mac, you own the data" is
  the existing story, and a control plane would be the one place it stopped being true.
- **The compliance burden approaches zero.** SOC 2 and HIPAA obligations attach to operating a
  service that handles customer data. A vendor shipping software that never sees that data has
  a fundamentally different posture. This is also a genuine differentiator to sell on, not only
  a cost saving.
- **It is a far smaller build.** No backend, no multi-tenancy: each install is one
  organisation by construction.

### 14.2 Licensing an organisation: the enforcement is legal, not technical

With no backend, **nothing is technically enforceable**: §5.6's argument in reverse. Worse
than the consumer case: the party deciding whether to bypass the check has engineers and a much
larger financial incentive.

**That is acceptable, because for organisations the contract is the enforcement.** A company
over the PolyForm threshold needs a commercial agreement whether or not it defeats a technical
gate, and unlike an individual, a company cannot casually run on patched-out license
enforcement: procurement, legal review and audit make the exposure asymmetric and visible.
`LICENSE.md` and `COMMERCIAL.md` already establish this; the code check is a courtesy on top.

**So the organisation license is a different shape from the consumer one:**

| | Consumer (§3) | Organisation |
|---|---|---|
| Form | Short-lived token, refreshed daily | **Signed license file, annual expiry** |
| Network required | Yes; fails closed after 7 days (§3.2) | **None. Verified entirely offline** |
| Claims | Tier | Tier, seat or line count, organisation name, expiry |
| Purchased | Self-serve checkout | Invoice or agreement |

Both are the same Ed25519 format from §3. The organisation variant is a long `exp`, extra
claims, and no refresh loop, which is what makes "no backend" literally true for these
customers.

### 14.3 Pricing: per line, annual, flat

**Utilisation cannot be measured without telemetry we have chosen not to collect, and it does
not need to be.** Self-hosted business software is conventionally licensed per instance or per
seat on contract with audit rights, not metered.

One server is one Apple ID is one number, so **the natural unit is per server per year, flat**.
Seats within a server are best left unlimited: the number of people sharing one phone number is
naturally small, counting them adds enforcement that cannot be verified, and "unlimited users,
priced per line" is a simpler proposition than seat arithmetic.

### 14.4 What already exists, and what does not

More of the authorisation model is built than is obvious:

- **`Scope` exists** (`AuthenticationScheme.swift:23`) with five values, and **every route
  already declares the scope it needs**. It is inert only because `auth_mode` defaults to
  `password`, where the principal holds every scope.
- **Token auth exists**: `TokenAuthService`, `DeviceRegistry`, `Enrollment` with codes,
  scrypt-hashed client secrets, and per-principal revocation. The header at
  `AuthenticationScheme.swift:39` states its purpose as fixing "a leaked password today can
  only be revoked by changing it for everyone", which *is* the multi-user requirement.

Missing:

- **Principals are devices, not people.** An employee is one identity with several devices.
- **No organisation or tenant concept** anywhere in the server.
- **Enrolment is local**: a code shown in the server's own UI, rather than an admin inviting
  someone.
- **No roles above scopes.** Roles would map onto scope sets; the mapping does not exist.

### 14.5 The web UI is the security-sensitive part

Current auth is a query-string password or bearer tokens, designed for API clients. A browser
needs sessions, cookies, CSRF protection and CSP: new surface, and the kind where mistakes are
expensive.

**HTTPS becomes load-bearing.** The self-signed certificates this server can generate are
rejected outright by browsers, so a usable web UI effectively requires a tunnel presenting a
real certificate, which makes the connection method a dependency of the product and puts
§5.5's rules squarely in the path.

### 14.6 The ceiling, and the two ways around it

**One server is one Apple ID is one number.** That caps this at organisations sharing a single
line. Two approaches were considered:

**Multiple user accounts on one Mac.** Each macOS account can hold its own Apple ID. The
blocker is that **macOS permits only one auto-login user**, and Messages requires a GUI session,
so a `LaunchDaemon` does not help and every additional account needs manual login after a
restart. No evidence was found that macOS 26 changes this.

> **Relevant to every BlueBubbles server, not only this tier:** macOS 26 enables **FileVault by
> default on upgrade**, and FileVault and auto-login are **mutually exclusive**. A server that
> relied on auto-login to recover from a restart will silently stop doing so after the upgrade.
> This is worth a startup check and a documentation note independently of anything here.

**A VM per number.** Each guest has its own user session, its own Apple ID and **its own
auto-login**, which sidesteps the limit entirely.

| Fact | Status |
|---|---|
| macOS VMs support iCloud sign-in, host and guest both macOS 15+ | Documented by Apple |
| SIP can be disabled in a guest | **MEASURED** on this setup |
| **Messages/iMessage signs in and works in a guest** | **UNTESTED: assumed, not verified** |
| **The Private API injects and works in a guest** | **UNTESTED** |
| Apple's SLA permits two additional macOS VMs per host | License limit, not technical |
| Each guest wants roughly 4–8 GB RAM | Practical limit: 2–3 numbers per Mac |

**The two untested rows gate everything else in this subsection.** If Messages or the Private
API does not work in a guest, the VM approach is void and additional Macs are the answer: at
roughly $600 each, which is a serious competitor to any amount of engineering here.

### 14.7 VM provisioning, if the VM approach survives testing

An administrative feature of the app described in §14.1, not a separate product: an admin who
wants a second number adds a guest from the same web UI they manage threads in.

One binary, two roles. A guest runs **the same build** as a managed messaging node (driving
Messages.app for its own Apple ID) while the host additionally serves the web UI and owns
provisioning. That is cheaper than a second product in every dimension that matters: one
codebase, one release, one license, one support surface.

`Virtualization.framework` is the substrate (`VZMacOSRestoreImage`, `VZMacOSInstaller`,
`VZVirtualMachine`, virtiofs shared folders). Existing open-source VM apps are useful reference
implementations rather than dependencies.

**What automates and what does not:**

| Step | Automatable |
|---|---|
| Fetch installer, create VM, install macOS | Yes |
| Shared folders, installing and updating the server in the guest | Yes |
| Start, stop, monitor, aggregate guest health to the host | Yes |
| **macOS Setup Assistant** | **No**: no automation hook |
| **Apple Account sign-in** | **No**: interactive and 2FA-gated |
| **Disabling SIP in the guest** | **No**: needs recovery-mode interaction |

So the realistic product is a **guided wizard**, not an unattended provisioner: a human does
three steps once per number and the tool automates everything either side.

**Golden-image cloning has an unresolved problem.** Cloning a configured VM is the usual answer
to Setup Assistant, but each VM carries a `VZMacMachineIdentifier` that is its hardware
identity, and **iMessage registration binds to hardware identity**. Reusing the identifier gives
two guests with identical hardware IDs; generating a fresh one may invalidate the registration
baked into the image. Unresolved, and it needs testing before any cloning design.

### 14.8 Remote console for guest setup

Since three setup steps need a human at a display, the question of reaching that display
remotely was raised.

- **Supported path:** `VZVirtualMachineView`, an AppKit view that renders the guest and forwards
  input. There is no public framebuffer API.
- **Streaming it to a browser is tractable: roughly one to two weeks**, not a research
  problem. Capture the app's own window with **ScreenCaptureKit**, which handles
  hardware-accelerated content reliably; send JPEG frames over a WebSocket (Setup Assistant is
  near-static, so 5–10 fps suffices); map click coordinates by simple ratio against the guest's
  display size; and inject input by constructing `NSEvent`s and calling the view's responder
  methods directly, which is more controllable than posting `CGEvent`s and needs no Accessibility
  permission. The bulk of the work is a browser-keycode-to-macOS-virtual-keycode table.
  - **Not** `cacheDisplay(in:to:)` or `CALayer.render(in:)`: those frequently return blank for
    Metal-backed layers, which is the failure this note originally described.
  - Known rough edges: sticky modifier state across events, keyboard-layout mismatch between
    browser and guest (harmless when typing an Apple ID, not when typing a password with
    punctuation), and the Screen Recording TCC prompt SCK requires.
- **Once a guest is networked**, macOS Screen Sharing plus a browser VNC client is
  straightforward. It does not help for first boot, which is exactly when it is needed.
- **Cheapest answer, and the one to start with:** render the guest natively in the app's own
  window and let an administrator reach the *host* over Screen Sharing. Zero custom streaming
  code, and headless hosts are reached that way already.
- **But the case for the in-browser console is stronger here than it would be standalone.** The
  admin is already in a web UI managing threads and contacts (§14.1); sending them out to
  install a VNC client mid-setup is a jarring break in an otherwise contained flow. The two
  weeks buys a coherent product rather than a convenience. Still queued behind §14.6's untested
  facts, but it is no longer only an onboarding-volume argument.

A browser-delivered console is remote desktop over the internet and should be treated as such:
it belongs behind the same authentication as everything else and is not a casual feature.

### 14.9 One license across a host and its guests

There is one application (§14.1), so there is no cross-product licensing problem, but a
deployment still spans several *machines*, and §3.3's machine binding has to account for it.

**The host holds the license; guests are vouched for by the host.** Rather than each guest
activating separately against the vendor and consuming an activation, the host activates once
and the token carries the number of lines the license covers. The host enforces that count
locally when provisioning guests.

Two reasons this beats one-activation-per-guest:

- **It matches what the customer thinks they bought.** They bought "three lines", not "four
  machine activations", and a naïve count would charge them for the host as well as the guests
  even when the host serves no number of its own.
- **The trust boundary already exists.** The host *created* the guests. Nothing is gained by
  making a guest prove entitlement to a vendor the host could vouch to anyway, and it avoids
  guests needing network access to our endpoint at all.

The consumer case is unchanged: one Mac, one activation, `machine`-bound exactly as §3.3
describes. Only a multi-line deployment uses the line count.

**§3.2's fail-closed rule needs §5.5's carve-out.** If the license cannot be verified, the app
must **stop permitting new provisioning** and must **not stop guests that are already running**.
Same load-bearing reasoning: otherwise a network problem takes working messaging servers offline.

### 14.10 Open questions

1. Whether to do this at all. It is a different product with a different sales motion, and it
   competes for time with everything in §11.
2. The two untested VM facts in §14.6, which are cheap to settle and gate §14.7 and §14.8
   entirely.
3. The machine-identity problem in §14.7.
4. Whether a team inbox (assignment, per-user read state, internal notes, canned replies) is
   a product worth building. It is the actual substance here and none of it is messaging work.
5. How a single Apple ID attributes messages to individual employees. Attribution can only be
   internal metadata; the recipient sees one identity.
6. Support and versioning. Self-hosted business software fragments across versions and cannot
   be hot-fixed, which is a materially different support model.
7. Whether VM provisioning is part of the paid tier or available to everyone. It is a feature
   of one app now, so this is purely a pricing decision, and giving it away may convert better,
   since each guest it creates is a line that needs licensing.
