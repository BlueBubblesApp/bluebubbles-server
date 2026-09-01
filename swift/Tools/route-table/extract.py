#!/usr/bin/env python3
"""Extract the Node server's route table into a fixture the parity tests diff against.

The compatibility contract's hardest rule is that a default-configured Swift server exposes
exactly the endpoints the Node server exposes — no more, no less. Verifying that needs ground
truth, and a hand-written list of ~100 routes would be wrong within a week.

So the fixture is generated from httpRoutes.ts. Run this whenever the Node table changes; the
parity test fails loudly if the two drift, which is the point.

    python3 swift/Tools/route-table/extract.py

Writes swift/Tests/CompatibilityTests/Fixtures/node-route-table.json.

Deliberately a regex scanner rather than a TypeScript parser: the table is a flat literal with
a fixed shape, and requiring a Node toolchain to run this would put it out of reach in CI jobs
that only install Swift. If httpRoutes.ts ever stops being a flat literal, this needs to
become a real parse — it will fail loudly rather than silently under-report, because the route
count is asserted below.
"""

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
SOURCE = REPO_ROOT / "packages/server/src/server/api/http/api/v1/httpRoutes.ts"
DESTINATION = REPO_ROOT / "swift/Tests/CompatibilityTests/Fixtures/node-route-table.json"

# Below this, the extraction has silently broken rather than the table having shrunk.
MINIMUM_EXPECTED_ROUTES = 90

NAME = re.compile(r'^name:\s*"[^"]*",?$')
PREFIX = re.compile(r'^prefix:\s*"([^"]*)",?$')
METHOD = re.compile(r"^method:\s*HttpMethod\.(\w+),?$")
PATH = re.compile(r'^path:\s*"([^"]*)",?$')


def extract(text: str) -> list[dict]:
    lines = text.splitlines()

    # Only the `api` definition. The `ui` definition below it serves the bundled web UI at
    # the root, which is not part of the client contract.
    start = next(i for i, line in enumerate(lines) if "static api: HttpDefinition" in line)
    end = next(i for i, line in enumerate(lines) if "static ui: HttpDefinition" in line)

    routes = []
    prefix = ""
    pending_method = None

    for line in lines[start:end]:
        stripped = line.strip()

        # A group's `name` always precedes its optional `prefix`, so resetting here is what
        # keeps a prefix-less group (General) from inheriting the previous group's prefix.
        if NAME.match(stripped):
            prefix = ""
            continue

        match = PREFIX.match(stripped)
        if match:
            prefix = match.group(1)
            continue

        match = METHOD.match(stripped)
        if match:
            pending_method = match.group(1)
            continue

        match = PATH.match(stripped)
        if match and pending_method:
            components = [c for c in ["api", "v1", prefix, match.group(1)] if c]
            routes.append({"method": pending_method, "path": "/" + "/".join(components)})
            pending_method = None

    return routes


def main() -> int:
    if not SOURCE.exists():
        print(f"Cannot find {SOURCE}", file=sys.stderr)
        return 1

    routes = extract(SOURCE.read_text())

    if len(routes) < MINIMUM_EXPECTED_ROUTES:
        print(
            f"Only extracted {len(routes)} routes, expected at least "
            f"{MINIMUM_EXPECTED_ROUTES}. httpRoutes.ts has probably changed shape — fix this "
            f"script rather than lowering the floor.",
            file=sys.stderr,
        )
        return 1

    # Duplicate (method, path) pairs would make the parity set comparison lie about coverage.
    seen = set()
    for route in routes:
        key = (route["method"], route["path"])
        if key in seen:
            print(f"Duplicate route in the Node table: {key}", file=sys.stderr)
            return 1
        seen.add(key)

    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    DESTINATION.write_text(json.dumps(routes, indent=2) + "\n")
    print(f"Wrote {len(routes)} routes to {DESTINATION.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
