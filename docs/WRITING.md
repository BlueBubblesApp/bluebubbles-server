# Writing

How documentation in this repository is written: every `CLAUDE.md`, every file header, every
page under `docs/` and `.claude/docs/`, every skill, and every comment long enough to make an
argument. It applies to agents and to people equally.

Naming — identifiers, keys, columns, spelling — is [`NAMING.md`](NAMING.md). This page is about
prose.

## Precedence

Three tiers, in this order. The first tier that answers a question wins.

1. **This file and [`NAMING.md`](NAMING.md).**
2. **The [Google developer documentation style guide](https://developers.google.com/style).**
   Everything below that is not marked as a deviation is taken from it.
3. **Merriam-Webster, the Chicago Manual of Style, the Microsoft Writing Style Guide**, which
   are what Google defers to.

That order is Google's own: it puts project-specific style above itself and says to depart from
it when departing improves the content. The deviations this repository takes are listed at the
end, with the reason for each. A deviation that is not listed there is a mistake, not a licence.

## First, what kind of document is this?

Length and register follow from the answer, and most disagreements about a document are really
disagreements about which row it is in.

| Kind | Job | Length |
|---|---|---|
| Source file header | The decision this file embodies, and the failure it prevents | 10–25 lines |
| Declaration comment (`///`) | What this type or member is for, and what a caller must know | 1–10 lines |
| Nested `CLAUDE.md` | The rules for editing one module, for someone already inside it | Under 500 lines |
| `CLAUDE.md` | A router. Only what every task needs; everything else is a link | Under 400 lines |
| `.claude/docs/*.md` | One subsystem, in the depth a task needs before editing it | 200–1,100 lines |
| `docs/*.md` | Reference: measured facts, matrices, per-release detail | No ceiling; write for grep |
| `.claude/docs/decisions.md` | Why something is the way it is, and what history explains it | Append a section |
| `.claude/skills/*/SKILL.md` | The order to do a multi-step job in, and what goes wrong | 100–250 lines |

Two consequences worth stating plainly. A reference page is allowed to be long, but it is read
by section, so every section has to stand alone. A router is not allowed to be long, and the
fix for a router that has grown is a link, never a smaller font.

## The rules that outrank style

These are about what a document may claim. They are not negotiable, and no amount of good prose
substitutes for them.

1. **Cite it or find out.** Every statement about the reference server's behaviour traces to
   `electron/packages/server/src/…` or to a recorded fixture, in the sentence that makes it. Every
   statement about this server traces to the code. The procedure is the `verify-a-claim` skill.
2. **State the decision and the failure it prevents. Do not narrate history.** What the code
   used to do belongs in git and in [`.claude/docs/decisions.md`](../.claude/docs/decisions.md).
   A narrative above a declaration rots the moment the declaration changes.
3. **Write timelessly.** No `currently`, `now`, `new`, `newer`, `old`, `latest`, `soon`,
   `eventually`, `as of this writing`, `does not yet`. Write "the emulator supports these
   filters", not "the emulator now supports these filters". Release notes and
   `decisions.md` are the exceptions, and there a date or a version is required, not optional.
4. **A number in prose is a claim.** A count, a size, a test total, a percentage: pin it with a
   test, or name the artifact a reader can go and count instead. `DocumentationDriftTests` is
   where the pinned ones live.
5. **A "never" ships with the test that enforces it**, in the same change.
6. **Say what was measured, and under what conditions.** "Measured on macOS 26.5.2" is a fact.
   "Should work" is not a claim anyone can check.

## Voice

- **Second person.** Address the reader as `you`. Use the imperative for instructions: "Run the
  probe", not "The probe should be run" and not "We then run the probe".
- **Name the actor instead of writing `we`.** This repository has several, and which one is
  meant is usually the point: *this server*, *the reference*, *the helper*, *the client*, *the
  registry*. `we` blurs exactly the distinction the sentence exists to make.
- **Active voice.** Make it clear what performs the action. Passive is allowed when the actor is
  genuinely unknown or irrelevant.
- **Present tense.** "The server sends an acknowledgment." Use the future only for something
  that genuinely happens later: "The file is archived the next time the backup runs."
- **No condescension.** Cut `simply`, `just`, `easy`, `obvious`, `of course`, `quickly`. If a
  step is easy, saying so adds nothing; if it is not, saying so is an insult with a footnote.
- **No `please`, no exclamation marks, no jokes, no idiom, no pop culture.** Not because the
  tone would be wrong, but because they do not survive translation or a reader skimming under
  pressure.
- **One idea per sentence.** A sentence that needs two independent clauses to state a rule is
  two sentences. This is the rule most often broken here, and it is the one that costs the most
  when a document is read in a hurry.
- Contractions are fine and are preferred for negatives: `don't` is harder to skim past than
  `do not`.

## Structure

- **Sentence case** for every heading and title.
- **Headings are descriptive and unique.** Prefer a noun phrase ("Chat GUIDs are not stable") or
  a bare infinitive ("Add a route") over an `-ing` form. Do not number them for sequence; the
  hierarchy is the sequence.
- **One `h1` per document**, and no skipped levels. Never stack two headings with nothing
  between them.
- **Put conditions before instructions.** "If the helper is not connected, run the probe", not
  "Run the probe if the helper is not connected."
- **Lists.** Numbered for a sequence, bulleted otherwise. Introduce one with a complete
  sentence. Keep items grammatically parallel. Never use a list for a single item.
- **Tables for lookup and for decisions**, which is the shape most of this repository's hard-won
  knowledge takes: symptom to cause, claim to verdict, state to fix. A table with one row is a
  sentence.
- **The failure comes last in the paragraph, not first.** State the rule, then what breaks
  without it. A paragraph that opens with the anecdote makes the reader hold it until the rule
  arrives.

## Formatting

**Code font** (`` ` ``) for anything typed verbatim or named in code: identifiers, type and
member names, filenames and paths, settings keys, wire keys, selectors, environment variables,
CLI commands and flags, HTTP status codes and methods, placeholders. Not for product names,
service names, domain names, or URLs.

Do not inflect a code item or use one as a verb. Write "send a `POST` request", not "`POST` the
data"; write "the `get` method", not "`get`s the value".

**Bold** for the load-bearing clause of a paragraph, as a run-in heading: the sentence a reader
who reads nothing else must come away with. One per paragraph. This is a deliberate deviation;
see below.

**Uppercase** for contrast, where the contrast is the point and a reader skimming would
otherwise invert the meaning: a MISSING field against an extra one, what a rule does NOT cover.
One or two words, never a clause, and never twice in a paragraph. Also a deliberate deviation.

*Italics* only for defining a term on first use, or for a mathematical or version variable.
Never for emphasis, which is what the bold run-in is for.

Em dashes are fine in prose. Commit messages use `--` instead; see
[`CONTRIBUTING.md`](../CONTRIBUTING.md).

**Links** carry descriptive text that makes sense out of context. Never "click here", "this
page", or a bare URL. Link to a repository path relative to the linking file, so it resolves on
GitHub and in an editor. For a standalone cross-reference, write "For more information, see
[`AUTH.md`](AUTH.md)."

## Words

- **British spelling**, in prose and in identifiers we own. Apple's API names keep theirs. See
  [`NAMING.md`](NAMING.md#spelling).
- **No Latin abbreviations.** Write "for example" for *e.g.*, "that is" for *i.e.*, and "and so
  on" for *etc.*, or rewrite the sentence so it needs none.
- **Expand an abbreviation on first use in a document**, except for ones every reader of this
  repository already holds: API, HTTP, JSON, SQL, URL, UI, CLI, TLS, GUID, and this project's
  own vocabulary (the Private API, the helper, the reference, a rung, a ladder, a ratchet).
- **Inclusive terms.** Allowlist and blocklist, which is already what the access-control code
  and its settings are called. Controller and replica, or parent and child. "Final check" rather
  than "sanity check"; "placeholder" rather than "dummy". No ableist figures of speech: `crazy`,
  `insane`, `blind to`, `cripple`. A third-party API name that uses another term is not ours to
  rename — `sqlite_master` stays `sqlite_master`.

## Deliberate deviations from Google

Each of these is a considered departure, kept because it earns its place here.

| Deviation | Why |
|---|---|
| **British spelling**, not American | The codebase's identifiers are British and prose that disagreed with them would read as two voices. `NAMING.md` has held this from the start |
| **Bold for the load-bearing clause**, not only for UI elements | These documents are read by someone mid-task who will skim. The bolded clause is functionally a run-in heading, which Google does permit; the deviation is how often one appears |
| **Uppercase for contrast** | Reserved for the handful of places where a skimming reader would otherwise read the opposite of what is meant. Constrained above rather than banned |
| **Long-form argued prose in reference pages** | The expensive mistakes here came from rules that were stated without their reasons and then "cleaned up" by someone who could not see what they held. The reason is the load-bearing part |
| **No admonition blocks** (Note, Caution, Warning) | Nothing renders them consistently across a terminal, GitHub and an editor. The underlying rule still holds: never put something a reader needs in an aside, and never stack asides |
| **Second person is relaxed in file headers** | A header addresses no one; it describes a decision. Instructions still take the imperative |

## What a test checks, and what it cannot

`DocumentationStyleTests` scans both corpora — every document above, and the comments in every
Swift file — for the three groups that need no judgement: time-anchored words, Latin
abbreviations, and non-inclusive terms. It reports a file and a line. Code is exempt: fenced
blocks, inline spans and lines of Swift are stripped or skipped before a line is read.

Everything else here is yours to hold. A scan cannot tell a run-in heading from shouting, an
argued paragraph from a war story, or a citation from a guess, and a scanner that tried would be
switched off within a week.

## Before you commit a document

- Every claim about the reference or about behaviour has something behind it, named in the
  sentence that makes it.
- No time-anchored words, and no number that nothing pins.
- Every heading is sentence case, descriptive, and in a hierarchy with no gaps.
- Code font is on every identifier, path, key and flag; off every product and domain name.
- One bolded clause per paragraph, at most.
- The document is in the right row of the table at the top, and is the length that row allows.
- If you added a "never", you added the test that enforces it.
