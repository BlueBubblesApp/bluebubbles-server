# Server backup and restore: plan

How this server will produce one file that carries everything needed to stand it up again on
another Mac, how that file is protected and checked, and how a restore applies it. A plan for
an implementing pass to take one phase at a time, with the file that proves each claim about
the tree as it stands.

**Status: not built.** Nothing in §3 onward exists. §1 was measured against the tree on
4 October 2026; re-measure before trusting it after a large change.

Vocabulary, because the word is already taken twice:

| Term | Means | Not to be confused with |
|---|---|---|
| **Archive** | The one file this plan produces: `<name>.bbbackup` | The `backup` table and the v1 `/backup/theme` and `/backup/settings` routes, which store opaque CLIENT blobs (`Sources/BBHTTPAPI/RouteTable.swift:477-486`). Those stay exactly as they are and are themselves one section of the archive |
| **Section** | One kind of state inside an archive, selectable by a checkbox | A table: a section may span several tables, or none |
| **Contributor** | The type in the module that owns some state, which knows how to export it into a section and apply it back | A service: a contributor has no lifecycle |
| **Undo point** | The archive the restore writes of the target's own state before it changes anything | A scheduled backup |

---

## 0. The rules this plan is under

Restated from [`CLAUDE.md`](../CLAUDE.md) because every section below touches them.

- **The v1 wire is frozen.** Every route here is additive, under `/api/v2`, through the
  `add-api-route` skill. The archive is not a wire format a shipped client reads, so its
  shape is this server's to decide.
- **A setting is declared in `SettingsRegistry` and named on the manifest of every service
  that reads it.** The scheduled-backup service declares what it reads; the engine that
  touches secrets is NOT a service, for the reason in §7.1.
- **A secret is never declarable by a service** (`ManifestValidator`, `ScopedSettings.checkRead`,
  `Sources/BBServiceKit/SettingsScope.swift:101-119`). The only code that may read the
  Keychain wholesale is composition-layer code holding `Storage` directly, the way
  `MigrationRunner` does. That decides where the engine lives.
- **`chat.db` is Apple's.** It is never in an archive. Messages, attachments and chats come
  back on the new Mac from iCloud and Messages.app, not from this server.
- **Never log a secret, never log a person.** An archive's password, its contents and its
  file name are never logged. Its own identifier, its section list and its byte count are.
- **Migrations are append-only**, and so are archive format versions (§3.5).
- **A rule the compiler cannot check ships with a test that scans for it.** §10.4 names
  each one this plan adds.
- **Say what was measured.** Where this plan could not verify a behaviour of a third-party
  tool from this tree, it says so (§13).

---

## 1. What exists, measured

### 1.1 Every piece of state, and where it lives

This is the inventory the sections in §6 are derived from. A row that is not a section is
listed with the reason.

| State | Store | Where | Sensitivity | Section |
|---|---|---|---|---|
| Typed settings, including every service field (`<service id>.<field>`), feature flags, `disabled_services`, each service's `<id>.__version` | `setting` table in `app.db` | `Sources/BBSettings/SettingsSchema.swift:22-31`; `Sources/BBServiceKit/ServiceManifest.swift:85,752`; `Sources/BBServiceKit/ServiceMigration.swift:78` | Configuration; `server_address` and the ntfy topic are the two that identify the install | `settings` |
| Server password, `ntfy_token`, six proxy and sink tokens | Keychain, service `app.bluebubbles.server`, one item per key; the table row holds only `is_secret=1` and an empty value | `Sources/BBSettings/SecretStore.swift:256-267`; `SettingsStore.swift:528-555`; secrets listed in `SettingsRegistry.swift:103,925` and `Sources/BBBuiltIns/BuiltInManifests.swift:156,199,277,430,583,841` | Secret | `secrets` |
| Token-signing key `auth.token_signing_key` | Keychain | `Sources/BBAuth/TokenIssuer.swift:210-242` | Secret | `secrets` |
| Firebase service account and client config, `fcm.service_account`, `fcm.client_config` | Keychain, verbatim JSON; the imported file is deleted after the write | `Sources/BBPushKit/ServiceAccount.swift:200-298` | Secret | `pushCredentials` |
| TLS certificate and private key, `tls.certificate`, `tls.private_key`, plus `tls_certificate_origin` and `tls_certificate_expires_at` settings | Keychain, PEM; provenance in two settings rows | `Sources/BlueBubblesServerCore/Composition/CertificateKeychainStore.swift:40-41`; `SettingsRegistry.swift:710-717` | Secret | `certificates` |
| FCM device registrations (`device`: token, name, codecs, public key, last active) | `app.db` | `Sources/BBAppStore/InterfacesSchema.swift`; `DeviceRepository.swift:20` | Personal | `devices` |
| Webhooks (`webhook`: URL, events, redirect policy) | `app.db` | `InterfacesSchema.swift` | Personal: URLs embed tokens | `webhooks` |
| Scheduled messages (`scheduled_message`: payload with recipients and text, schedule, status) | `app.db` | `InterfacesSchema.swift`; `Services/ScheduledMessageService.swift` | Personal: message content | `scheduledMessages` |
| Client theme and settings blobs (`backup`) | `app.db` | `Sources/BBAppStore/BackupRepository.swift` | Personal: opaque client JSON | `clientBackups` |
| Allowlist and blocklist (`allowed_client`, `blocked_client`) | `app.db` | `Sources/BBAuth/AccessControlSchema.swift:346-405` | Configuration; contains client addresses | `accessControl` |
| Paired token-auth clients (`paired_client`: secret hash, name, scopes, public key, revocation) | `app.db` | `AccessControlSchema.swift`; mode dormant per [`AUTH.md`](AUTH.md) § 1 | Secret-adjacent: hashes whose signing key is `auth.token_signing_key` | `pairedClients` |
| Locally created contacts (`contact` rows with `source = local`) and disabled contacts (`contact_disabled`) | `app.db` | `Sources/BBContacts/ContactsSchema.swift:64-158`; `ContactIndex.swift:30-41` | Personal | `contacts` |
| FaceTime link ledger | `~/Library/Application Support/BlueBubbles/facetime-links.json` | `Sources/BBSystem/FaceTimeLinkLedger.swift:41` | Personal | `faceTimeLinks` |
| Tailscale node state (node key, tailnet identity) | `~/Library/Application Support/BlueBubbles/tailscale/`, mode 0700 | `Composition/Services/Proxy/TailscaleMethod.swift:44-52` | Secret | `tailscale` |
| Contact index built from macOS Contacts (`contact`, `contact_address` with `source != local`) | `app.db` | `ContactsSchema.swift` | Personal | Not a section: rebuilt from the address book on the new Mac by `ContactsService` |
| Alert history (`alert`) | `app.db` | `InterfacesSchema.swift` | Low | Not a section: history, not state |
| Failed-auth ring (`auth_failure`) | `app.db` | `AccessControlSchema.swift` | Ephemeral | Not a section |
| Managed tool binaries, `Tools/<tool>/`, `state.json` | Support directory | `Sources/BBTooling/ToolStore.swift:6-8,34-43` | None | Not a section: re-downloaded, and keyed by architecture, which the new Mac may not share (`ToolStore.swift:16-18`) |
| `daemons.json`, `launcher-intent`, the lock file, `cloudflared/config.yml` (empty, rewritten on start) | Support directories | `Sources/BBProxy/DaemonLedger.swift:38`; `Sources/BBCore/LauncherContract.swift:74-107`; `SingleInstanceLock.swift:41`; `CloudflareMethod.swift:117-118` | None | Not a section: process bookkeeping |
| `uploads/`, `ConvertedAttachments/`, helper staging in the app containers | Support directory and containers | `Sources/BBMedia/UploadStore.swift:22-25`; `AttachmentConversion.swift:134-139`; `Sources/BBPrivateAPI/AttachmentStaging.swift:39` | Personal | Not a section: caches, swept |
| Logs | `~/Library/Logs/bluebubbles-server/` | `Sources/BBCore/LogDestination.swift:17-21` | Personal, redacted | Not a section: the support bundle's job (`ENTERPRISE_PLAN.md` § 2.3) |
| zrok environment | `~/.zrok`, written by `zrok enable` | `Sources/BBProxy/ZrokEnvironment.swift:93` | Secret | Not a section: zrok's own per-machine identity; §13 |
| Electron leftovers: `config.db`, `FCM/*.json`, `Certs/` | Support directory | `Sources/BBCore/ApplicationSupport.swift:90-109` | Secret | Not a section: migration sources, already imported into the stores above |
| Onboarding flags | `UserDefaults` of the app | `Models/OnboardingModel.swift:41-95`; `PermissionsModel.swift:170-171` | None | Not a section: §8.6 says what a restore does to onboarding instead |
| `~/bluebubbles.yml` | Home directory | `ServerComposition.swift:1037-1063` | Configuration, may hold secrets in plaintext | Not a section: an operator-authored overlay, outside the server's stores |
| User files that settings point at: `landing_page_path`, ngrok `traffic_policy_file`, cloudflare `config_file`, the two helper paths | Anywhere on disk | `SettingsRegistry.swift`; `BuiltInManifests.swift:362-366,444-447` | Varies | The PATH travels in `settings`; the file does not. The restore preview reports a path whose file is missing on the target (§8.3) |

### 1.2 Why a file-level backup of this server is lossy, and the code already says so

Every secret is a Keychain item written `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
in the data protection keychain (`SecretStore.swift:353-359`). That attribute is chosen on
purpose: it keeps the item out of Time Machine and Migration Assistant (`SecretStore.swift:159`),
which is the right property for a password at rest and the wrong one for moving house. The
tree names the consequence in three places:

- `TLSProvisioning.swift:172-199` calls out "the restore case": settings say an imported
  certificate exists, the Keychain is empty, and the only thing the server can do is
  regenerate a self-signed one and raise an alert saying the user's certificate is gone.
- `ToolStore.swift:16-18` anticipates a Time Machine restore onto a different CPU
  architecture.
- `.claude/docs/architecture.md:369-373` records a restore to a new Mac as "the one lossy
  case".

So a copy of `app.db` is a backup of the markers, not the secrets, and a copy of the home
directory loses the password, every tunnel token, the Firebase credentials, the TLS private
key and the token-signing key. An archive that carries secrets must therefore export them
explicitly and protect them in transit, which is what §4 is for.

### 1.3 What already moves state, one way

| Mechanism | Where | What it teaches this plan |
|---|---|---|
| Electron migration: four steps, `isBlocking`, `prerequisite`, per-step state in settings, run on `Storage` BEFORE `build` | `Migration/MigrationState.swift:39-123`; `MigrationRunner.swift`; `MigrationModel.swift`; `BlueBubblesServerCommand.swift:62` | A restore is this shape: it needs the one `SettingsStore` and the Keychain, no running server, and an entry both the app and the CLI share. §8.1 |
| `LegacyConfigMigration.run` coerces each value by its declared type and writes the completed marker in the same transaction as the import | `Sources/BBSettings/LegacyConfigMigration.swift:80-180` | Typed coercion against the registry is the validation step; a marker outside the transaction is a re-run hazard. §5.4, §8.4 |
| `PushInterface.importCredentials` and `CertificateImportView` | `ServiceAccount.swift:266-279`; `Views/CertificateImportView.swift` | The write paths for `pushCredentials` and `certificates` exist; the contributors call them rather than the Keychain. §6 |
| `SettingsStore.write` stages secrets in the Keychain, upserts rows in one transaction, rolls the Keychain back if the transaction fails, and broadcasts only the keys that moved | `SettingsStore.swift:439-616` | The `settings` and `secrets` sections apply through this call and nothing else. §8.4 |
| `SealedPayloadCodec`: AEAD with the plaintext header as additional authenticated data, a fresh nonce from the CSPRNG, HKDF with a domain-separation string | `Sources/BBEvents/SealedCodec.swift:1-60` | The archive's envelope follows the same construction and the same reasoning. §4 |
| `SecretHash`: scrypt through `_CryptoExtras`, chosen over Argon2id because swift-crypto ships no Argon2 and a new dependency would put unaudited crypto in the trust path | `Sources/BBAuth/Enrollment.swift:150`; [`AUTH.md`](AUTH.md) § Secrets are hashed with scrypt | The same primitive, with parameters chosen for a HUMAN password rather than a random secret. §4.2 |
| Subprocess-only archive extraction (`unzip`, `tar`); nothing in the tree creates an archive | `Sources/BBTooling/Unpacking.swift:44-62` | No zip or tar dependency to lean on, and none is wanted: §3.1 |

---

## 2. Goals and non-goals

**Goals.**

1. One file moves a server to a new Mac with no re-entry of any setting, token, credential
   or list, and the clients that were talking to the old server keep working against the
   new one without re-pairing.
2. The file is safe to put in iCloud Drive, on a USB stick or in an email: without the
   password its contents are unreadable, and with the password its integrity is proven
   before a byte is applied.
3. The restore refuses anything it cannot prove well-formed, lists every problem at once,
   writes nothing until the whole archive has passed, and leaves an undo point.
4. The user chooses what goes in, section by section, with everything selected by default.
5. The same engine serves the app, the CLI, the scheduled service and the API, so there is
   one definition of what a backup is.
6. An archive made by an older server restores on a newer one. A newer archive is refused by
   an older server with a message that says which to update.

**Non-goals.**

- Backing up messages, attachments or chats. `chat.db` is Apple's; iCloud carries it.
- Running two servers from one archive. A restore is a move, not a clone; §8.7 says what
  happens when both run.
- A general-purpose plugin hook. The contributor protocol is internal, and `BBServiceKit` is
  frozen (`Sources/BBServiceKit/ServiceManifest.swift:36-51`). §7.2.
- Replacing the support bundle (`ENTERPRISE_PLAN.md` § 2.3) or the audit journal
  (§ 2.1). §11 says how they relate.

---

## 3. The archive

### 3.1 One file, binary framed, no compression

```
offset  size      field
0       8         magic: ASCII "BBBACKUP"
8       4         header length, unsigned 32-bit big-endian
12      n         header: UTF-8 JSON, exactly the bytes used as additional authenticated data
12+n    rest      body: either plaintext UTF-8 JSON, or a ChaCha20-Poly1305 sealed box
```

Why framed rather than a single JSON document: the header has to be authenticated as the
EXACT bytes on disk, and JSON has no canonical encoding worth relying on across encoder
versions. Storing the header as raw bytes with a length prefix sidesteps canonicalisation
entirely. Why not zip or tar: the tree creates neither, extraction already shells out, a
container with file names inside it is a path-traversal surface, and nothing in a backup is
large enough to want compression. The body is kilobytes to a few megabytes: settings rows,
PEM, two Firebase documents, some tables, a small state directory. The header carries
`"compression": "none"` so a later format can add it without a magic change.

Extension `.bbbackup`, exported UTI `app.bluebubbles.backup` in `Packaging/Info.plist`, so
double-clicking an archive opens the app on the restore sheet (§9.1).

### 3.2 Header fields

All plaintext, all authenticated once the body is sealed. Nothing here is secret: the point
of the header is that a user or a support thread can read what an archive is without the
password.

| Field | Type | Purpose |
|---|---|---|
| `format` | int | Container version. `1`. Bumped only for a change to the framing, the KDF, the cipher or the header. §3.5 |
| `schema` | int | Body document version. `1`. Bumped when a section's shape changes incompatibly. §3.5 |
| `archive_id` | UUID | Names the archive in logs, the journal and the undo point. Never the file name |
| `created_at` | ISO 8601 | |
| `server_version`, `server_build` | string | `ServerVersion.current` (`Sources/BBHandlers/CoreHandlers.swift:91-101`) and `CFBundleVersion` |
| `macos_version`, `architecture` | string | For the preview's compatibility notes only; never a refusal |
| `migrations` | [string] | The applied `grdb_migrations` names, in order. Restore compares; §5.4 |
| `sections` | [string] | Section ids present in the body, so the preview can be drawn before decryption |
| `sensitivity` | string | The highest class among the sections: `configuration`, `personal` or `secret`. §3.4 |
| `protection` | object | `"none"`, or `{ "kdf": "scrypt", "n": 131072, "r": 8, "p": 1, "salt": base64, "cipher": "chacha20poly1305", "nonce": base64 }` |
| `body_length` | int | Declared length of the body bytes. Enforced before reading them. §5.1 |
| `body_sha256` | base64 | Digest of the body bytes as stored. The only integrity check an unprotected archive has; redundant with the AEAD tag on a protected one, kept so corruption and a wrong password report differently |
| `compression` | string | `"none"` |

### 3.3 Body document

A JSON object, `{ "schema": 1, "sections": { "<id>": <section document> } }`. Each section
document is owned by its contributor and is Codable with explicit keys. Two shapes recur:

- **Rows.** A list of objects with the table's column names as keys and values typed the
  way the column is. `updated_at` and `created_at` travel; `id` travels only where it is a
  foreign-key target, otherwise the target assigns one.
- **Files.** A list of `{ "name": string, "mode": int, "contents": base64 }`. `name` is a
  single path component, never a path: the contributor decides where each file lands (§5.5).

A settings value travels with its registry type tag, as the `setting` table stores it, and
is coerced on restore by the same `parse` the config-file layer uses (`Setting.swift:15-58`).

### 3.4 Sensitivity classes

Every section declares one, and the archive's class is the highest of its sections.

| Class | Means | Forces a password |
|---|---|---|
| `configuration` | Nothing that identifies a person or unlocks anything: ports, switches, tunnel choice, allowlist | No |
| `personal` | Content or an identifier of a person or a client: a webhook URL, a push token, a scheduled message, a local contact | Yes |
| `secret` | Anything from the Keychain, and the Tailscale node key | Yes |

A `configuration`-only archive may be written unprotected. That is what makes it also the
"configuration export" of `ENTERPRISE_PLAN.md` § 2.2: the same file, readable with `strings`
or `backup inspect`, carrying no secret and no person. §11.

### 3.5 Versioning rules

- **`format` is the container.** A reader opens only the formats it knows. A newer `format`
  is refused with "made by a newer BlueBubbles Server; update this server first". There is
  no reader for an unknown framing, by definition.
- **`schema` is the body.** Readers are append-only, like migrations: `BodyReader.v1`,
  `BodyReader.v2`, each upgrading its input to the current in-memory model. A newer `schema`
  on a known `format` is refused the same way.
- **Within a schema, a section is tolerant in one direction only.** A key the current reader
  does not recognise inside a KNOWN section is a refusal, listed by path, because the only
  ways it gets there are a newer server (caught above), corruption past the digest, or
  tampering. A section id the reader does not recognise is reported in the preview and
  skipped, never refused, because a section is a unit the user chose and a target without
  the contributor has nothing to apply it to.
- **A removed setting is handled by the reader for the schema that carried it**, with a
  rename or a drop stated in code, the way `LegacyConfigMigration`'s key map does
  (`LegacyConfigMigration.swift:246`). The registry itself never learns an old name.
- **A pinned corpus proves it.** `Fixtures/backups/` holds one archive per `(format,
  schema)` pair ever shipped, built from placeholder data, and a test restores each into an
  in-memory target and asserts the result. Changing a reader so an old archive stops
  restoring fails the build. §10.4.

### 3.6 What an archive never contains

- Anything from `chat.db`, any attachment, any message body other than the server's own
  scheduled messages.
- The password that protects it, in any form: not the password, not its hash, not a
  verifier. A wrong password is detected by the AEAD tag failing, and only by that.
- `backup_password`, the Keychain item the scheduled service uses (§7.4). The `secrets`
  contributor excludes it by name, and a test asserts the exclusion.
- An absolute path, a `..`, or a file destination. §5.5.
- Logs, alerts, the auth-failure ring, tool binaries, caches.

---

## 4. Protection

### 4.1 The construction

Password → scrypt → 32-byte master key → HKDF-SHA256 with info `bluebubbles-backup-v1` →
ChaCha20-Poly1305 key. The body is sealed in one call with a fresh 12-byte nonce from the
system CSPRNG and the header bytes as additional authenticated data. The salt and nonce are
in the header; the key and the password exist only in memory, as `SecureString` where the
type fits (`SettingsStore.swift:378-387`), and are zeroed on release.

Why this and not AES-GCM: ChaCha20-Poly1305 is what `SealedPayloadCodec` already uses, it has
no hardware-dependence story, and one AEAD in the tree is easier to audit than two. Why one
sealed box rather than chunks: the body is small (§3.1), and a streaming AEAD is where
implementations get nonce handling wrong. Why the header is AAD: so a `sections` list, a
`migrations` list or a `protection` block cannot be edited to steer the restore while the
tag still verifies, which is the relabelling attack `SealedCodec.swift:17-21` describes.

### 4.2 Key derivation parameters

| Parameter | Value | Why |
|---|---|---|
| scrypt N | 2^17 | The memory-hard setting for a human-chosen password: about 128 MiB and a fraction of a second on Apple silicon. `SecretHash` uses lighter parameters because its input is a random 32-byte secret ([`AUTH.md`](AUTH.md) § Secrets are hashed with scrypt); that reasoning does not transfer to a password a person typed |
| r, p | 8, 1 | Standard companions to that N |
| Output | 32 bytes | |
| Ceiling on restore | N ≤ 2^20, r ≤ 16, p ≤ 4 | The header is read BEFORE it is authenticated. Without a cap, a crafted header could ask the restore to allocate gigabytes. §5.1 |

The parameters live in the header so a later release can raise them without a format bump,
and an archive written with the old ones keeps restoring.

### 4.3 Password rules

- Required whenever the archive's sensitivity is `personal` or `secret` (§3.4). The UI
  enforces it by greying the "no password" choice out; the engine enforces it by throwing;
  a test asserts the engine does so the UI is not the only line.
- Minimum length is 12 characters. The app offers "Generate" (24 characters from the system
  CSPRNG, shown once, with a copy button through `CopyableValue`). A generated password is
  not stored anywhere by the app; the user keeps it.
- The password is never on a command line. The CLI takes `--password-file <path>` or
  prompts on a TTY; `BB_BACKUP_PASSWORD` is accepted for launchd use and documented as
  visible to the same user's processes.
- Never logged, never in an alert, never in the journal. A wrong password is reported as
  "wrong password or damaged archive", never distinguished, because the AEAD cannot tell and
  pretending otherwise would be a lie in an error string.

### 4.4 Why not sign with a server key

The Ed25519 token-signing key would be the obvious signer, and it is inside the archive. On
a fresh Mac there is no key to verify against before the restore, so a signature would prove
nothing to the one reader that matters. Authenticity here comes from the password: a party
who can produce a valid tag knew it. For an unprotected `configuration` archive there is no
authenticity at all, only integrity, and the restore's validation (§5) is what makes
applying a hostile one safe rather than a signature.

---

## 5. Validation on restore

Each step runs before the next and before anything is written. A failure anywhere stops the
restore with every problem found so far listed, not the first. This is the order, and the
attack or fault each step exists for.

### 5.1 Framing, before any parse

| Check | Refuses |
|---|---|
| File size ≤ 256 MiB, read through `FileHandle`, never `Data(contentsOf:)` on an unchecked size | An oversize file exhausting memory |
| Magic matches | Any other file; the UTI is a hint, this is the test |
| Header length ≤ 64 KiB and ≤ remaining bytes | A length that reads past the file or into a huge allocation |
| Header decodes with a strict `Codable` (unknown keys refused, every field required) | Malformed or edited header |
| `format` known | A newer container |
| KDF parameters within the ceiling of §4.2 | A header crafted to make the KDF allocate gigabytes |
| `body_length` equals the remaining bytes and ≤ 256 MiB | Truncation, concatenation |

### 5.2 Integrity and authenticity

| Check | Refuses |
|---|---|
| `body_sha256` matches the stored body | Corruption; reported as "damaged" before a password is asked for |
| Protected: AEAD opens with the header as AAD | Wrong password, tampering, a swapped header |
| Unprotected archive whose header claims `personal` or `secret` sensitivity | A file edited to carry secrets in the clear; the writer never produces one |
| Unprotected archive whose body contains a section of a non-configuration class | The same, decided from the body rather than the header |

### 5.3 Body shape

| Check | Refuses |
|---|---|
| `schema` known | A newer body |
| Body decodes through the reader for its `schema` with explicit keys | Corruption past the digest; never-seen keys |
| Every section id in the header's `sections` is present in the body and vice versa | A header and body from different archives, if the AAD check somehow passed |
| Each section's document validates on its own (§5.4 to §5.5) | |

### 5.4 Semantic validation, per section

- **Settings.** Every key must be declared: in `Settings.allKeys`, as a field on a manifest
  in the integration catalogue, as `disabled_services`, as a `<id>.__version` row, or as
  `feature_<id>`. Its type tag must match the declaration. Its value must pass the
  declaration's `validate`. A key marked `isSecret` must NOT appear here; it belongs in
  `secrets`. A namespaced key whose service is not in the catalogue is a skip with a
  reason shown in the preview, not a refusal: a plugin that is not installed has nothing
  to validate against, and dropping its rows would lose state the user chose to carry.
- **Secrets.** Every key must be a declared secret, or one of the fixed Keychain accounts the
  section owns (`auth.token_signing_key`). A key that is not a secret here is a refusal.
  The archive's own `backup_password` is a refusal if present (§3.6).
- **Rows.** Every row decodes into the repository's own model type, through its `Codable`,
  and is inserted through the repository, never through SQL built from the archive. A row
  that fails the model's own invariants (a webhook with no URL, a schedule with no payload)
  is a refusal naming the row.
- **Migrations.** The header's `migrations` list must be a PREFIX of the target's applied
  list. A longer list means a newer server; refused as in §3.5. A shorter one is the normal
  older-archive case. A list that diverges is a different lineage of `app.db` and is
  refused, because the readers only know how to upgrade along the shipped sequence.
- **Cross-section dependencies.** `pairedClients` without `secrets` is a warning in the
  preview: the hashes come across but the signing key does not, so every token is dead on
  arrival. `certificates` with `use_custom_certificate` off is a note, not a problem.

### 5.5 Files

The archive carries file CONTENTS under a contributor-chosen name, never a destination. The
tailscale contributor accepts only the names it knows (`tailscaled.state` and whatever else
§13 measures), refuses anything else by name, caps each at 16 MiB, writes into a fresh
directory under the support directory with mode 0700, and swaps it into place with a rename
only after every file has been written. No name may contain a path separator, `..`, or be
empty. A symlink in the target location is removed, never followed. The FaceTime ledger is a
single JSON file validated through its own `Codable`.

### 5.6 Preconditions on the target

| Check | Outcome |
|---|---|
| The server is not running (the restore holds `Storage` before `build`; the single-instance lock is the proof) | Refused with "stop the server first" on the CLI; the app stops it for you (§9.1) |
| `KeychainSecretStore.usingDataProtection` is true, or the build is unsigned | A warning in the preview: secrets would land in the legacy keychain, as `--check-keychain` would report (`BlueBubblesServerCommand.swift:280-306`) |
| Disk has room for the undo point plus the restore | Refused |
| `app.db` passes `PRAGMA integrity_check` before the undo point is written | Refused; the undo point would be a copy of a broken database |

---

## 6. Sections

The catalogue the checkboxes are drawn from. Every section is selected by default. `Replace`
and `merge` are the two restore modes (§8.2). "Owner" names the module whose contributor
exports and applies the section.

| Id | Class | Owner | Carries | On `replace` | On `merge` |
|---|---|---|---|---|---|
| `settings` | configuration | `BBSettings` | Every non-secret `setting` row except the excluded keys below, with type tags | Every carried key is written; keys on the target that the archive lacks are left alone, because an unset key reads as its declared default and deleting rows gains nothing | Only keys the target has never written |
| `secrets` | secret | `BBSettings` | Every declared secret, `auth.token_signing_key` | Written through `SettingsStore.write` (settings keys) and `SecretStore` (fixed accounts) | Only accounts the target lacks |
| `pushCredentials` | secret | `BBPushKit` | `fcm.service_account`, `fcm.client_config`, verbatim | Through `PushCredentialStore`, replacing both | Only if the target has neither |
| `certificates` | secret | `BlueBubblesServerCore` | `tls.certificate`, `tls.private_key`, `tls_certificate_origin`, `tls_certificate_expires_at` | Through `CertificateKeychainStore` with its read-back check, then the two settings in the same `write` as the clock, which `architecture.md` § the clock is written wherever the material is requires | Only if the target has no material |
| `devices` | personal | `BBAppStore` | `device` rows | Table replaced | Rows added by `identifier`; existing kept |
| `webhooks` | personal | `BBAppStore` | `webhook` rows | Table replaced | Rows added by URL; existing kept |
| `scheduledMessages` | personal | `BBAppStore` | `scheduled_message` rows, every status | Table replaced | Rows added by `uuid` |
| `clientBackups` | personal | `BBAppStore` | `backup` rows | Table replaced | Rows added by `(kind, name)` |
| `accessControl` | configuration | `BBAuth` | `allowed_client`, `blocked_client` | Both tables replaced | Rows added by address |
| `pairedClients` | secret | `BBAuth` | `paired_client` rows | Table replaced | Rows added by `client_id` |
| `contacts` | personal | `BBContacts` | `contact` rows with `source = local` and their `contact_address` rows; every `contact_disabled` row | Local rows and the disabled list replaced; the macOS-derived index untouched | Added by id |
| `faceTimeLinks` | personal | `BBSystem` | The ledger file | Replaced | Union by link |
| `tailscale` | secret | `BlueBubblesServerCore` | The node state directory | Replaced (§8.7 on what that means to the old Mac) | Refused: a node identity is one thing, not a set |

**Settings keys the `settings` section never carries**, each with its reason, pinned by a test
that lists them:

| Key | Why |
|---|---|
| `server_address` | Written by the active connection method on every start; a stale one would be announced to clients before the tunnel replaced it |
| `last_run_version` | Describes the target's own history |
| `last_fcm_restart` | A timestamp of the old server's push restart |
| `migration_*_state`, `legacy_config_imported` | Describe Electron files on the OLD Mac. Carrying `completed` across would stop a migration the new Mac might genuinely need; leaving them lets `MigrationState` look at what is actually on disk |
| `tls_certificate_origin`, `tls_certificate_expires_at` | Belong to `certificates`, and must move WITH the material or the renewer's clock is wrong |
| `backup_*` schedule and directory settings | A restore should not start writing archives into a directory that exists only on the old Mac. Carried under a separate `backupSchedule` id in a later phase if wanted |

---

## 7. Creating an archive

### 7.1 The engine is composition-layer code, not a service

`BackupEngine` takes `SettingsStore`, `any SecretStore`, `AppDatabase` and the contributor
list, which is exactly `ServerComposition.Storage` plus a catalogue, and is built in
`prepareStorage` (`ServerComposition.swift:99-133`) so the CLI and the app hold the same
one. It is reached from the running server through `LazyCollaborators`, which is where an
on-demand subsystem goes ([`CLAUDE.md`](../CLAUDE.md) § What is built on first use is one type).

It cannot be a service because a service reads settings through `ScopedSettings`, which
refuses every secret key regardless of entitlements (`SettingsScope.swift:101-119`), and the
`secrets` section is the point. `MigrationRunner` is the precedent for code that holds the
stores directly, and `.claude/docs/architecture.md` says why that is honest rather than a
bypass: in-process code can open `app.db` anyway; the manifest boundary is for the plugins
that will one day run out of process.

### 7.2 Contributors

```swift
public protocol BackupContributor: Sendable {
  static var section: BackupSection { get }          // id, class, title, summary
  func export(into: inout BackupBody) async throws   // read-only against the stores
  func preview(_ section: SectionDocument, against: Target) async throws -> SectionPreview
  func apply(_ section: SectionDocument, mode: RestoreMode, in: RestoreTransaction) async throws
}
```

The protocol lives in a new `BBBackup` module that depends on `BBCore` and swift-crypto only,
so every owning module can conform without a cycle. The composition root lists them in
`BackupCatalog.contributors`, the sibling of `AppSchema.contributors`
(`Composition/AppSchema.swift:32-37`). The checkbox list in the app and the `--sections` help
on the CLI are DERIVED from that list; no view names a section by hand, and
`IntegrationCatalogTests` is the model for the test that enforces it.

Built-in services do not get a manifest field for this. `BBServiceKit` is frozen, and a
contributor is not a plugin concern until plugins exist; when they do, the out-of-process
boundary will need its own design and this protocol is not it.

### 7.3 Consistency of a snapshot

- Settings are read as one copy of the cached table from the actor, so an archive never
  holds half of a `write`.
- Tables are read inside one `AppDatabase.read`, so the row sections are consistent with
  each other.
- Keychain items are read one by one; there is no transaction. The window between the
  settings read and the secret reads is where a concurrent token rotation could leave a
  mismatch, so the engine reads secrets FIRST and settings second and documents the order.
- Files are copied as they are. `tailscaled` may be writing its state file while the server
  runs; whether it writes atomically is a §13 measurement, and until it is measured the
  tailscale contributor copies only while the Tailscale method is stopped and says so in
  the preview.

### 7.4 The scheduled backup service

`app.bluebubbles.core.backup`, through the `add-a-service` skill, not user-manageable in the
enablement sense (it is on when a schedule is set), depending on nothing. Its `Host` is
`BackupProviding` (the engine) and `SettingsProviding`; it never sees the secret store. Its
manifest declares reads of the settings below and nothing else.

| Setting | Type | Default | Purpose |
|---|---|---|---|
| `backup_schedule` | enum `off`, `daily`, `weekly` | `off` | Cadence |
| `backup_hour` | int 0–23 | 3 | Local hour to run |
| `backup_directory` | path | `<support>/Backups/` | Where archives land. A directory Time Machine does capture, which is the whole reason a scheduled archive beside the Keychain-excluded secrets is worth having |
| `backup_keep_count` | int ≥ 1 | 7 | Retention; the oldest beyond the count is deleted after a successful write, never before |
| `backup_sections` | string list | every id | Which sections, as ids |
| `backup_password` | secret | unset | Required for any schedule whose sections are not all `configuration`. The service asks the engine whether a password is set; it never reads it |

Behaviour: on the tick, if the previous run is still going, skip and log at `debug`; write to
a temporary name in the directory, fsync, rename; prune; log one `info` line with the archive
id, the byte count and the section ids. On failure, raise an alert through `AlertCenter`
with `dedupeKey: "backup.scheduled-failed"`, severity `error`, action `openSettings(.backup)`,
and the sentence from `DiagnosticText.sentence(for:)`. A scheduled backup that fails silently
is the enterprise failure this service exists to prevent; success is not an alert.

### 7.5 Memory

scrypt at N = 2^17 allocates about 128 MiB for the duration of the derivation. The app's
budget in [`.claude/docs/performance.md`](../.claude/docs/performance.md) is per process; the
allocation is one-shot, freed before the body is sealed, and never concurrent with itself
because the engine serialises create and restore on one lane. State it in the engine's
header; measure it with the probe in §13 before shipping the parameter.

---

## 8. Restoring an archive

### 8.1 Where it runs

On `Storage`, before `build`, exactly where the Electron migration runs
(`MigrationRunner.swift`, `AppModel.start` → `prepareStorage` → migration check → `build`).
That gives the restore the one `SettingsStore` (whose in-memory cache is why a second store is
forbidden, `ServerComposition.swift:73-90`), the Keychain, and a server that is not serving
requests against tables being replaced.

The app reaches that state two ways: on first launch, from the onboarding restore step,
which runs before `build`; and on a running server, by the Backup page stopping the server,
keeping `Storage`, running the restore, and starting again, through `ServerControlling`
(`Sources/BBInterfaces/Capabilities.swift:247`). The CLI acquires the single-instance lock
and refuses if it cannot.

### 8.2 Modes

| Mode | Meaning | Default where |
|---|---|---|
| `replace` | The target's copy of each selected section becomes the archive's. The move case | Onboarding, CLI |
| `merge` | Add what the target lacks, keep what it has. For bringing a second server's webhooks or allowlist into a running one | Never the default; chosen explicitly |

Per-section semantics are the two right-hand columns of §6. A section that cannot merge
(`tailscale`) is refused in that mode and the preview says so before anything runs.

### 8.3 Preview, always

Every restore produces a preview first, and the preview is what the user confirms. It is a
table, per section:

- apply: counts of rows or keys that will change, with the before and after value for a
  setting that is not a secret;
- skip: each item with the reason (unknown service namespace, unchanged, merge keeps the
  target's);
- warning: a path setting whose file is missing on the target, `pairedClients` without
  `secrets`, the Keychain fallback (§5.6), a `tailscale` section while the archive's
  `created_at` is recent enough that the old node may still be up;
- refusal: anything from §5, which empties the apply column.

The CLI prints the same table and `--dry-run` stops there. Nothing in the preview prints a
secret's value; a changed secret shows as `••••` → `••••`, the `DiagnosticValue.secret`
rendering.

### 8.4 Transaction order

1. Write the undo point: a full archive of the target's current state, every section,
   protected with the SAME password the user just supplied for the incoming archive, to
   `<support>/Backups/undo-<archive_id>.bbbackup`. The password is already in memory and
   already the user's, so no second one is needed and the undo point is as protected as the
   thing it undoes. An unprotected incoming archive produces an undo point only if the
   target is itself `configuration`-only; otherwise the restore asks for a password for the
   undo point, because the target's secrets must not be written in the clear to undo a
   configuration import.
2. Files: write each file section into its staging directory (§5.5). Nothing is swapped yet.
3. Keychain: stage every secret through the existing `stageSecrets` path, which records the
   previous values for rollback (`SettingsStore.swift:493-498,608-616`). The fixed accounts
   (`fcm.*`, `tls.*`, `auth.*`) go through their own stores, each of which reads back what it
   wrote.
4. `app.db`: one transaction. Settings upsert, table replacements or merges through the
   repositories, and a `restored_from` marker row (archive id, time, sections, mode) written
   INSIDE the transaction, the way `LegacyConfigMigration` writes its completed marker,
   because a marker outside the transaction is how a re-run undoes the user's later changes.
5. Commit. On failure anywhere before this point: roll the Keychain back, delete the
   staging directories, leave the undo point on disk, report.
6. Swap the file sections into place by rename.
7. Broadcast one `SettingsChange` for every key that moved, so a restore on a running
   server restarts the services watching those keys and `SettingsPropagation` raises its
   restart-required notice for the `.composition` ones.

### 8.5 After a restore

- The server starts (or the onboarding continues). `TLSProvisioning` finds material and a
  clock that agree. `PushDeliveryService` finds credentials and devices.
- One `info` log line with the archive id, the mode and the section ids. One journal row
  (§11). No alert on success.
- The undo point stays until the user deletes it or retention prunes it, and the Backup
  page lists it under its own heading with a "Restore this" button that is the same restore
  flow.

### 8.6 Onboarding: the restore step is page two

The restore step is the SECOND page of onboarding, immediately after `welcome` and before
anything else asks the user for a decision. A person moving to a new Mac must be offered
their archive before they have typed a password, chosen a connection method or imported
Firebase credentials by hand, because every one of those steps becomes wasted work the
moment a restore runs. The step is a `restore` case in `OnboardingStep.ID`
(`Onboarding/OnboardingFlow.swift:164-167`) with `isSkippable: true`, a catalogue entry
whose `isIncluded` is always true, and a view case in `Views/Onboarding/OnboardingSteps.swift`.

The page asks one question: "Are you moving this server from another Mac?" It offers
"Choose a backup…", a drop target for a `.bbbackup`, and "Start fresh", which is the skip.
Choosing an archive opens the same restore sheet the Backup page uses (§9.1): password,
preview, confirm. The welcome page carries one sentence saying a backup can be restored on
the next page, so nobody reads the welcome text and reaches for their old settings first.

The catch the UI survey turned up: onboarding is presented only once the phase is `.running`
(`RootView.swift:188-198`), and a restore has to run BEFORE `build` (§8.1). So the step does
not restore in place. Confirming the sheet stops the just-started server, keeps `Storage`,
runs the restore on it through the shape `MigrationModel` already has, and starts again. The
first start of a fresh install has nothing worth keeping, so the stop is invisible to the
user beyond a progress indicator on the sheet. The sheet cannot be dismissed while this runs.

After a successful restore the flow continues at `permissions`, because macOS grants are per
Mac and nothing in an archive can supply them. Each later step's `isIncluded` consults what
the restore applied, through the `restored_from` marker (§8.4) rather than onboarding state:

| Step | Shown after a restore when |
|---|---|
| `permissions` | Always |
| `connection` | `settings` or `secrets` was not applied, or the server password is still unset |
| `firebase` | `pushCredentials` was not applied |
| `webhooks` | `webhooks` was not applied and the goal asks for it |
| `api` | As before; it only explains |
| `privateAPI` | Always; it depends on this Mac's SIP state and helper, which no archive carries |
| `groupShortcut` | As before |
| `finish` | Always, and it names the archive id and the sections that were applied |

Every step shown after a restore is prefilled from the restored values, so a user who
reaches `connection` sees their tunnel already chosen rather than a blank form. The
onboarding flags in `UserDefaults` are not touched by the restore; the flow reaches `finish`
the ordinary way.

A restore chosen later, from the Backup page on a running server, does not re-run
onboarding. The two entry points share the sheet and the engine and differ only in what
happens afterwards.

### 8.7 Moving house: what is a move and what is a clone

Restoring an archive onto a second Mac while the first still runs produces two servers with
the same password, the same Firebase credentials, the same device list and, if `tailscale`
was carried, the same node identity. Push would be sent twice; the tailnet would see one
node flapping between two machines. The preview says, once, that a restore is a move and the
old server should be stopped, and the `tailscale` row of the preview says it again
specifically. The journal on the old server records nothing, because it is not told. A
`server_id` setting that clients could use to tell two servers apart is in §12.

---

## 9. Surfaces

### 9.1 The app

A `backup` case on `Destination` (`RootView.swift:12-61`), titled "Backup", symbol
`externaldrive`, taking the ninth ⌘ slot (`BlueBubblesApp.swift:103`). State reaches it through
a `backup` member on the `security` facade (`ServerAccess.swift:114-116`), never `AppContext`.
It is a `TablePage` because its centre is a list of archives.

| Region | Contents |
|---|---|
| Make a backup | The section checkboxes, derived from `BackupCatalog` with each section's title, summary and class badge; the password fields with Generate and the minimum-length rule; the "no password" choice greyed out with the reason while any selected section is `personal` or `secret`; "Back up to…" opening an `NSSavePanel` on `.bbbackup` |
| Automatic backups | The schedule settings of §7.4 as their generated rows; the directory as a `CopyableValue`; a `ServerStoppedNotice(placement: .section, purpose: "run automatic backups")` when the server is stopped |
| Archives | A `Table` of archives in the backup directory and the undo points: created, size, sections, protected, server version. Read through `ScreenModel` so a directory that cannot be read says so. Actions: Restore, Reveal in Finder, Delete (confirmed) |
| Restore from a file | "Choose…" opening an `NSOpenPanel`; also the drop target for a `.bbbackup`, and the destination of the UTI's open-document event |

The restore sheet: password, mode, the section checkboxes narrowed to what the archive holds,
then the preview table of §8.3, then "Restore and restart". It cannot be dismissed while
the restore runs. Every image-only control has an `accessibilityLabel`
(`AccessibilityPolicyTests`); every error goes through `DiagnosticText.sentence(for:)`.

### 9.2 The CLI

`ENTERPRISE_PLAN.md` § 2.10 proposes replacing the seven flags with subcommands. This plan
adds a `backup` subcommand group to that design and does not wait for it: if subcommands are
not in yet, the same verbs ship as `--backup-create`, `--backup-restore`, `--backup-inspect`
in the `xAndExit` pattern of `BlueBubblesServerCommand.swift:83-149`, run on `Storage`
without building the server, and become hidden aliases when the subcommands land.

| Verb | Does |
|---|---|
| `backup create <path> [--sections a,b] [--password-file f \| --no-password]` | Writes an archive. `--no-password` is refused unless every section is `configuration` |
| `backup inspect <path>` | Prints the header, and with a password the preview against this machine. Writes nothing |
| `backup restore <path> [--mode replace\|merge] [--sections …] [--dry-run] [--yes]` | Preview, then apply. Refuses while the lock is held. Without `--yes` on a TTY it asks; off a TTY it refuses without `--yes` |
| `backup verify <path>` | Framing, digest and, with a password, the tag. Exit status says which failed |

The password comes from `--password-file`, the prompt, or `BB_BACKUP_PASSWORD`; never an
argument. Each verb takes the capabilities it needs, not `AppContext`.

### 9.3 The API

Under `/api/v2/server/backup`, `server:admin`, in `AdditiveRoutes`, listed in
`BBOpenAPI/RouteCatalog.swift` with availability `always`.

| Route | Does |
|---|---|
| `GET /server/backup/sections` | The section catalogue: id, title, class, default. What a management UI draws its checkboxes from |
| `GET /server/backup/archives` | The archives in the backup directory, header fields only |
| `POST /server/backup` | Runs a backup into the backup directory with the configured sections and the configured `backup_password`. Answers the header. The archive does NOT come back in the response |
| `GET /server/backup/status` | Schedule, last run, last outcome, next run |

**No download and no restore over the network.** The reasoning is `ENTERPRISE_PLAN.md`
§ 2.2's and it is the same here with higher stakes: an archive that can leave over the API
is every secret this server holds, leaving with a stolen password. A restore over the API
is remote code to the Keychain. Both become reasonable when per-device credentials are
live and a `server:backup` scope can be a separate, revocable credential; until then the
file leaves through the app, the CLI or the directory. §12.

---

## 10. Code placement, tests and documents

### 10.1 Modules

| Module | Holds | Depends on |
|---|---|---|
| `BBBackup` (new) | `ArchiveHeader`, `ArchiveWriter`, `ArchiveReader`, the KDF and AEAD wrapper, `BackupSection`, `BackupContributor`, `BodyReader.v1`, the refusal types | `BBCore`, `Crypto`, `_CryptoExtras` |
| Owning modules | One contributor each, next to the repository or store it reads: `BBSettings` (`settings`, `secrets`), `BBPushKit`, `BBAppStore`, `BBAuth`, `BBContacts`, `BBSystem` (`faceTimeLinks`) | add `BBBackup` |
| `BlueBubblesServerCore` | `BackupEngine`, `BackupCatalog`, the `certificates` and `tailscale` contributors (they sit beside `CertificateKeychainStore` and `TailscaleMethod`), `BackupService`, the `restored_from` marker as a `SchemaContributor`, wiring in `prepareStorage` and `LazyCollaborators`, `BackupProviding` in `ServiceCapabilities.swift` | |
| `BBInterfaces` | `BackupInterface`: catalogue, create, inspect, restore-preview, restore, list; the typed values the app and the handlers project from | |
| `BBHandlers`, `BBHTTPAPI`, `BBOpenAPI` | The four routes, their handler ids, catalogue entries | |
| `BlueBubblesApp` | `Destination.backup`, `BackupView`, `RestoreSheet`, the onboarding step, the UTI handling | |
| `BlueBubblesServer` | The CLI verbs | |

`python3 Tools/package-graph/check.py` fails the build if `Package.swift` and the imports
disagree.

### 10.2 Settings

Through the `add-a-setting` skill: the six in §7.4, `backup_password` marked `isSecret`,
`backup_directory` with `kind: .path`, all `renderable` on the Backup page, and the schedule
settings `requires: Settings.backupSchedule.key` so the rows grey out while the schedule is
`off`. `backup_sections` is a string list and needs a `SettingValue` conformance, or is
stored as a comma-joined string with a comment saying why; the implementing pass decides and
`SettingDependencyTests` pins the dependency shape either way.

### 10.3 Wiring tests

Following `Tests/CompositionTests/EventDeliveryWiringTests.swift:162-188`:

- `BackupWiringTests`: `BackupCatalog.contributors` is non-empty, every id is unique, the
  engine is reachable from `AppContextFixture`, the service id appears in
  `registry.manifests` after `registerServices`.
- `BackupCoverageTests`: every table in `app.db` (read from `sqlite_master` on an in-memory
  database after `migrate`) is either carried by some contributor or named in an explicit
  `notBackedUp` list with a reason (`alert`, `auth_failure`, `grdb_migrations`, the
  macOS-derived part of `contact`). A new table fails the build until someone decides.
- `BackupKeychainCoverageTests`: every Keychain account name the tree writes (gathered by
  scanning for `kSecAttrAccount` writes and the fixed account constants) is in a section or
  in the exclusion list (`diagnostics.keychain_probe`, `backup_password`).

### 10.4 Behaviour and policy tests

| Test | Asserts |
|---|---|
| Round trip, in-memory `AppDatabase` and `InMemorySecretStore` | Create, restore into an empty target, every section equal; both modes; each section alone |
| Tamper matrix | Flip one byte in the magic, the header length, each header field, the body, the tag, the nonce, the salt; truncate at each boundary; append a byte. Each is refused with the expected refusal and nothing is written |
| Wrong password | Refused as "wrong password or damaged"; the undo point is NOT written (it is written after the tag verifies) |
| Unprotected archive carrying a `secret` section | Refused |
| KDF ceiling | A header asking for N = 2^21 is refused before derivation |
| Unknown setting key, wrong type tag, failing `validate`, secret in `settings` | Each refused and all listed together |
| Unknown service namespace | Skipped, listed in the preview, the rest applied |
| Unknown section id | Skipped, listed |
| Newer `format`, newer `schema` | Refused with the update message |
| Divergent `migrations` | Refused |
| File section with `..`, `/`, an empty name, an unknown name, an oversize file | Refused |
| Keychain failure mid-restore | Rolled back; `app.db` unchanged; undo point present |
| `app.db` failure mid-restore | Keychain rolled back; staging removed |
| `restored_from` marker | Written in the same transaction; absent after a failed restore |
| The pinned corpus (`Fixtures/backups/`) | Each archive restores and matches its expected state. `TestDataPolicyTests` already refuses a real address in a fixture; the corpus is built from the placeholder data it allows |
| Excluded settings | The list in §6 is the list in code |
| `BackupSectionCatalogPolicyTests` (source scan) | No file under `Sources/BlueBubblesApp/` or `Sources/BlueBubblesServer/` names a section id as a string literal; the catalogue is the only source |
| `BackupLogPolicyTests` (source scan) | No `logger.<level>` call in `BBBackup` or the engine carries a key named `path`, `file`, `password` or `name`; `LogRedactionPolicyTests` is the pattern |
| Scheduled service | Runs on the tick, skips when running, prunes after success only, raises the alert on failure with the dedupe key, never on success |
| Password rules | Engine refuses a `personal` or `secret` archive without a password, and a password under the minimum, independently of the UI |

### 10.5 Documents that change with the code

- A reference page `docs/BACKUP.md`: the archive format, the section table, the CLI, the
  restore procedure, the "moving house" section, written to [`WRITING.md`](WRITING.md).
  This plan is deleted when it lands; finished work is not kept as a plan.
- `CLAUDE.md`: a "Where to go" row, a "Where do I add…" row for a section, a non-negotiable
  for the catalogue-only rule, with its test named.
- `.claude/docs/architecture.md`: the engine under "built on first use", and the restore
  case paragraph rewritten to point at the restore.
- `.claude/docs/database.md`: the `restored_from` table and the migration list, which the
  survey found already stale (it lacks `contacts.addContactSearchHaystack`,
  `contacts.addContactEnablement` and `interfaces.addWebhookRedirectPolicy`).
- `docs/AUTH.md`: a line that `auth.token_signing_key` moves with the `secrets` section.
- `docs/TESTING.md`: the corpus and the policy tests.
- `TLSProvisioning.swift:172-182`: the "restore case" comment gains the sentence that the
  restore path exists and what it does to the clock.
- `.claude/docs/decisions.md`: a dated section on why the engine is not a service, why
  there is no download route, and why there is no signature.

---

## 11. How this relates to the audit journal and the enterprise plan

The audit journal of `ENTERPRISE_PLAN.md` § 2.1 is being built separately. Three points of
contact, none of which makes either plan depend on the other's order:

- **Journal rows are not a section.** They are history, not state, and they are the one
  record that should NOT be rewritable by a restore. The `notBackedUp` list in §10.3 names
  the journal's table with that reason once it exists.
- **The engine writes journal rows** when the journal exists: `admin` category,
  `backup-created`, `backup-restored`, `backup-restore-refused`, `undo-point-written`, with
  the archive id, the section ids and the mode in `detail`, and the actor the journal
  already models (`app`, `cli`, `api`, `system` for the scheduled service). Until the
  journal exists the same facts go to the `info` log, which is where the journal's hooks will
  find them. Never the file name, never the password, never a value.
- **A restore is the one event the journal cannot see from the inside**, because it happens
  before `build`. The `restored_from` marker (§8.4) is what the journal reads at the next
  start to write its `server.restored` row, and it is also what `GET /server/info`'s
  diagnostics can report.

The rest of the enterprise plan, adjusted:

| `ENTERPRISE_PLAN.md` item | Effect of this plan |
|---|---|
| § 2.2 Configuration export and import | Subsumed. A `configuration`-only unprotected archive is the export; `backup inspect` is the human-readable view; the import is a restore. The JSON body is the document that section asks for, inside a framed container. `GET /api/v2/config/export` is NOT added; §9.3 |
| § 2.3 Support bundle | Unchanged. It may include a `configuration`-only archive and never anything above that class |
| § 2.10 CLI subcommands | Gains the `backup` group; §9.2 |
| § 2.11 Validated configuration file | Unchanged, and the validation it wants is the §5.4 settings check, which `BBBackup` should expose as a function both can call |
| § 2.12 `app.db` care | The `VACUUM INTO` copy is dropped from that item: an archive is the copy, and § 2.12 itself says a copy of `app.db` is not a full backup. `integrity_check` stays, and the restore runs it (§5.6) |

---

## 12. Considered and not built

| Idea | Why not, and what would change the answer |
|---|---|
| Download or restore over the API | §9.3. Revisit when per-device credentials and a `server:backup` scope are live |
| A signature from the token-signing key | §4.4. Proves nothing on the Mac that matters |
| Compression | Bodies are small; a decompressor is a bomb surface; the header field is reserved |
| Chunked or streaming AEAD | Same size argument; one sealed box is the construction the tree already trusts |
| Argon2id | [`AUTH.md`](AUTH.md) § Secrets are hashed with scrypt; the same dependency argument |
| Carrying tool binaries | Architecture-specific and re-downloadable; the tool-updates service restores them |
| Carrying `~/.zrok` | zrok's own identity; §13 |
| Carrying the macOS-derived contact index | Rebuilt from Contacts on the new Mac; carrying it would ship a copy of the user's address book in every archive |
| Carrying `~/bluebubbles.yml` | Operator-authored, may hold secrets in plaintext, outside the stores; the operator moves it |
| A `server_id` setting so clients can tell two servers apart | Wanted for §8.7 and for client attribution, but it touches the v1 `server/info` payload and is a client change; a separate decision through `acceptedDifferences` |
| Encrypting with the server password instead of a separate one | The server password is inside the archive; a file that decrypts with its own contents is no protection, and the clients that know the password are the parties who should not be able to open it |
| Restoring while the server runs, without a stop | The settings cache and the single-store rule (`ServerComposition.swift:73-90`); replacing tables under live services |
| Multi-tenant or remote fleet restore | `ENTERPRISE_PLAN.md` § 4 |

---

## 13. What has to be measured before it is relied on

Each of these is a claim this plan could not settle from the tree. The implementing pass
measures it, records the result in `docs/BACKUP.md` with the macOS version, and only then
depends on it.

- **Which files `tailscaled` writes under its state directory, and whether it writes them
  atomically.** Decides the allowlist of names in §5.5 and whether the contributor can copy
  while the method runs (§7.3).
- **Whether a zrok reserved share can be used from a new environment.** If a reserved share
  is bound to the environment that reserved it, carrying `reserved_token` is not enough and
  the restore must re-reserve under the same name; the preview should say which.
- **Whether Firebase accepts the same service account from two machines**, which is the
  §8.7 clone case for push. Expected yes, with doubled delivery.
- **What scrypt at N = 2^17 costs on the oldest Mac the floor allows** (macOS 14 on Intel),
  in time and peak memory, against the budget in `performance.md`.
- **Whether `KeychainSecretStore` on the new Mac prompts for anything on first write** of
  the restored items in a signed build. The data protection keychain should not; §5.6's
  warning depends on it.
- **How `ToolUpdateService` behaves when the restored settings name a tool version that is
  not on disk**, so the first start after a restore downloads rather than fails.

---

## 14. Order of work

Each phase ends with the five checks green ([`CLAUDE.md`](../CLAUDE.md) § Fast commands) and
its tests from §10 in place.

1. **`BBBackup`**: the container, the KDF and AEAD wrapper, the header, `BodyReader.v1`, the
   contributor protocol, the refusal types, the tamper matrix and the first corpus archive.
   No contributor yet; the round trip uses a test contributor.
2. **Contributors and the engine**: every section in §6, `BackupCatalog`, `BackupEngine`
   on `Storage`, the coverage tests, the `restored_from` marker, the excluded-settings list
   and its test.
3. **Restore**: preview, modes, the undo point, the transaction order, the preconditions,
   the failure tests. CLI verbs in the `xAndExit` pattern, because they are the cheapest
   way to drive the engine end to end on a real Mac, and the §13 measurements happen here.
4. **The app**: the Backup page, the restore sheet, the UTI, the onboarding step.
5. **The scheduled service**: settings, manifest, retention, the alert, its tests.
6. **The API**: four routes, catalogue entries, OpenAPI regeneration.
7. **Documents**: `docs/BACKUP.md` and the list in §10.5; delete this plan.
