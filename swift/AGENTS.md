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
| iMessage domain — GUIDs, typedstream, sending | [`.claude/docs/imessage.md`](.claude/docs/imessage.md) |
| Private API — injection, sandbox, selectors | [`.claude/docs/private-api.md`](.claude/docs/private-api.md) |
| Memory, processes, async traps | [`.claude/docs/performance.md`](.claude/docs/performance.md) |
| Decisions and constraints | [`.claude/docs/decisions.md`](.claude/docs/decisions.md) |
| Build, run, test, CI | [`.claude/docs/workflow.md`](.claude/docs/workflow.md) |
| Events, sinks, payload codecs | [`docs/EVENTS.md`](docs/EVENTS.md) |
| Auth, access control, permissions | [`docs/AUTH.md`](docs/AUTH.md) |
| What the tests assert and why | [`docs/TESTING.md`](docs/TESTING.md) |

## Skills

Two packaged workflows in `.claude/skills/`, for the multi-step jobs where doing the steps out of
order breaks client compatibility or the build:

- **`add-api-route`** — adding, changing or removing an endpoint; a failing route-table, parity or
  OpenAPI check.
- **`implement-imcore-method`** — implementing a `notImplemented` helper stub, adding an IMCore
  call or inbound event, chasing a selector that vanished on a new macOS.

Each is a `SKILL.md` with YAML frontmatter. If your tooling does not support skills, read the file
directly — it is a checklist.

## Directory-local instructions

Additional `CLAUDE.md` files sit in `Sources/BBInterfaces/`, `Sources/BBHandlers/`,
`Sources/BlueBubblesServerCore/`, `Sources/BBPersistence/` and `Helper/`. If your tooling does not automatically load nested instruction files, read the ones
covering the directories you are about to edit.

## One warning

Source-file headers are the primary documentation here and are usually right, but where any
document disagrees with the code, **the code wins** — say so rather than propagating the doc.
