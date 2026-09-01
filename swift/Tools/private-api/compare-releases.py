#!/usr/bin/env python3
"""compare-releases.py — what moved between two macOS releases, for the selectors we call.

This is the analysis behind `docs/SEQUOIA_COMPATIBILITY.md`, checked in so it can be re-run
rather than reconstructed. Point it at two header directories; it reads every Objective-C
selector the helpers actually dispatch and reports which ones diverge.

    ./compare-releases.py                                  # 15.6 vs 26.5.2, the default pair
    ./compare-releases.py docs/headers/macos-14.7 docs/headers/macos-26.5.2
    ./compare-releases.py --unresolved                     # selectors no dumped class explains
    ./compare-releases.py --markdown                       # a table to paste into the doc

THE ONE THING TO UNDERSTAND BEFORE READING THE OUTPUT
-----------------------------------------------------
"Absent from release X" and "on a class release X never dumped" are DIFFERENT ANSWERS, and
conflating them is the mistake this whole exercise exists to avoid. A missing header is not
evidence of a missing selector. So every selector is reported in one of four buckets, and
`UNCOMPARABLE` is a real result rather than a gap in the report:

    BOTH          present on both sides — nothing to do
    ONLY-<rel>    present on one, absent from the other THOUGH ITS CLASS WAS DUMPED there
    UNCOMPARABLE  its class has no header on one side; the comparison cannot be made
    UNRESOLVED    no dumped class on EITHER side declares it (see --unresolved)

Exit status is 0 unless --strict is passed, in which case any ONLY-* row exits 1 — for CI,
once both sides are real runtime dumps.
"""

import argparse
import collections
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

SOURCE_ROOTS = ["Helper", "Sources/BBPrivateAPI"]

# Literals that look like selectors but are not: JSON keys on the helper's own wire format,
# URL schemes, Foundation methods. Listed rather than pattern-matched, because a heuristic
# here silently drops a real selector the day somebody names one `path`.
NOT_SELECTORS = {
    "mailto:", "tel:", "path", "index", "array", "error", "event", "events", "ping",
    "process", "protocolVersion", "transactionId", "data", "bytes", "action", "clients",
    "registered", "connections", "pid", "attempt", "reason", "app", "detail", "contains",
    "matchType", "unreported", "inboundEvents", "unknown", "none", "nil", "available",
    "helper", "facetime", "unavailable", "legacy", "live", "proactive", "shallow",
    "proactiveorshallow", "TEMP", "backend", "provisioned", "restricted", "sharingDisabled",
    "absoluteString", "UUIDString", "alloc", "description", "init", "count",
}


# --------------------------------------------------------------------------- headers

def parse_header_dir(path):
    """Returns (index: class -> set(selector), present: class -> bool)."""
    index, present = {}, {}
    if not os.path.isdir(path):
        sys.exit(f"error: no header directory at {path}")
    for filename in sorted(os.listdir(path)):
        if not filename.endswith(".h"):
            continue
        name = filename[:-2]
        raw = open(os.path.join(path, filename), encoding="utf-8", errors="replace").read()
        if "NOT PRESENT" in raw:
            present[name], index[name] = False, set()
            continue
        present[name] = True
        index[name] = parse_declarations(raw)
    return index, present


def parse_declarations(raw):
    """Every selector a header declares — properties (getter and setter) and methods.

    Split on `;` rather than by line, because the two dump formats disagree: the runtime
    dumper writes one declaration per line, and classdump-dyld sometimes packs two onto one.
    A line-anchored regex silently missed `+(id)sharedList;` for exactly that reason.
    """
    text = re.sub(r"^\s*//.*$", "", raw, flags=re.M)
    selectors = set()
    for decl in text.split(";"):
        decl = decl.strip()
        if not decl:
            continue

        if decl.startswith("@property"):
            match = re.match(r"@property\s*(\(([^)]*)\))?\s*(.*)$", decl, re.S)
            if not match:
                continue
            attributes, body = match.group(2) or "", match.group(3)
            name = re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*$", body.strip())
            if not name:
                continue
            name = name[0]
            getter = re.search(r"getter\s*=\s*([A-Za-z_][A-Za-z0-9_]*)", attributes)
            setter = re.search(r"setter\s*=\s*([A-Za-z_][A-Za-z0-9_:]*)", attributes)
            selectors.add(getter.group(1) if getter else name)
            if "readonly" not in attributes:
                selectors.add(setter.group(1) if setter
                              else "set" + name[0].upper() + name[1:] + ":")
            continue

        match = re.search(r"([-+])\s*\(([^)]*)\)\s*(.*)$", decl, re.S)
        if not match:
            continue
        body = match.group(3).strip()
        if not body or not re.match(r"[A-Za-z_]", body):
            continue
        if ":" in body:
            # Keyword parts are the identifiers immediately before a `:(`, which is what
            # separates a real parameter from a colon inside a block or protocol type.
            parts = re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*:\s*\(", body)
            if not parts:
                parts = re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*:", body)
            if parts:
                selectors.add("".join(p + ":" for p in parts))
        else:
            name = re.match(r"([A-Za-z_][A-Za-z0-9_]*)", body)
            if name:
                selectors.add(name.group(1))
    return selectors


# --------------------------------------------------------------------------- sources

LITERAL = re.compile(r'"([A-Za-z_][A-Za-z0-9_]*(?::[A-Za-z0-9_]*)*:?)"')


def collect_selectors(class_names):
    """Every selector-shaped literal in the helper sources, with its call sites.

    Two filters, both structural rather than a denylist, because a denylist silently drops a
    real selector the day somebody names one `path`:

    ONLY FILES THAT DISPATCH. A file with no `IMCoreRuntime.` in it never sends a message to
    IMCore, so its string literals are the helper's own wire vocabulary — `HelperDispatch`'s
    action names, `PrivateAPIClient`'s JSON keys — and they outnumber the real selectors
    three to one. Excluding the file is exact; guessing at the literal is not.

    NOT CLASS NAMES. `requireClass("IMChat")` names a class, not a selector. Any literal that
    is a class in either dump is dropped for that reason.

    Adjacent literals joined by `+` are concatenated FIRST. IMCore's message initializers are
    twenty-odd keywords long and the source wraps them across three lines; read
    literal-by-literal they look like four unresolved selectors instead of one real one.
    """
    found = collections.defaultdict(list)
    skipped_files = []
    for source_root in SOURCE_ROOTS:
        base = os.path.join(ROOT, source_root)
        for dirpath, _, filenames in os.walk(base):
            for filename in filenames:
                if not filename.endswith((".swift", ".m")):
                    continue
                full = os.path.join(dirpath, filename)
                rel = os.path.relpath(full, ROOT)
                text = open(full, encoding="utf-8", errors="replace").read()

                if "IMCoreRuntime." not in text and "objc_getClass" not in text:
                    skipped_files.append(rel)
                    continue

                # Join `"a:" + "b:"` across newlines before anything else looks at it.
                text = re.sub(r'"\s*\+\s*\n?\s*"', "", text)

                for number, line in enumerate(text.split("\n"), 1):
                    stripped = line.lstrip()
                    if stripped.startswith("//") or stripped.startswith("*"):
                        continue
                    for match in LITERAL.finditer(line):
                        value = match.group(1)
                        if len(value) < 3 or value in NOT_SELECTORS:
                            continue
                        if value in class_names:
                            continue
                        found[value].append(f"{rel}:{number}")
    return found, skipped_files


# --------------------------------------------------------------------------- compare

def classify(selector, a_flat, b_flat, a_index, b_index):
    """Which bucket a selector falls in, and why.

    The subtlety is UNCOMPARABLE. If a selector is on `IMMessage` in one release and the
    other release has no `IMMessage.h` at all, its absence there says nothing — so it must
    not be reported next to a genuine removal.
    """
    in_a, in_b = a_flat.get(selector), b_flat.get(selector)
    if in_a and in_b:
        return "BOTH", ""
    if in_a and not in_b:
        if not any(cls in b_index for cls in in_a):
            return "UNCOMPARABLE", f"class(es) {'/'.join(sorted(in_a))} not dumped on the other side"
        return "ONLY-A", "/".join(sorted(in_a))
    if in_b and not in_a:
        if not any(cls in a_index for cls in in_b):
            return "UNCOMPARABLE", f"class(es) {'/'.join(sorted(in_b))} not dumped on the other side"
        return "ONLY-B", "/".join(sorted(in_b))
    return "UNRESOLVED", ""


def flatten(index):
    flat = collections.defaultdict(set)
    for cls, selectors in index.items():
        for selector in selectors:
            flat[selector].add(cls)
    return flat


def main():
    parser = argparse.ArgumentParser(add_help=True, description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("older", nargs="?", default="docs/headers/macos-15.6")
    parser.add_argument("newer", nargs="?", default="docs/headers/macos-26.5.2")
    parser.add_argument("--unresolved", action="store_true",
                        help="list selectors no dumped class on either side declares")
    parser.add_argument("--markdown", action="store_true", help="emit a Markdown table")
    parser.add_argument("--strict", action="store_true", help="exit 1 if anything diverges")
    args = parser.parse_args()

    older = args.older if os.path.isabs(args.older) else os.path.join(ROOT, args.older)
    newer = args.newer if os.path.isabs(args.newer) else os.path.join(ROOT, args.newer)
    a_label, b_label = os.path.basename(older), os.path.basename(newer)

    a_index, a_present = parse_header_dir(older)
    b_index, b_present = parse_header_dir(newer)
    a_flat, b_flat = flatten(a_index), flatten(b_index)
    class_names = set(a_index) | set(b_index)
    used, skipped_files = collect_selectors(class_names)

    buckets = collections.defaultdict(list)
    for selector in sorted(used):
        bucket, detail = classify(selector, a_flat, b_flat, a_index, b_index)
        buckets[bucket].append((selector, detail, used[selector][0]))

    print(f"{a_label}: {len(a_index)} classes, {sum(len(v) for v in a_index.values())} selectors")
    print(f"{b_label}: {len(b_index)} classes, {sum(len(v) for v in b_index.values())} selectors")
    print(f"helper dispatches {len(used)} distinct selector literals "
          f"(skipped {len(skipped_files)} non-dispatching source files)\n")

    for bucket, title in [
        ("ONLY-B", f"PRESENT ON {b_label}, ABSENT ON {a_label}  (regression risk)"),
        ("ONLY-A", f"PRESENT ON {a_label}, ABSENT ON {b_label}  (fallback needed)"),
    ]:
        rows = buckets[bucket]
        print(f"=== {title} — {len(rows)}")
        if args.markdown and rows:
            print("\n| Selector | Class | Call site |\n|---|---|---|")
            for selector, detail, site in rows:
                print(f"| `{selector}` | `{detail}` | {site} |")
            print()
        else:
            for selector, detail, site in rows:
                print(f"  {selector}\n      on {detail}\n      {site}")
        print()

    print(f"=== BOTH — {len(buckets['BOTH'])}")
    print(f"=== UNCOMPARABLE — {len(buckets['UNCOMPARABLE'])}  "
          f"(class dumped on one side only; get the other dump before reading anything into it)")
    for selector, detail, site in buckets["UNCOMPARABLE"]:
        print(f"  {selector} — {detail}")
    print(f"\n=== UNRESOLVED — {len(buckets['UNRESOLVED'])}"
          f"{'' if args.unresolved else '  (--unresolved to list)'}")
    if args.unresolved:
        for selector, _, site in buckets["UNRESOLVED"]:
            print(f"  {selector}\n      {site}")

    diverged = len(buckets["ONLY-A"]) + len(buckets["ONLY-B"])
    if args.strict and diverged:
        print(f"\nstrict: {diverged} selector(s) diverge", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
