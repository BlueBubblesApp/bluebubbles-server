#!/usr/bin/env python3
"""Extract the Node server's per-route validation rules into a fixture the parity tests diff.

The reference runs validatorjs rule sets per route (`validators/*.ts`, attached in
`httpRoutes.ts`), and a violation is a 400 whose `error.message` is the generated sentence.
`Sources/BBHTTPAPI/ValidationRules.swift` is a transcription of those rule sets, and a
transcription rots: a rule added or reordered upstream is invisible here until a client is
refused something it should be allowed, or allowed something it should be refused.

So the rules are generated from the reference and committed, and `ValidationRuleParityTests`
diffs the Swift table against this file. Run it whenever the Node validators change:

    python3 swift/Tools/validation-rules/extract.py

Writes swift/Tests/CompatibilityTests/Fixtures/node-validation-rules.json.

WHAT IS AND IS NOT CAPTURED
Only the DECLARATIVE rule sets — the `static <name>Rules = {...}` objects fed to
`ValidateInput`. The bespoke checks around them (the `parts` walk in `validateMultipart`, the
send-method implications in `validateText`, every `ContactValidator` method) are handler logic
and live in the handlers on the Swift side too; a scanner cannot read them and should not try.

FIELD ORDER IS PRESERVED AND IS PART OF THE CONTRACT. Only the first failure is reported
(`validators/index.ts:getFirstError`), taken in declaration order, so a reordering changes
which sentence a client is shown. The fixture is a list of pairs, never a dict.

Deliberately a regex scanner, for the same reason as `Tools/route-table/extract.py`: these are
flat object literals, and requiring a Node toolchain would put this out of reach of a
Swift-only CI job. It asserts its own yield below and fails loudly rather than under-reporting.
"""

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
VALIDATORS = REPO_ROOT / "packages/server/src/server/api/http/api/v1/validators"
ROUTES = REPO_ROOT / "packages/server/src/server/api/http/api/v1/httpRoutes.ts"
INTERFACES = REPO_ROOT / "packages/server/src/server/api/interfaces/messageInterface.ts"
DESTINATION = (
    REPO_ROOT / "swift/Tests/CompatibilityTests/Fixtures/node-validation-rules.json"
)

# Measured from the current reference. A yield below these means the scanner stopped
# matching something it used to match, which is the failure mode a silent regex has.
MINIMUM_RULE_SETS = 31
MINIMUM_VALIDATED_ROUTES = 40


def possible_reactions() -> list[str]:
    """`in:${MessageInterface.possibleReactions.join(",")}` is the one interpolated rule."""
    source = INTERFACES.read_text()
    block = re.search(r"possibleReactions:\s*string\[\]\s*=\s*\[(.*?)\]", source, re.S)
    if not block:
        sys.exit("could not read possibleReactions from messageInterface.ts")
    return re.findall(r'"([^"]+)"', block.group(1))


def rule_sets(reactions: list[str]) -> dict[str, list[list]]:
    """Every `static <name> = { field: "rules" }` in the validator directory."""
    sets: dict[str, list[list]] = {}
    for path in sorted(VALIDATORS.glob("*.ts")):
        if path.name == "index.ts":
            continue
        source = path.read_text()
        for match in re.finditer(r"static (\w+)\s*=\s*\{(.*?)\n    \};", source, re.S):
            name, body = match.group(1), match.group(2)
            if "Rules" not in name and name != "rules":
                continue
            fields = []
            for field in re.finditer(
                r'\n\s*"?([\w.*]+)"?\s*:\s*([`"\'])(.*?)\2', body
            ):
                spec = field.group(3)
                # The single interpolated rule string in the whole surface.
                spec = spec.replace(
                    '${MessageInterface.possibleReactions.join(",")}', ",".join(reactions)
                )
                fields.append([field.group(1), spec.split("|")])
            if fields:
                sets[f"{path.stem}.{name}"] = fields
    return sets


def validated_routes() -> list[dict]:
    """Which route each validator is attached to, in `httpRoutes.ts` order."""
    source = ROUTES.read_text().split("\n")
    found, method, path = [], None, None
    for line in source:
        if m := re.search(r"method:\s*HttpMethod\.(\w+)", line):
            method, path = m.group(1), None
        if p := re.search(r'path:\s*"([^"]*)"', line):
            if method:
                path = p.group(1)
        if v := re.search(r"(\w+Validator)\.(\w+)", line):
            if method is not None:
                found.append(
                    {
                        "method": method,
                        "path": path or "",
                        "validator": v.group(1),
                        "method_name": v.group(2),
                    }
                )
                method = None
    return found


def main() -> None:
    for required in (VALIDATORS, ROUTES, INTERFACES):
        if not required.exists():
            sys.exit(f"missing reference source: {required}")

    reactions = possible_reactions()
    sets = rule_sets(reactions)
    routes = validated_routes()

    if len(sets) < MINIMUM_RULE_SETS:
        sys.exit(
            f"only {len(sets)} rule sets found, expected at least {MINIMUM_RULE_SETS}. "
            "The scanner has stopped matching; fix it rather than lowering the floor."
        )
    if len(routes) < MINIMUM_VALIDATED_ROUTES:
        sys.exit(
            f"only {len(routes)} validated routes found, expected at least "
            f"{MINIMUM_VALIDATED_ROUTES}. The scanner has stopped matching."
        )

    document = {
        "_comment": (
            "Generated by swift/Tools/validation-rules/extract.py from the Node server's "
            "validators. Field order is the contract: only the first failure is reported, "
            "in declaration order. Do not hand-edit; re-run the extractor."
        ),
        "reactions": reactions,
        "ruleSets": sets,
        "routes": routes,
    }
    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    DESTINATION.write_text(json.dumps(document, indent=2) + "\n")
    print(
        f"Wrote {DESTINATION.relative_to(REPO_ROOT)}: "
        f"{len(sets)} rule sets, {len(routes)} validated routes."
    )


if __name__ == "__main__":
    main()
