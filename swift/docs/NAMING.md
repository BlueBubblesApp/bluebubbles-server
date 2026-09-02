# Naming

One rule per namespace, and the reason for it. Where a namespace is inconsistent, this
document says whether that is a contract we are bound to or a bug to fix.

`Tests/CompatibilityTests/NamingConventionTests.swift` enforces the parts a test can see.
If you are adding a key and the test fails, this file is why.

## The short version

| Namespace | Convention | Enforced |
|---|---|---|
| Database tables | `snake_case`, **singular** | test |
| Database columns | `snake_case` | test |
| Settings keys | `snake_case` | test |
| Feature flag ids | `snake_case` | test |
| Socket.IO events | `kebab-case` | frozen |
| Diagnostic codes | `snake_case`, dotted (`access_control.blocked`) | test |
| Diagnostic context keys | `snake_case` | test |
| **`/api/v1` JSON** | **whatever Node emitted** | parity harness |
| **`/api/v2` JSON** | **`snake_case`** | test |
| Swift identifiers | `camelCase` / `PascalCase`, British spelling | swift-format |

## Why v2 is snake_case

v2 cannot be uniform, and no choice available makes it uniform. Two things do not move:

- **`auth/*` is `snake_case` by RFC.** `access_token`, `token_type`, `expires_in`,
  `client_id`, and `client_secret` are OAuth 2.0 (RFC 6749) field names. A client's OAuth
  library reads those spellings. They are not ours to restyle.
- **Embedded iMessage entities are `camelCase` and frozen.** A message, chat, handle or
  attachment inside a v2 response comes out of the *same serializer v1 uses*. That sharing
  is the point — there is one definition of what a message looks like — and it means those
  objects carry v1's casing wherever they appear.

So the only real question is where the seam goes. Putting it at
**"our own fields vs. inherited entities"** gives a client one structural rule it can
actually hold in its head, and it lines up with the database, the settings store, the
feature flags and the OAuth endpoints — four of the five namespaces that were already
`snake_case`. The alternative seam, "camelCase everywhere except auth", is a carve-out with
no principle behind it, and it still leaves the entities to explain.

Concretely:

```
GET /api/v2/chat/:guid/mute        ->  { "is_muted": true, "muted_until": 1735689600000 }
GET /api/v2/chat/:guid?with=lastMessage
                                   ->  { "lastMessage": { "isFromMe": true, ... } }
                                          ^ inherited entity, keeps v1 casing
```

## Why v1 is left alone

`/api/v1` is 228 distinct keys across four conventions — `guid`, `isFromMe`,
`server_version`, `SMS`, `__kIMMessagePartAttributeName`. It reads as a mess because it is
one. It is also the contract: every one of those spellings is something a shipped client
switches on, and the parity harness diffs our table against the reference's in both
directions precisely so nobody "tidies" one.

**A bug fix belongs in v1. A naming preference does not.**

## What is not ours to rename

Three boundaries carry Apple's naming, and it stays camelCase on all of them. Renaming
anything here breaks a real interface:

- **IMCore selectors and class names** — `isMuted`, `filterCategory`, `horizontalAccuracy`
  as they appear in `Tests/HelperTests/IMCoreSelectorTests.swift` are Objective-C selectors
  we call. They are Apple's names for Apple's methods.
- **Plist keys we read** — `extensionIdentifier` and `isHighKey` in the `-watchBackground`
  cache are keys Messages wrote. We are a reader of that file, not its author.
- **The helper protocol** — `BBPrivateAPI` talks to the Objective-C helper in the helper's
  own vocabulary, which is IMCore's. `PrivateAPIClient` translating `isMuted` off the wire
  into `is_muted` in an HTTP response is the seam working correctly.

The rule is about names *we* choose. Where we are quoting someone else's interface, we
quote it exactly.

The same reasoning exempts one route. `GET /api/v2/facetime/:group_uuid/debug` forwards the
helper's dictionary unchanged — one of its keys is `getActiveLinks(createdOnly:false)`, an
Objective-C selector — so it is listed in `NamingConventionTests.passthroughRoutes` rather
than restyled. It is registered only in development builds. **Adding a route to that list
needs a reason of the same kind: the keys are genuinely another system's, not merely
inconvenient to rename.**

## Database

Tables are singular (`alert`, not `alerts`) because a row is one of the thing.

Columns:

- **`_at` for a time something happened** — `created_at`, `read_at`, `blocked_at`,
  `last_seen_at`, `occurred_at`. All of them, no exceptions.
- **`_for` for a time something is aimed at** — `scheduled_message.scheduled_for` is the
  only one. It is not an event time: it may be in the future and may never arrive, and
  calling it `scheduled_at` would say the scheduling happened then, which is what
  `created_at` already says.
- **`is_` for booleans** — `is_secret`, `is_permanent`, `is_durable`.
- **`_count` for counts** — `occurrence_count`, `failure_count`, `offence_count`.
- **`<table>_id` for foreign keys** — `contact_address.contact_id`.

Column names leak. `blocked_client` is serialized field-for-field onto
`/api/v2/server/security/blocklist`, so a column named badly is a wire key named badly.
That is how `first_seen` and `blocked_at` ended up side by side in one JSON object as two
timestamps spelled two ways.

### Known exception: identity columns

Four spellings for the same idea survive from before this document:

| Table | Column | |
|---|---|---|
| `alert` | `uuid` | text UUID beside an int `id` |
| `device` | `identifier` | client-supplied |
| `contact` | `id` | text primary key |
| `paired_client` | `client_id` | text primary key |

These are **not** renamed. They are primary keys and foreign key targets, and the churn
buys nothing a comment cannot. **New tables use `id` for the primary key and `uuid` for a
UUID that is not it.**

## Migrations are append-only

Never edit a released migration — two installs on the same version would have different
schemas. Renaming a column means a *new* migration with `table.rename(column:to:)`.

## Spelling

British, in prose and identifiers: `colour`, `behaviour`, `normalised`, `offence`.
`AppBehaviour`, `colour(_:)`, `offence_count`. Apple's own API names keep their spelling
(`CLLocationCoordinate2D`, `.color`) — do not fight the SDK.
