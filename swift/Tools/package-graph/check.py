#!/usr/bin/env python3
"""Verify that Package.swift describes the module graph the code actually has.

Why this exists
---------------
``Package.swift`` is the only thing enforcing layering in this repository. Its comments
explain why each edge exists — why BBHTTPAPI is allowed to know about serialization and not
about chat.db, why the injected helper links the contract and nothing else. Those comments
are only true if the manifest matches the ``import`` statements, and nothing was checking
that.

It had drifted in both directions:

* **Declared but never imported.** A dead edge is worse than no edge, because it silently
  widens what a target is *allowed* to import. BBHTTPAPI declared BBIMessage, BBContacts,
  BBPrivateAPI, BBAppleScript, BBEvents and BBServiceKit while importing none of them — so
  nothing stopped someone pulling chat.db into the HTTP layer, and the header claiming
  otherwise was describing intent rather than fact.

* **Imported but never declared.** These compile today only because some *other* target
  happens to pull the module in transitively. BBSettings imported GRDB without declaring it,
  so dropping GRDB from BBPersistence would have broken BBSettings for a reason nothing in
  its manifest entry hinted at.

Both are invisible to the compiler and to ``swift build``. This is the check that makes them
visible.

What it does NOT do
-------------------
It does not police *which* edges are allowed — that is a design question, and the answer
lives in the manifest's comments. It only asserts that the declared set and the imported set
are the same set.

Usage
-----
    python3 Tools/package-graph/check.py            # report drift, exit 1 if any
    python3 Tools/package-graph/check.py --self-test # exercise the import scanner
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Modules that ship with the platform or the toolchain. Importing one needs no manifest
# entry, so they are excluded from both directions of the comparison.
#
# An explicit list rather than a heuristic, and the script FAILS on an unrecognised module
# instead of assuming it is a system one. That is the fail-closed direction: a genuinely
# undeclared package dependency must not be waved through because it looked SDK-ish.
SDK_MODULES = {
    "AVFoundation", "AppKit", "Carbon", "Contacts", "CoreGraphics", "CoreLocation",
    "CoreServices", "Darwin", "Dispatch", "Foundation", "FoundationNetworking", "IOKit",
    "ImageIO", "ObjectiveC", "Observation", "Security", "ServiceManagement", "SwiftUI",
    "Testing", "UniformTypeIdentifiers", "UserNotifications", "WebKit", "fcntl", "os",
}

# Targets that are LINKED but never imported, with the reason. A C target whose only job is
# to run a constructor exports no Swift module, so "declared but not imported" is its normal
# and correct state.
LINK_ONLY = {
    "HelperBootstrap":
        "four lines of C providing the dylib constructor; nothing to import",
    "HelperBootstrapFaceTime":
        "the FaceTime dylib's constructor, same shape as HelperBootstrap",
}


def dump_package() -> dict:
    return json.loads(
        subprocess.check_output(["swift", "package", "dump-package"], cwd=REPO_ROOT)
    )


def target_path(target: dict) -> str:
    """Where a target's sources live, applying SwiftPM's defaults."""
    if target.get("path"):
        return os.path.join(REPO_ROOT, target["path"])
    root = "Tests" if target["type"] == "test" else "Sources"
    return os.path.join(REPO_ROOT, root, target["name"])


def declared_dependencies(target: dict) -> set[str]:
    """The module names a target's manifest entry says it may import.

    Every external product in this graph vends a module of the same name, which is asserted
    below rather than assumed — see `verify_product_naming`.
    """
    names: set[str] = set()
    for dependency in target["dependencies"]:
        if "byName" in dependency and dependency["byName"][0]:
            names.add(dependency["byName"][0])
        elif "target" in dependency and dependency["target"][0]:
            names.add(dependency["target"][0])
        elif "product" in dependency and dependency["product"][0]:
            names.add(dependency["product"][0])
    return names


IMPORT = re.compile(
    r"""^\s*
        (?:@[\w()]+\s+)?                                    # @_exported, @testable
        import\s+
        (?:struct|class|enum|protocol|func|typealias|var|let)?\s*
        ([A-Za-z_][A-Za-z0-9_]*)                            # the module
    """,
    re.VERBOSE,
)
CONDITION_START = re.compile(r"^\s*#(if|elseif)\s+(.*)$")
CONDITION_ELSE = re.compile(r"^\s*#else\b")
CONDITION_END = re.compile(r"^\s*#endif\b")


def imports_in_file(path: str) -> set[str]:
    """Every module a file imports unconditionally.

    An import guarded by `#if canImport(X)` is skipped: that is the idiom for a module which
    may not exist on the platform being compiled for, and requiring a manifest entry for one
    would be requiring a dependency that cannot be satisfied. `BBEvents` imports
    `FoundationNetworking` this way. Any OTHER condition — `#if DEBUG` most of all — still
    requires a declaration, because that import does have to resolve somewhere.
    """
    found: set[str] = set()
    conditions: list[str] = []
    with open(path, errors="ignore") as handle:
        for line in handle:
            if CONDITION_END.match(line):
                if conditions:
                    conditions.pop()
                continue
            start = CONDITION_START.match(line)
            if start:
                if start.group(1) == "elseif" and conditions:
                    conditions.pop()
                conditions.append(start.group(2))
                continue
            if CONDITION_ELSE.match(line):
                if conditions:
                    conditions[-1] = ""
                continue
            match = IMPORT.match(line)
            if not match:
                continue
            module = match.group(1)
            if any(f"canImport({module})" in condition for condition in conditions):
                continue
            found.add(module)
    return found


def imports_in_target(target: dict) -> set[str]:
    root = target_path(target)
    found: set[str] = set()
    for directory, _, files in os.walk(root):
        for name in files:
            if name.endswith(".swift"):
                found |= imports_in_file(os.path.join(directory, name))
    return found


def verify_product_naming(package: dict, used: set[str]) -> list[str]:
    """Assert the assumption `declared_dependencies` rests on.

    Every `.product(name:package:)` in this manifest vends a module of the same name, which
    is what lets the comparison treat product names and module names as one namespace. If a
    future dependency breaks that — a product vending a differently-named module — the
    comparison would silently report a false missing import, so it is checked rather than
    trusted.
    """
    problems = []
    for target in package["targets"]:
        for dependency in target["dependencies"]:
            product = dependency.get("product")
            if not product or not product[0]:
                continue
            name = product[0]
            if name not in used and name not in LINK_ONLY:
                problems.append(
                    f"product '{name}' (declared on {target['name']}) is never imported "
                    f"under that name — if it vends a module with a different name, this "
                    f"script's product-name-equals-module-name assumption no longer holds"
                )
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", help="exercise the scanner")
    arguments = parser.parse_args()

    if arguments.self_test:
        return self_test()

    package = dump_package()
    local = {target["name"] for target in package["targets"]}

    all_imports: set[str] = set()
    undeclared: list[tuple[str, list[str]]] = []
    unused: list[tuple[str, list[str]]] = []
    unknown: list[tuple[str, list[str]]] = []

    for target in sorted(package["targets"], key=lambda t: t["name"]):
        name = target["name"]
        found = imports_in_target(target)
        all_imports |= found
        declared = declared_dependencies(target)

        wanted = {module for module in found if module != name and module not in SDK_MODULES}
        missing = sorted(wanted - declared)
        if missing:
            undeclared.append((name, missing))

        dead = sorted(
            module for module in declared - found
            if module not in LINK_ONLY
        )
        if dead:
            unused.append((name, dead))

        strangers = sorted(
            module for module in wanted
            if module not in local and module not in declared
        )
        if strangers:
            unknown.append((name, strangers))

    naming = verify_product_naming(package, all_imports)

    if not (undeclared or unused or naming):
        print(f"Package graph is consistent: {len(package['targets'])} targets, "
              f"no drift in either direction.")
        return 0

    if unused:
        print("Declared but never imported")
        print("  A dead edge widens what the target is allowed to import. Remove it.\n")
        for name, modules in unused:
            print(f"  {name}")
            for module in modules:
                print(f"      - {module}")
        print()

    if undeclared:
        print("Imported but never declared")
        print("  These compile only because something else pulls them in transitively.\n")
        for name, modules in undeclared:
            print(f"  {name}")
            for module in modules:
                marker = "" if module in local else "   (external product)"
                print(f"      + {module}{marker}")
        print()

    if naming:
        print("Product naming assumption violated")
        for problem in naming:
            print(f"  - {problem}")
        print()

    print("Fix Package.swift, or add a documented entry to SDK_MODULES / LINK_ONLY in")
    print(f"  {os.path.relpath(os.path.abspath(__file__), REPO_ROOT)}")
    return 1


def self_test() -> int:
    """Exercise the import scanner against the forms this repository actually uses.

    The scanner is the part with the real risk: a regex that quietly stops matching
    `@_exported import struct X.Y` would turn this check into one that always passes.
    """
    import tempfile

    source = """
//  A comment mentioning import NotAModule
import Foundation
import BBSettings
@_exported import struct BBSettings.PasswordPolicy
@testable import BBAuth
  import GRDB

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

#if DEBUG
  import DebugOnlyModule
#endif

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
"""
    expected = {
        "Foundation", "BBSettings", "BBAuth", "GRDB", "DebugOnlyModule", "Glibc",
    }

    with tempfile.TemporaryDirectory() as directory:
        path = os.path.join(directory, "Sample.swift")
        with open(path, "w") as handle:
            handle.write(source)
        actual = imports_in_file(path)

    if actual != expected:
        print("FAIL: import scanner")
        print(f"  expected: {sorted(expected)}")
        print(f"  actual:   {sorted(actual)}")
        print(f"  missing:  {sorted(expected - actual)}")
        print(f"  extra:    {sorted(actual - expected)}")
        return 1

    print("Import scanner self-test passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
