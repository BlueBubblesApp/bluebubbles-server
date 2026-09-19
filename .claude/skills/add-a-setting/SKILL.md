---
name: add-a-setting
description: Add, change, hide or remove a setting in the BlueBubbles Swift server. Use when declaring a Setting in SettingsRegistry, giving one a UI row, marking one secret, making one depend on a switch, deciding whether a change applies live or needs a restart, letting a service read one, or when a settings, dependency or key-literal test is failing. Covers what a storage key costs, what is derived rather than declared, and the gotchas that produce a row which looks live and is not.
---

# Adding a setting

Read [`.claude/docs/database.md`](../../docs/database.md) for how settings are stored. The rules
below are the ones that cost rework or ship a lie to the user.

## Step 0: two things you do not need to do

- **No migration.** `setting` is a key-value table; a new key is a new row. Only a *renamed* key
  needs thought, and see the next step for why you should not rename one.
- **No second list.** `Settings.all`, `allKeys` and `secretKeys` are all derived from the
  declarations. A key in neither `renderable` nor `hidden` does not exist.

## Step 1: declare it, once

`Sources/BBSettings/SettingsRegistry.swift`

```swift
public static let dbPollInterval = Setting<Int>(
  "db_poll_interval", default: 30_000,
  validate: { value in
    guard value >= 30_000 else {
      throw SettingsError.validationFailed(
        key: "db_poll_interval", reason: "minimum is 30 seconds (30000ms)")
    }
  },
  presentation: .init(
    label: "Backup Check Interval (ms)",
    help: "…",
    section: .advanced, control: .number(range: 30_000...600_000))
)
```

- **The key is storage, and it does not change.** Keys are unchanged from the Electron server.
  Renaming one orphans the row a user's value already lives in, breaks the config-file name, and
  breaks the mapping `LegacyConfigMigration` reads the Electron `config.db` with. They are not
  wire names — nothing serves the settings map to a client.
- **Declare the real type.** That is half of what declaring here buys: `start_delay` is a
  `Double` here, while the Electron server stores the STRING `"0.0"` so its type inference does
  not read it as a boolean.
- **`validate:` runs on write, and only on write.** That is a deliberate placement, not a
  convenience: `password` validates entropy here because validating on the auth path instead
  would lock out every client holding a weak password the moment the server updated. Exempt the
  shipped default if refusing it would make a fresh install unconfigurable.
- **`isSecret: true` routes the value to the Keychain and redacts it everywhere** — `secretKeys`
  is derived from the flag, and both `SettingsScope` and the diagnostic redaction consult it. A
  literal list would miss a setting declared secret later, silently and in the worst direction.

## Step 2: give it a row, or say it has none

| | |
|---|---|
| Has a `presentation:` | Add it to `Settings.renderable`, which is the generated UI **in presentation order** |
| No UI at all | Add it to `Settings.hidden`: bookkeeping the server reads and the user never sees |

Both lists are hand-written because Swift cannot enumerate declarations; `allKeys` is derived
from them. A setting that is in neither is not reachable by `--set`, the config file or the API.

`label` is what a person reads; the **storage key** is the identity everywhere else — in the
config file, in `--set`, in the API, in the logs, and in a service's permissions list.
`Settings.label(forKey:)` exists for exactly one job: naming the setting someone has just edited
in the restart notice.

## Step 3: `requires:` — for a row that would otherwise look live

```swift
presentation: .init(…, requires: enableFaceTimePrivateAPI.key)
```

The generated page greys the row out and names the switch to turn on, so no screen has to know
the group by name. It fixes one failure precisely: somebody turning "Incoming call hand-off" on
with the FaceTime Private API off, watching the switch move, and concluding hand-off is broken.

- **Presentation only.** It does not gate reads or writes, deliberately: the server already
  treats these as unreachable when the parent is off, and making the store refuse would break
  `--set` on a config being assembled before the switch it depends on.
- It must name a **renderable `Setting<Bool>`** — a parent the user cannot see is a dead end.
- **Chains are allowed and cycles are not.** `auto_install_hour` is two links, and
  `Settings.requirementChain` walks the chain whole, nearest first: reading only the immediate
  parent draws the hour live while the switch above it is greyed out. The row names the
  **outermost switch that is off**, because the ones under it are greyed out too.
- `SettingDependencyTests` enforces every line of that, and pins the two settings that look like
  dependencies and are not.

## Step 4: when does the change take effect?

```swift
application: .composition
```

`.live` (the default) means read live, or read by a service that restarts itself on the change.
`.composition` means it is read once while the server is assembled — which routes mount, which
codec the socket negotiates, how `chat.db` is opened — so a change needs a full restart and the
propagation layer **says so rather than pretending to apply it**. Declared on the setting so the
list of restart-to-apply keys cannot drift from the declarations.

## Step 5: never spell the key again

`Settings.x.key` is the only spelling a service, a manifest, a view or a test should use.
`SettingKeyLiteralTests` scans the tree and fails the build on a literal, because a renamed
setting otherwise silently stops being watched, declared or read, and nothing fails until a
person notices a switch has no effect.

## Step 6: if a service reads it

Add the key to that service's `readSettings` entitlement in its manifest. **An undeclared read
throws** — `ScopedSettings` never returns nil for one, because a nil is indistinguishable from
"unset". There is no trusted tier; a built-in is checked exactly like a plugin.

Two consequences worth knowing before you add the entitlement:

- **A service can never declare a secret.** `checkRead` refuses it before it considers
  entitlements, and `ManifestValidator` refuses the manifest. A service that needs a credential
  checked takes `.authenticateRequests` and asks the host to do the comparison.
- **Declaring a read is declaring a restart trigger.** `watchedSettingKeys` is the service's own
  form fields plus its `readSettings`, minus its `writeSettings` — so a key you add here will
  restart that service on every change unless it decides otherwise. If some other service writes
  this key routinely, that is the two-hop restart loop that respawned cloudflared twenty times a
  second; see `HTTPService.liveKeys` and the `add-a-service` skill.

## Step 7: test

```bash
swift test --filter BBSettingsTests           # registry, store, dependencies, key literals
swift test --filter CompositionTests          # manifests and whatever watches the key
```

Then the five: `swift build`, the strict build, the lint,
`python3 Tools/package-graph/check.py`, `swift test`.

Try it end to end where it matters — the layering over is never persisted, so it is safe:

```bash
swift run bluebubbles-server --headless --set my_new_key=value
```

## Gotchas

| Symptom | Cause |
|---|---|
| A user's existing value vanished after an update | The key was renamed. The old row is still there under the old name |
| The switch moves and nothing happens | Either the reader needs `requires:` on its row, or the service watching it never started |
| A service throws on a read that obviously exists | The key is not in its `readSettings`, or it is secret and therefore undeclarable |
| Adding a read restarts a service constantly | `watchedSettingKeys` now includes it; decide per key, as `HTTPService.liveKeys` does |
| The change appears applied and is not | It is read at composition. Declare `application: .composition` so the notice is honest |
| A value shows up in a log or a diagnostic | It is not declared `isSecret`, and redaction is derived from that flag |
| `SettingKeyLiteralTests` fails | A key is spelled as a string outside the registry |
| The row is greyed out with nowhere to go | `requires:` names a hidden or internal setting |
