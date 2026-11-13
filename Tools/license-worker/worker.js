//  BlueBubbles license issuer — Creem
//  Exchanges a Creem license key for a signed entitlement token.
//
//  This is the ONLY thing in the system that knows there is a vendor. The server posts
//  `{key, machine_id}` and reads back `{token, revoked}`, and the Mac verifies an Ed25519
//  token against a key compiled into it. Nothing in the Swift tree has heard of Creem, which
//  is the whole point of §1.6 of swift/docs/SUBSCRIPTION_PLAN.md — and is why Lemon Squeezy
//  declining the store application cost one file rather than a release every user has to
//  install. The Lemon Squeezy version of this file is at 55ac72a0 if it is ever wanted back.
//
//  WHY THIS EXISTS, restated, because the answer CHANGED with the vendor.
//
//  Under Lemon Squeezy the license API needed no authentication, so "the vendor key must not
//  ship" was not a reason for a Worker, and `worker.js` records that it was wrong to give as
//  one. Creem's license endpoints require an `x-api-key`, and that key is an ACCOUNT
//  credential rather than a license-scoped one. Shipping it inside a Mac app that anybody can
//  unzip would hand every user a credential against the store itself. So under Creem the
//  Worker is structurally required, not merely advisable, and the other two reasons still
//  stand on their own:
//
//    - A direct integration would have to cache the vendor's plain JSON to honour the offline
//      window (§3.2), and that cache is an editable text file. A signed token can be cached
//      and still cannot be forged.
//    - The product → tier/lifetime map lives here as configuration, so repricing or adding a
//      tier is an edit and a redeploy with nothing for a user to install.
//
//  WHAT IS DIFFERENT FROM THE LEMON SQUEEZY WORKER, and it is one thing that matters:
//  `POST /v1/licenses/validate` requires an `instance_id`, which only exists once the machine
//  has been ACTIVATED. Activation is therefore a prerequisite of validation rather than the
//  after-the-fact bookkeeping it was under Lemon Squeezy, where it ran in `waitUntil` and a
//  failure cost nothing. Two consequences are load-bearing and are handled below:
//
//    - KV is no longer a cache. It is the only record of which instance belongs to which Mac,
//      and the write has to complete BEFORE the response, because a lost id cannot be
//      recovered by asking Creem "which instance is this machine" — there is no such call.
//    - A machine whose instance was deleted in the dashboard would validate 404 forever. So a
//      404 from validate clears the entry and re-activates, once.

const CLAIM_VERSION = 1;
const DAY = 86_400;

/// Which product means what.
///
/// The one piece of configuration here, keyed on Creem's `product_id` (the Lemon Squeezy
/// worker keyed on `variant_id`; same idea, different vendor's noun). Fill these in from the
/// Creem dashboard.
///
/// `lifetime` decides the token's WINDOW, not whether it expires: a perpetual license still
/// checks in, so a refund stays revocable. Ninety days rather than seven because somebody who
/// paid once should not lose features over a fortnight offline, and rather than never because
/// a license that cannot be revoked cannot be refunded. See `LicenseWindows`.
const PRODUCTS = {
  "prod_7U04JyTc70e3eyxHM3sI7Z": { tier: "pro", rank: 1, lifetime: false },
  "prod_JWRUjlW5eKaNqrolx699C": { tier: "pro", rank: 1, lifetime: false },
  "prod_TzeZuhSzSIPDWSn1Yptns": { tier: "pro", rank: 1, lifetime: true },
};

/// Applied when a product is not in the map above.
///
/// Permissive on PURPOSE. The failure this prevents: a new product is created in the
/// dashboard, somebody buys it at 2am, and the issuer refuses every customer on it until
/// someone notices. A wrong tier is recoverable on the next refresh; a refused paying
/// customer is a support ticket and a refund. The mismatch is logged so it is findable.
const FALLBACK = { tier: "pro", rank: 1, lifetime: false };

export default {
  async fetch(request, env) {
    if (request.method !== "POST") return refuse(405, "method_not_allowed");

    let body;
    try {
      body = await request.json();
    } catch {
      return refuse(400, "malformed_request");
    }

    const key = typeof body.key === "string" ? body.key.trim() : "";
    const machine = typeof body.machine_id === "string" ? body.machine_id.trim() : "";
    // The server sends a SHA-256 hex digest. Checked rather than trusted: this value goes into
    // a signed claim, and a token minted for an attacker-chosen `machine` works on any Mac.
    if (!key || !/^[0-9a-f]{64}$/.test(machine)) return refuse(400, "malformed_request");
    if (!env.CREEM_API_KEY) return refuse(500, "issuer_misconfigured");
    if (!env.ACTIVATIONS) return refuse(500, "issuer_misconfigured");

    const license = await entitlementFor(key, machine, env);
    if (!license.ok) return refuse(license.status, license.reason);

    const record = license.entity;

    // `disabled` is the only status that means anything about the LICENSE rather than about
    // its dates: a refund, a chargeback, or a manual revocation. It is durable, so the server
    // persists it rather than retrying past it.
    if (record.status === "disabled") {
      return json(200, { token: null, revoked: true });
    }

    // `expired` is NOT refused. A token is still minted, carrying the end date, because that
    // is what lets the app say "your subscription ended on 14 March" instead of "could not
    // confirm". The server decides what an ended subscription permits; this only reports it.
    if (!["active", "inactive", "expired"].includes(record.status)) {
      return refuse(403, "license_not_usable");
    }

    const product = PRODUCTS[record.product_id] ?? FALLBACK;
    if (!PRODUCTS[record.product_id]) {
      console.log(`unmapped product ${record.product_id}; issued the fallback tier`);
    }

    const now = Math.floor(Date.now() / 1000);
    const claims = {
      v: CLAIM_VERSION,
      // The license's own id, never an email address: this is written to disk on the
      // customer's Mac and appears in diagnostics.
      sub: `lk_${record.id ?? "unknown"}`,
      tier: product.tier,
      // The rank travels WITH the token so a tier introduced after a server shipped still
      // orders correctly on it. See SubscriptionTier.
      rank: product.rank,
      feats: [],
      machine,
      iat: now,
      exp: now + (product.lifetime ? 90 * DAY : 7 * DAY),
      jti: crypto.randomUUID(),
    };
    // PERPETUAL IS STATED, NOT INFERRED FROM A MISSING DATE.
    //
    // Creem reports `expires_at` as null when a license has no expiry of its own, which is
    // true of a key on a recurring plan as well as of a lifetime purchase — the same trap
    // Lemon Squeezy set, and the one that told every healthy monthly subscriber they had
    // bought the software outright. The product map is the only thing that actually knows.
    if (product.lifetime) claims.perp = true;

    // Set only when the vendor has one: present and in the past is how an ended subscription
    // reaches the app as "ended on 14 March" rather than "could not confirm". Absent on an
    // active subscription is honest, and the app then says "active" without inventing a date.
    if (record.expires_at) {
      claims.sub_end = Math.floor(new Date(record.expires_at).getTime() / 1000);
    }

    return json(200, { token: await sign(claims, env), revoked: false });
  },
};

// MARK: - Creem

/// The license as Creem sees it, activating this machine first if it has not been seen.
///
/// Returns the `LicenseEntity` from whichever call produced it: activate and validate return
/// the same shape, so a machine's first visit costs one request rather than two.
async function entitlementFor(key, machine, env) {
  const cacheKey = await instanceCacheKey(key, machine);
  const known = await env.ACTIVATIONS.get(cacheKey);

  if (known) {
    const validated = await call("validate", { key, instance_id: known }, env);
    if (validated.ok) return { ok: true, entity: validated.body };
    // The instance was deleted in the dashboard, or the license was rotated. Forget it and
    // activate again, ONCE — a loop here would spend an activation slot per request.
    if (validated.status === 404) {
      console.log(`instance ${known} is gone; re-activating`);
      await env.ACTIVATIONS.delete(cacheKey);
    } else {
      return validated;
    }
  }

  // The machine hash is the instance NAME, not a name a person chose: it is what makes one
  // Mac one activation, and it is what the dashboard shows beside the slot.
  const activated = await call("activate", { key, instance_name: machine }, env);
  if (!activated.ok) return activated;

  const instanceId = activated.body?.instance?.id;
  if (!instanceId) return { ok: false, status: 502, reason: "vendor_response_unexpected" };

  // AWAITED, not `waitUntil`. There is no call that asks Creem "which instance belongs to
  // this machine", so this entry is the only record of it: dropping the write to save a few
  // milliseconds would burn one activation slot per refresh until the limit was exhausted.
  // No TTL, for the same reason — an activation does not lapse.
  await env.ACTIVATIONS.put(cacheKey, instanceId);
  return { ok: true, entity: activated.body };
}

/// KV key for one machine's instance id.
///
/// Hashed rather than `${key}:${machine}`, so a license key is not sitting in a KV key name
/// where it shows in a dashboard listing or a `wrangler kv key list`. The machine hash is
/// already a digest; this makes the pair one.
async function instanceCacheKey(key, machine) {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${key}:${machine}`)
  );
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/// One Creem license call.
///
/// `CREEM_API_BASE` selects test or production (`https://test-api.creem.io` while setting up,
/// `https://api.creem.io` once real money is involved) so the switch is a Worker variable
/// rather than an edit to this file. Defaulting to TEST is deliberate: a misconfigured
/// deployment that quietly talks to production is the worse accident.
async function call(path, payload, env) {
  const base = env.CREEM_API_BASE ?? "https://test-api.creem.io";
  let response;
  try {
    response = await fetch(`${base}/v1/licenses/${path}`, {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        // The reason this Worker is not optional. Never sent anywhere but Creem, and never
        // returned to the caller in any form.
        "x-api-key": env.CREEM_API_KEY,
      },
      body: JSON.stringify(payload),
    });
  } catch (error) {
    // The vendor being unreachable is OUR outage as far as the customer is concerned, so it
    // is a 502 rather than a 400: the server treats it as "could not confirm" and keeps the
    // token it already holds, which is the whole point of the window.
    console.log(`license ${path} failed: ${error}`);
    return { ok: false, status: 502, reason: "vendor_unreachable" };
  }

  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    // 404 is reported as-is so `entitlementFor` can tell "no such instance" (recoverable by
    // re-activating) from "no such license". Everything else collapses to a refusal: 401 is
    // OUR credential being wrong, which is not the customer's fault and must not read as a
    // dead license.
    if (response.status === 404) return { ok: false, status: 404, reason: "license_not_found" };
    if (response.status === 401) {
      console.log("creem rejected the API key");
      return { ok: false, status: 502, reason: "issuer_misconfigured" };
    }
    // 403 IS AMBIGUOUS AT CREEM and the two meanings could not be further apart. It is what
    // an under-scoped API key answers ("Invalid API key or insufficient permissions"), and
    // it is also, as far as anyone outside can tell, what an exhausted activation limit
    // answers — that error body is the one thing their documentation does not specify.
    //
    // Read as a refusal, the first meaning tells every customer their license is dead while
    // the actual fault is one unticked box in our dashboard, with nothing anywhere pointing
    // at it. So the body is sniffed for the documented credential wording and that case is
    // reported as OURS, which is what keeps a permissions mistake from being debugged by
    // staring at license keys. Anything else stays a refusal, because it probably is one.
    const detail = JSON.stringify(body);
    if (response.status === 403 && /api key|permission/i.test(detail)) {
      console.log(`creem refused the API key's scope: ${detail}`);
      return { ok: false, status: 502, reason: "issuer_misconfigured" };
    }
    console.log(`license ${path} refused: ${response.status} ${detail}`);
    return { ok: false, status: 403, reason: "license_not_usable" };
  }
  return { ok: true, body, status: response.status };
}

// MARK: - Signing

/// Compact JWS, Ed25519, signed over `header.claims`.
///
/// Identical to `worker.js`, and it has to stay that way: `TokenVerifier` matches it byte for
/// byte — three base64url segments, no padding, the signature over the first two joined by a
/// dot. The verifier does NOT read `alg` from the header — a verifier that lets the token
/// choose its algorithm is how `alg: none` happened — so the header is fixed here and is
/// decoration on the wire.
async function sign(claims, env) {
  const header = base64url(JSON.stringify({ alg: "EdDSA", typ: "JWT" }));
  const payload = base64url(JSON.stringify(claims));
  const signing = `${header}.${payload}`;

  const signature = await crypto.subtle.sign(
    "Ed25519",
    await privateKey(env),
    new TextEncoder().encode(signing)
  );
  return `${signing}.${base64url(new Uint8Array(signature))}`;
}

/// The secret is stored as the raw 32-byte seed, because that is the one representation both
/// sides agree on: swift-crypto takes raw bytes and WebCrypto takes PKCS8, and DER wrappers
/// are where cross-language key handling goes wrong. The fixed prefix below is the PKCS8
/// envelope for an Ed25519 private key; the only variable part is the seed.
///
/// THE SAME KEYPAIR AS THE LEMON SQUEEZY WORKER. Changing processor must not change the
/// signing key: the public half is compiled into every shipped server, so a new keypair
/// strands every existing license until each user updates.
async function privateKey(env) {
  const seed = Uint8Array.from(atob(env.SIGNING_KEY), (c) => c.charCodeAt(0));
  if (seed.length !== 32) throw new Error("SIGNING_KEY must be 32 base64-encoded bytes");
  const pkcs8 = new Uint8Array([
    0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22,
    0x04, 0x20, ...seed,
  ]);
  return crypto.subtle.importKey("pkcs8", pkcs8, { name: "Ed25519" }, false, ["sign"]);
}

// MARK: - Wire

function base64url(input) {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function json(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/// `reason` is the field `EntitlementClient` reads off a non-2xx body. It reaches a log, never
/// a person: the sentence a customer sees comes from `LicenseRefusal` on the Mac.
function refuse(status, reason) {
  return json(status, { reason });
}
