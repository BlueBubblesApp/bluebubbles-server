#!/usr/bin/env python3
"""Capture real `attributedBody` blobs from a live chat.db, redacted, as test fixtures.

Why this is needed: the synthetic typedstream vectors in Tools/protocol-vectors cover the
primitive grammar, but not a full NSAttributedString with attribute ranges and nested
dictionaries. Hand-rolling one produces an archive the reference decoder rejects, which is
worse than no fixture. Real ones can only come from a real Mac.

REDACTION. This reads your actual messages. It never writes the message text to the fixture
file — only the raw bytes needed to exercise the decoder, plus a SHA-256 of the expected
text so the Swift test can assert correctness without the fixture containing anything
readable. Review the output before committing it, and prefer messages you sent to yourself.

    python3 capture_attributed_bodies.py --out ../../Tests/ProtocolTests/ProtocolFixtures
    python3 capture_attributed_bodies.py --out <dir> --limit 40 --include-text   # local only

`--include-text` stores the plaintext, which makes failures far easier to debug. Use it
while working on the decoder; do NOT commit the result.

Requires Full Disk Access for whatever runs it (Terminal, or your IDE).
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import sqlite3
import sys
from pathlib import Path

DEFAULT_DB = Path.home() / "Library" / "Messages" / "chat.db"


def capture(db_path: Path, limit: int, include_text: bool) -> list[dict]:
    if not db_path.exists():
        raise SystemExit(f"No chat.db at {db_path}")

    # READ-ONLY, and immutable is deliberately NOT set: Messages writes to this file live,
    # and telling SQLite otherwise yields stale reads.
    uri = f"file:{db_path}?mode=ro"
    try:
        connection = sqlite3.connect(uri, uri=True)
    except sqlite3.OperationalError as error:
        raise SystemExit(
            f"Could not open chat.db read-only ({error}).\n"
            "This is almost always missing Full Disk Access for the app running this script."
        )

    columns = {row[1] for row in connection.execute("PRAGMA table_info(message)")}
    if "attributedBody" not in columns:
        raise SystemExit("This chat.db has no attributedBody column.")

    # A spread of shapes rather than the most recent N, which would likely be one
    # conversation in one style.
    query = """
        SELECT ROWID, guid, text, attributedBody,
               COALESCE(cache_has_attachments, 0) AS has_attachments,
               LENGTH(attributedBody) AS blob_length
        FROM message
        WHERE attributedBody IS NOT NULL AND LENGTH(attributedBody) > 0
        ORDER BY blob_length DESC
        LIMIT ?
    """

    captured = []
    for row in connection.execute(query, (limit,)):
        rowid, guid, text, blob, has_attachments, blob_length = row
        text = text or ""

        entry = {
            "name": f"captured-{rowid}",
            "base64": base64.b64encode(blob).decode("ascii"),
            "byteLength": blob_length,
            # The decoder's job is to reproduce message.text where it is populated. Hashing
            # lets the test assert that without the fixture carrying readable content.
            "expectedTextSHA256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
            "expectedTextLength": len(text),
            "hasAttachments": bool(has_attachments),
            # The interesting case: text NULL but attributedBody populated, which is what
            # makes the decoder load-bearing rather than an optimisation.
            "textWasNull": row[2] is None,
        }
        if include_text:
            entry["expectedText"] = text
        captured.append(entry)

    connection.close()
    return captured


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--limit", type=int, default=25)
    parser.add_argument(
        "--include-text",
        action="store_true",
        help="Store plaintext for debugging. Do not commit the result.",
    )
    args = parser.parse_args()

    vectors = capture(args.db, args.limit, args.include_text)
    if not vectors:
        print("No attributedBody blobs found.", file=sys.stderr)
        return 1

    payload = {
        "_README": (
            "Captured from a real chat.db. Text is stored as a SHA-256 unless --include-text "
            "was passed. REVIEW BEFORE COMMITTING."
        ),
        "_containsPlaintext": args.include_text,
        "vectors": vectors,
    }

    args.out.mkdir(parents=True, exist_ok=True)
    target = args.out / "typedstream-captured.json"
    target.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")

    null_text = sum(1 for v in vectors if v["textWasNull"])
    print(f"wrote {target}")
    print(f"  {len(vectors)} blobs, {null_text} with NULL message.text")
    if args.include_text:
        print("  WARNING: contains plaintext. Do not commit.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
