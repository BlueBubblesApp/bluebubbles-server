# License issuer

Exchanges a Creem license key for a signed entitlement token. The only thing in the system
that knows there is a vendor: the server verifies an Ed25519 token against a key compiled into
it, so changing payment processor is a rewrite of `worker.js` rather than a server release
every user has to install.

That is not theoretical. This spoke to Lemon Squeezy until they declined the store
application; the switch to Creem was this one file, and no shipped server would have noticed.
The Lemon Squeezy version is at commit `55ac72a0` if it is ever wanted back.

Runs on Cloudflare Workers' free tier. No database beyond a small KV namespace, and no
customer data: everything worth knowing is Creem's.

## Why it exists at all

Creem's license endpoints require an `x-api-key`, and that is an **account** credential rather
than a license-scoped one. Shipping it inside a Mac app anybody can unzip would hand every user
a credential against the store. So the Worker is structurally required here, and two further
reasons stand on their own:

- A direct integration would have to cache the vendor's plain JSON to honour the offline window
  (§3.2 of `swift/docs/SUBSCRIPTION_PLAN.md`). That cache is an editable text file: change a
  date and you have a permanent license. A signed token can be cached and still not forged.
- The product → tier/lifetime map is configuration here, so repricing or adding a tier is an
  edit and a redeploy with nothing for a user to install.

Under Lemon Squeezy the first reason was false — its license API needed no authentication — and
`worker.js` recorded that, so the claim would not be repeated without being checked. Under
Creem it is true.

## What it speaks

The contract is `EntitlementClient` on the server side.

**Request** — `POST /`

```json
{ "key": "…", "machine_id": "<64 hex chars>", "server_version": "1.2.3" }
```

**Response** — `200`

```json
{ "token": "<compact JWS>", "revoked": false }
```

A refused request answers a non-2xx with `{"reason": "…"}`. That reason reaches a log, never a
person: the sentence a customer reads comes from `LicenseRefusal` on the Mac, and the wire
values a client branches on are documented in `docs/api/openapi.json` under
`SubscriptionRefusal`.

## Setting it up

**1. The keypair — generate it once, and never again.**

```bash
node keygen.mjs --selftest
```

The PUBLIC half goes into `LicensePublicKey.base64` in
`Sources/BBLicense/TokenVerifier.swift`. **That constant being empty is what keeps the
subscription gate switched off**, so this is the step that turns enforcement on.

The PRIVATE half never goes in this repository, a commit, or a chat.

**Changing payment processor is not a reason to regenerate it.** The public half is compiled
into every shipped server, so a new keypair strands every license until each user updates — the
same damage as a leak, self-inflicted. The keypair outlives the vendor.

**2. Fill in the product map** in `worker.js`. The ids come from the Creem dashboard. An
unmapped product still issues a token on the fallback tier and logs the mismatch: refusing a
paying customer because a product was added at 2am is the worse failure.

**3. Create the KV namespace and paste its id into `wrangler.toml`.**

```bash
npx wrangler kv namespace create ACTIVATIONS
```

**4. Deploy, then load both secrets.**

```bash
npx wrangler deploy
npx wrangler secret put SIGNING_KEY      # the PRIVATE half from step 1
npx wrangler secret put CREEM_API_KEY    # from the Creem dashboard
```

`CREEM_API_BASE` is a plain var in `wrangler.toml`, not a secret. Leave it on
`https://test-api.creem.io` until real money is meant to move.

**5. Point the server at it.**

```bash
swift run bluebubbles-server --set license_endpoint=https://<your-worker>/
```

`license_endpoint` is composition-time, so it applies on the next start. Its compiled default
is the `workers.dev` hostname above, which is what a shipped server reaches unless an operator
changes it — and it is also what `BuiltInManifests.license` declares as the one host this
service may contact, so the two move together.

A vanity hostname such as `license.bluebubbles.app` would read better and would survive a
change of Worker, but a Workers custom domain needs the zone on Cloudflare and
`bluebubbles.app` is on Namecheap. Until that zone moves, `workers.dev` is the honest default.
Worth knowing before shipping: `workers.dev` is blocked on some corporate networks and in a
few countries, and a server that cannot reach the issuer fails premium features closed.

## Checking it before real money touches it

Do all of this against `https://test-api.creem.io` with a test license key.

```bash
curl -s https://<your-worker>/ \
  -H 'Content-Type: application/json' \
  -d '{"key":"<test key>","machine_id":"'"$(printf test | shasum -a 256 | cut -d' ' -f1)"'","server_version":"test"}'
```

A good response carries a three-segment token. Decode the middle segment and check `tier`,
`rank`, `exp`, and that `perp` is present **only** on the lifetime product — getting that
backwards is the mistake worth catching here rather than in support.

**The cross-language check is already automated.** `selftest.mjs` mints a token through the same
path the Worker uses — including the PKCS8 re-wrap of the raw seed — and
`Tests/BBLicenseTests/WorkerCompatibilityTests.swift` verifies it with the real `TokenVerifier`.
The two sides agree on base64url-without-padding, on the signature covering `header.claims`
rather than the whole token, on raw 32-byte keys rather than DER, and on the claim spellings.
Every one of those is silent when wrong. Regenerate the fixture with:

```bash
node selftest.mjs
```

and paste the three values into that test. It is unaffected by a vendor change: the token
format is ours.

## Things that will bite

- **Activation is a PREREQUISITE of validation, not bookkeeping.** `validate` requires an
  `instance_id` that only exists once the machine has been activated. Under Lemon Squeezy
  activation ran after the response and a failure cost nothing; here a customer who has spent
  every activation slot cannot be validated at all. Set a generous activation limit.
- **A refused activation reads as "could not confirm".** `EntitlementClient` turns any non-2xx
  into a thrown failure, so somebody at their device limit is told the subscription could not be
  confirmed rather than why. Safe direction, inaccurate sentence; fixing it properly means a new
  `LicenseRefusal` case and a wire reason.
- **KV is load-bearing, not a cache.** No call asks "which instance belongs to this machine", so
  the entry is the only record. The write is awaited rather than deferred for that reason, and a
  404 from validate clears the entry and re-activates ONCE — without that, an instance deleted
  in the dashboard would 404 forever.
- **`expires_at` is null for a subscription, not only for a lifetime purchase.** Inferring
  "perpetual" from a missing date told every healthy monthly subscriber they had bought the
  software outright. The product map is the only thing that knows; the `perp` claim is stated.
  Lemon Squeezy had the identical trap, which is why it is called out twice.
- **`disabled` is the only durable refusal.** `expired` still mints a token carrying the end
  date, because that is what lets the app say "ended on 14 March" instead of "could not confirm".
- **The API key needs `Licenses` read AND write, and nothing else.** The two calls this makes
  are `/v1/licenses/activate` and `/v1/licenses/validate`; `Products: read` is worth ticking
  as well, because `product_id` off the license response is what selects the tier and the
  90-day lifetime window, and a fallback tier is a silent wrong answer. Never `Full access`,
  whose "current and future" clause widens the key every time Creem ships a resource.
- **An under-scoped key reads as a dead license unless it is caught.** Creem answers 403 with
  "Invalid API key or insufficient permissions", which is the same status an exhausted
  activation limit is believed to use. `call()` sniffs the body for the credential wording and
  reports that case as ours; everything else stays a refusal. If customers start being told
  their subscription cannot be confirmed, check the key's permissions before the licenses.
- **The activation-limit error body is undocumented.** Creem's docs do not say what it returns,
  so `call()` collapses unrecognised failures to a refusal rather than guessing. Exhaust a test
  license deliberately and write down what actually comes back.
