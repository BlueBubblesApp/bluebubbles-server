# AGENTS.md

This repository's agent instructions live in **[`CLAUDE.md`](CLAUDE.md)**.

Read it first. It is a router: it carries the six rules that apply to every change and then points
to the topic document that matches your task.

| | |
|---|---|
| Entry point | [`CLAUDE.md`](CLAUDE.md) |
| Architecture | [`.claude/docs/architecture.md`](.claude/docs/architecture.md) |
| Databases | [`.claude/docs/database.md`](.claude/docs/database.md) |
| HTTP + socket API | [`.claude/docs/api.md`](.claude/docs/api.md) |
| iMessage domain: GUIDs, typedstream, sending | [`.claude/docs/imessage.md`](.claude/docs/imessage.md) |
| Private API: injection, sandbox, selectors | [`.claude/docs/private-api.md`](.claude/docs/private-api.md) |
| Memory, processes, async traps | [`.claude/docs/performance.md`](.claude/docs/performance.md) |
| Decisions and constraints | [`.claude/docs/decisions.md`](.claude/docs/decisions.md) |
| Build, run, test, CI | [`.claude/docs/workflow.md`](.claude/docs/workflow.md) |
| Events, sinks, payload codecs | [`docs/EVENTS.md`](docs/EVENTS.md) |
| Auth, access control, permissions | [`docs/AUTH.md`](docs/AUTH.md) |
| What the tests assert and why | [`docs/TESTING.md`](docs/TESTING.md) |
| Naming: DB columns, settings keys, wire keys, spelling | [`docs/NAMING.md`](docs/NAMING.md) |
| Writing any documentation, and what a document may claim | [`docs/WRITING.md`](docs/WRITING.md) |
| What works on which macOS, and what needs a guard | [`docs/MACOS_COMPATIBILITY.md`](docs/MACOS_COMPATIBILITY.md) |

## Skills

Six packaged workflows in `.claude/skills/`, for the multi-step jobs where doing the steps out of
order breaks client compatibility or the build:

- **`add-api-route`**: adding, changing or removing an endpoint; a failing route-table,
  request-parameter, parity or OpenAPI check.
- **`implement-imcore-method`**: implementing a `notImplemented` helper stub, adding an IMCore
  call or inbound event, chasing a selector that vanished on a new macOS.
- **`add-a-service`**: a new subsystem with a lifecycle — its manifest, entitlements,
  permissions, managed tools, watched keys and wiring into the composition root.
- **`add-a-setting`**: declaring a setting, giving it a row, marking it secret, making it depend
  on a switch, letting a service read it.
- **`macos-release-sweep`**: a new macOS or beta — dumping headers, deciding guard against
  ladder, and bringing the capability catalog and the compatibility matrix up to date.
- **`verify-a-claim`**: auditing or reviewing; checking whether a comment, header or doc line is
  true **and** enforced; citing what the Node reference actually does.

Each is a `SKILL.md` with YAML frontmatter. If your tooling does not support skills, read the file
directly; it is a checklist. `DocumentationDriftTests` fails the build when this list and
`CLAUDE.md`'s table stop matching the directory.

## Directory-local instructions

Additional `CLAUDE.md` files sit in `Sources/BBInterfaces/`, `Sources/BBHandlers/`,
`Sources/BlueBubblesServerCore/`, `Sources/BBPersistence/`, `Sources/BlueBubblesApp/` and
`Helper/`. If your tooling does not automatically load nested instruction files, read the ones
covering the directories you are about to edit.

## One warning

Source-file headers are the primary documentation here and are usually right, but where any
document disagrees with the code, **the code wins**; say so rather than propagating the doc.
