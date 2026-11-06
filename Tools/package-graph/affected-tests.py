#!/usr/bin/env python3
"""Run only the tests a change can affect.

Why this exists
---------------
A warm ``swift test`` runs every target and takes most of a minute; one target takes a few
seconds. An agent iterating on one module pays the full minute on every loop unless something
tells it which targets that module can reach, and guessing is how a change in ``BBCore`` gets
tested in ``BBCoreTests`` alone while the twenty targets above it go unrun.

What it selects
---------------
* **Every test target that depends on a changed target**, through the graph ``Package.swift``
  declares. A changed file maps to the target whose directory holds it; a changed test file
  selects its own target.
* **Every suite that reads what changed**, wherever it is. A source-scanning policy test fails
  on a line in any module, whatever its imports say, and the documentation checks fail on a
  changed ``.md``. A test file that calls ``SourceScanner`` or reads through ``Repository`` is
  one of these, and its suites are added by name rather than its whole target, when a changed
  path falls under a path the target's reading files spell as a string literal
  (``"Sources"``, ``"Fixtures/http"``, ``"docs/AUDIT_LOG.md"``). Per target, not per file,
  because a reader often reaches the tree through a helper in another file of its target. A
  target whose readers spell no path at all is treated as reading everything.
* **Everything**, when the manifest, the resolved versions or the toolchain pin changes.

The tree-reading suites are most of the cost of a selected run: a handful of scanners each
read every file in the repository, and they dominate however small the change. For the
inner loop of editing one module, ``--no-scanners`` leaves them out, which is a test of the
module's behaviour and of nothing it might have broken elsewhere in the tree.

This is a fast loop, not the gate. A change is done when the five checks in ``CLAUDE.md``
pass, and the fifth of them is the whole ``swift test``.

Usage
-----
    python3 Tools/package-graph/affected-tests.py              # working-tree changes
    python3 Tools/package-graph/affected-tests.py --base master
    python3 Tools/package-graph/affected-tests.py Sources/BBCore/Timeout.swift
    python3 Tools/package-graph/affected-tests.py --run        # and run them
    python3 Tools/package-graph/affected-tests.py --run --no-scanners
    python3 Tools/package-graph/affected-tests.py --self-test
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check import REPO_ROOT, declared_dependencies, dump_package, target_path  # noqa: E402

# A change to one of these can change what every target compiles to.
EVERYTHING = {"Package.swift", "Package.resolved", ".swift-version"}

# A test file that reads the repository rather than only the modules it imports.
READS_TREE = re.compile(r"\bSourceScanner\.|\bRepository\.(read|url)\b")

# A suite a filter can name: a top-level test type, which is what Swift Testing and XCTest
# both use as the second component of a test's identifier.
SUITE = re.compile(
    r"^(?:@Suite[^\n]*\n)?(?:@MainActor\s+)?(?:final\s+)?(?:struct|class|enum)\s+"
    r"([A-Za-z_][A-Za-z0-9_]*)",
    re.MULTILINE,
)


def changed_files(base: str | None) -> list[str]:
    """Paths changed in the working tree, plus every commit since ``base`` when one is given."""

    def git(*arguments: str) -> list[str]:
        output = subprocess.check_output(["git", *arguments], cwd=REPO_ROOT, text=True)
        return [line for line in output.splitlines() if line]

    paths = set(git("diff", "--name-only", "HEAD"))
    paths |= set(git("ls-files", "--others", "--exclude-standard"))
    if base:
        paths |= set(git("diff", "--name-only", f"{base}...HEAD"))
    return sorted(paths)


def owning_target(path: str, roots: dict[str, str]) -> str | None:
    """The target whose directory holds ``path``, the deepest one when directories nest."""
    best: tuple[int, str] | None = None
    for name, root in roots.items():
        if path == root or path.startswith(root + "/"):
            if best is None or len(root) > best[0]:
                best = (len(root), name)
    return best[1] if best else None


def dependents(changed: set[str], graph: dict[str, set[str]]) -> set[str]:
    """``changed`` and every target that depends on one of them, transitively."""
    reached = set(changed)
    frontier = set(changed)
    while frontier:
        frontier = {name for name, deps in graph.items() if deps & frontier} - reached
        reached |= frontier
    return reached


# A string literal in Swift, up to an interpolation, which is where a path stops being static.
LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
# `SourceScanner.files(under: [""], …)`: the top-level files, which no literal path names.
TOP_LEVEL_SCAN = re.compile(r'under:\s*\[\s*""\s*\]')


class Readers:
    """What one test target's tree-reading files read: their suites, and where they read."""

    def __init__(self) -> None:
        self.suites: set[str] = set()
        # Path prefixes from the repository root; "" is the top-level files.
        self.prefixes: set[str] = set()

    def reads(self, path: str) -> bool:
        """Whether a change to ``path`` can reach one of these suites."""
        if not self.prefixes:
            return True  # Nothing spelled a path, so assume the whole tree.
        for prefix in self.prefixes:
            if prefix == "" and "/" not in path:
                return True
            if prefix and path.startswith(prefix):
                return True
        return False


def read_prefixes(text: str, top_level: set[str]) -> set[str]:
    """The repository paths a file spells: literals whose first component exists at the root."""
    found: set[str] = set()
    for literal in LITERAL.findall(text):
        static = literal.split("\\(")[0]
        if static and static.split("/")[0] in top_level:
            found.add(static)
    if TOP_LEVEL_SCAN.search(text):
        found.add("")
    return found


def tree_reading_suites(test_targets: dict[str, str]) -> dict[str, "Readers"]:
    """For each test target, the suites in its files that read the repository, and where."""
    top_level = set(os.listdir(REPO_ROOT))
    found: dict[str, Readers] = {}
    for name, root in test_targets.items():
        directory = os.path.join(REPO_ROOT, root)
        for folder, subfolders, files in os.walk(directory):
            subfolders[:] = [s for s in subfolders if not s.startswith(".") and s != "Fixtures"]
            for file in files:
                if not file.endswith(".swift"):
                    continue
                with open(os.path.join(folder, file), encoding="utf-8") as handle:
                    text = handle.read()
                if READS_TREE.search(text):
                    readers = found.setdefault(name, Readers())
                    readers.suites.update(SUITE.findall(text))
                    readers.prefixes |= read_prefixes(text, top_level)
    return found


def select(
    paths: list[str],
    roots: dict[str, str],
    graph: dict[str, set[str]],
    tests: set[str],
    readers: dict[str, Readers],
) -> tuple[set[str] | None, dict[str, set[str]], set[str]]:
    """Whole test targets to run, extra suites to run, and the changed targets.

    ``None`` for the targets means run everything.
    """
    if any(path in EVERYTHING for path in paths):
        return None, {}, set()
    changed = {target for path in paths if (target := owning_target(path, roots))}
    whole = dependents(changed, graph) & tests
    suites = {
        target: found.suites
        for target, found in readers.items()
        if target not in whole and found.suites and any(found.reads(p) for p in paths)
    }
    return whole, suites, changed


def filter_expression(whole: set[str], suites: dict[str, set[str]]) -> str:
    parts = [rf"^{re.escape(target)}\." for target in sorted(whole)]
    for target in sorted(suites):
        names = "|".join(sorted(suites[target]))
        parts.append(rf"^{re.escape(target)}\.({names})\b")
    return "|".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("paths", nargs="*", help="changed paths, relative to the repository")
    parser.add_argument("--base", help="also include every commit since this ref")
    parser.add_argument("--run", action="store_true", help="run swift test with the filter")
    parser.add_argument(
        "--no-scanners", action="store_true", help="leave out the suites that read the tree"
    )
    parser.add_argument("--self-test", action="store_true", help="exercise the selection")
    arguments = parser.parse_args()
    if arguments.self_test:
        return self_test()

    package = dump_package()
    roots = {t["name"]: os.path.relpath(target_path(t), REPO_ROOT) for t in package["targets"]}
    graph = {t["name"]: declared_dependencies(t) for t in package["targets"]}
    tests = {t["name"] for t in package["targets"] if t["type"] == "test"}
    readers = {} if arguments.no_scanners else tree_reading_suites({n: roots[n] for n in tests})

    paths = arguments.paths or changed_files(arguments.base)
    if not paths:
        print("No changes, so no tests to select.")
        return 0
    whole, suites, changed = select(paths, roots, graph, tests, readers)

    if whole is not None and not whole and not suites:
        print("Nothing selected: no test target depends on what changed.")
        return 0
    if whole is None:
        print("The manifest or the toolchain changed: run the whole suite.")
        command = ["swift", "test"]
    else:
        suite_count = sum(len(names) for names in suites.values())
        print(f"Changed targets: {', '.join(sorted(changed)) or 'none'}")
        print(f"Test targets run whole ({len(whole)}): {', '.join(sorted(whole)) or 'none'}")
        if arguments.no_scanners:
            print("Tree-reading suites: left out")
        else:
            print(f"Tree-reading suites in the other {len(suites)} targets: {suite_count}")
        command = ["swift", "test", "--filter", filter_expression(whole, suites)]
    print()
    print(" ".join(command if len(command) < 3 else command[:3] + [f"'{command[3]}'"]))
    if arguments.run:
        return subprocess.call(command, cwd=REPO_ROOT)
    return 0


def self_test() -> int:
    roots = {
        "BBCore": "Sources/BBCore",
        "BBSettings": "Sources/BBSettings",
        "App": "Sources/App",
        "BBCoreTests": "Tests/BBCoreTests",
        "BBSettingsTests": "Tests/BBSettingsTests",
        "Policy": "Tests/Policy",
        "Helper": "Helper",
        "HelperContract": "Helper/Contract",
    }
    graph = {
        "BBCore": set(),
        "BBSettings": {"BBCore"},
        "App": {"BBSettings"},
        "BBCoreTests": {"BBCore"},
        "BBSettingsTests": {"BBSettings"},
        "Policy": set(),
        "Helper": set(),
        "HelperContract": set(),
    }
    tests = {"BBCoreTests", "BBSettingsTests", "Policy"}
    def make(suites: set[str], prefixes: set[str]) -> Readers:
        found = Readers()
        found.suites, found.prefixes = suites, prefixes
        return found

    readers = {
        "Policy": make({"ScanTests"}, {"Sources", "docs", ""}),
        "BBCoreTests": make({"CoreScanTests"}, set()),
        "BBSettingsTests": make({"FixtureTests"}, {"Fixtures/http"}),
    }
    failures: list[str] = []

    def expect(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    whole, suites, changed = select(["Sources/BBCore/A.swift"], roots, graph, tests, readers)
    expect(changed == {"BBCore"}, f"a source file maps to its target, got {changed}")
    expect(whole == {"BBCoreTests", "BBSettingsTests"}, f"dependents are transitive, got {whole}")
    expect(suites == {"Policy": {"ScanTests"}}, f"only readers of what changed are added: {suites}")

    whole, suites, _ = select(["docs/WRITING.md"], roots, graph, tests, readers)
    expect(whole == set(), f"a document runs no target whole, got {whole}")
    expect(
        set(suites) == {"Policy", "BBCoreTests"},
        f"a document runs its readers and the ones that spell no path: {suites}",
    )
    _, suites, _ = select(["Fixtures/http/a.json"], roots, graph, tests, readers)
    expect(set(suites) == {"BBSettingsTests", "BBCoreTests"}, f"a fixture runs its reader: {suites}")
    _, suites, _ = select(["README.md"], roots, graph, tests, readers)
    expect("Policy" in suites, f"a top-level scan reads a top-level file: {suites}")
    expect(
        read_prefixes('Repository.url("Fixtures/http/\\(name)") + "x.swift"', {"Fixtures"})
        == {"Fixtures/http/"},
        "an interpolated literal keeps its static prefix, and a name not at the root is no path",
    )

    whole, _, _ = select(["Tests/BBSettingsTests/T.swift"], roots, graph, tests, readers)
    expect(whole == {"BBSettingsTests"}, f"a test file runs its own target, got {whole}")

    whole, _, _ = select(["Package.swift"], roots, graph, tests, readers)
    expect(whole is None, "the manifest runs everything")

    expect(owning_target("Helper/Contract/X.swift", roots) == "HelperContract", "deepest wins")
    expect(owning_target("Sources/BBCoreExtra/X.swift", roots) is None, "a prefix is not a root")

    expression = filter_expression({"BBCoreTests"}, {"Policy": {"B", "A"}})
    expect(expression == r"^BBCoreTests\.|^Policy\.(A|B)\b", f"filter shape, got {expression}")

    expect(
        SUITE.findall('@Suite("x")\nstruct ATests {\n  struct Inner {}\n}\nfinal class B: XCTestCase {}')
        == ["ATests", "B"],
        "only top-level types are suites",
    )

    for failure in failures:
        print(f"FAIL: {failure}")
    print(f"{'FAILED' if failures else 'OK'}: affected-tests self-test")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
