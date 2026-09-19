---
name: verify-a-claim
description: Check whether something this repository asserts is actually true and actually enforced. Use when auditing or reviewing the codebase, when a comment, header, CLAUDE.md line or doc page states a rule and you need to know whether anything holds it, when citing what the Node reference does, or before acting on "this is handled" / "this is covered" / "the class is gone". Covers wire-versus-internal claims, finding the enforcement, breaking it on purpose, tests that mirror their implementation, and the dialects of "I could not check this".
---

# Verifying a claim

**A claim is verified when you can name the thing that would fail if it stopped being true.**
Not before. Confident prose with nothing behind it is the failure mode this repository spends
the most effort on, and it has produced both wrong documentation and wrong code.

The worked cases are in [`.claude/docs/decisions.md`](../../docs/decisions.md) §4b, §4e and
§4f — read them when you want evidence that a shape below is real. They are not repeated here:
a retelling rots and the record does not.

## Step 1: is the claim about the wire, or about an internal?

This decides what evidence counts.

| The claim is about | Verify against |
|---|---|
| A status code, envelope key, error string, payload shape, route, parameter | `electron/packages/server/src/…` **and** its `validators/*.ts`, or a recorded fixture |
| Anything a client cannot observe | The merits, in this repository |

Two rules follow:

- **Read the validators as well as the routers.** A router that destructures a parameter without
  checking it may sit behind a validator that requires it. The routers are half the contract.
- **The reference does not constrain internals.** Ask whether the claim needs to be true before
  asking whether it is: every reference claim found false in this repository was an appeal about
  an internal, never about the wire, because the wire is diffed and prose is not. If a client
  cannot observe it, the citation should not be there at all.

## Step 2: find the enforcement, not the statement

Go and find the line that makes the claim true. Four questions, in order:

1. **Who calls it?** A function that is correct and unreached is not a guard.
2. **What fails if I delete it?** Step 3.
3. **Is the thing that checks it a copy of the thing it checks?** Step 4.
4. **Could the checker have answered "I do not know"?** Step 5.

A rule the compiler cannot check ships with a test that scans the source for it; the set CLAUDE.md
lists is the pattern, and `DocumentationDriftTests` keeps that list honest. **A "never" with no
scanning test behind it is an unverified claim by construction**, and finding one is a finding.

## Step 3: break it on purpose

The only direct evidence that a guard is load-bearing is watching something fail without it.
Delete it, invert it, or point it at the wrong input; run the suite; put it back.

Do this to the check as well as to the code. A source scan that finds nothing passes while
looking exactly like full coverage, which is why the policy tests assert a minimum hit count —
and why a coverage ratchet is verified by pointing one entry at a missing fixture and watching
the rest still run.

If nothing fails, you have found the defect rather than proved the claim.

## Step 4: a test that mirrors its implementation proves nothing

A test that defines its own copy of the rule asserts nothing about the code that ships. Two
markers, both of which pass as loudly as the real thing:

- **The test restates the logic.** `SendTextRequiredFieldTests` is the case;
  `WriteHandlers.sendTextFields` and `HTTPService.reloadAction(for:)` are the fix — the rule
  becomes one pure static that the route calls and the test asserts.
- **The test builds the world it then asserts on.** A fixture written by the test, in the shape
  the test expects, is code and test agreeing about a world neither has checked. Drive the real
  thing — a real `chat.db`, the real repository — when that is what ships.

And check *why* a negative test passes. A refusal for the wrong reason is still a refusal, so
assert the specific failure, not merely that something threw.

Ask of every green test: **what world is this asserting about, and is it the one we ship into?**

## Step 5: "I could not check this" is never agreement

Every checking tool here has a vocabulary for it. Each means unverified, which is a different
finding from false, and is written up as such:

| Tool | Says | Means |
|---|---|---|
| `ResponseDiff` | `.notCompared` | one side's array was empty, so the elements were never compared |
| `compare-releases.py` | `UNCOMPARABLE` | the class has no header on one side |
| `docs/MACOS_COMPATIBILITY.md` | `?` | no header for that class in that dump. Nobody asked |
| `NSClassFromString` | `nil` | not loaded **in this process**. Cross-check the committed dumps |
| A source scan | zero hits | the scanner may have stopped matching. Check its hit count |

## Step 6: a ratchet entry is a claim, not a fact

`docs/api/uncovered-routes.txt`, `knowinglyDivergent`, `knowinglyInert`, `acceptedDifferences`,
`readOutsideTheHandler`, and the coverage ratchets are each a sentence someone wrote asserting
that something is deliberate. Verify the entry, not the list's existence: an entry naming a
suite is a claim that the suite covers that case, and it can be false while the list looks
complete.

## Step 7: what a finding is worth, and where it goes

- **An inverted claim is the expensive kind**, because a live guard documented as decoration is
  one someone deletes. Separate the true half from the false one rather than deleting the
  sentence.
- **A literal in a serializer is invisible to a diff that compares keys and types.** A constant
  in a response either IS the contract, with a citation, or it is a stub that needs a test
  asserting the real value. A parameter no call site passes is the same defect with a signature.
- **A fallback that has never been observed to fire is not defence in depth**: it is a second
  thing to keep working and a third place for a reader to look.
- Fix the code when it is code. When it is prose, correct it where it is written and put the
  history in `decisions.md`, not above the declaration — a narrative rots the moment the
  declaration changes.
- **When you add a "never", add the test that enforces it in the same change.** Otherwise you
  have written the next unverified claim.
- **Cite what is pinned, not what you measured once.** A count, a size or a test total in prose
  is itself an unverified claim unless something checks it; prefer naming the artifact a reader
  can go and read.

## Shapes that look verified and are not

| Shape | Why it passes anyway |
|---|---|
| A test whose fixture it also wrote | Code and test agreeing about a world neither has checked |
| A test asserting a refusal, with none asserting acceptance still works | Deleting the feature outright passes it |
| A negative test passing on the wrong error | A refusal, but not the refusal under test |
| A comment citing the reference for an internal | Unfalsifiable by the parity harness |
| A fallback never observed to fire | Nothing distinguishes "never needed" from "never worked" |
| A capability, ratchet or coverage entry | A hand-written claim that a named thing covers a named case |
| A scan with no minimum hit count | Finds nothing, reports success |
