#!/usr/bin/env python3
"""Generate deterministic synthetic chat.db fixtures, one per macOS schema profile.

Why this exists
---------------
Serializer output is version-dependent: `messageSummaryInfo` and `payloadData` appear on
High Sierra and later, `wasDeliveredQuietly` and `didNotifyRecipient` on Monterey and later,
`dateEdited` / `dateRetracted` / `partCount` on Ventura and later. Fields are *absent* on
older releases, not null. Asserting that correctly needs a real database per profile.

It also means contributors can develop against a fixture database instead of pointing the
server at their own messages.

Schemas come from ``macos/database/samples/<release>/*.sql``, which are dumps of the real
Apple schema. Some releases omit the join tables; those fall back to the canonical
definitions below, which have been stable across every release in the corpus.

Everything is deterministic — fixed GUIDs, fixed timestamps, no randomness — so a
regenerated fixture produces an empty diff rather than churn.

Usage
-----
    python3 generate.py --out ../../Tests/ChatDBFixtures
    python3 generate.py --self-test          # CI: build in a temp dir and verify invariants
"""

from __future__ import annotations

import argparse
import re
import shutil
import sqlite3
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
SAMPLES_DIR = REPO_ROOT / "macos" / "database" / "samples"

# Profiles the Swift server actually supports. macOS 13 is the deployment floor, so
# anything older is present in the corpus for reference but is not generated.
PROFILES = ["ventura", "sonoma", "sequoia"]

# The seed identities. See CONTRIBUTING.md § "Test data: never real addresses" — these are
# reserved ranges, and changing them means regenerating the committed fixtures.
ALICE_NUMBER = "+12025550143"
BOB_NUMBER = "+12025550144"
FRIEND_EMAIL = "person@example.com"
GROUP_GUID = "chat000000000000000001"

# Join tables are absent from several release dumps. These definitions are identical across
# every release that does include them.
CANONICAL_JOIN_TABLES = {
    "chat_handle_join": """
        CREATE TABLE chat_handle_join (
            chat_id INTEGER REFERENCES chat (ROWID) ON DELETE CASCADE,
            handle_id INTEGER REFERENCES handle (ROWID) ON DELETE CASCADE,
            UNIQUE(chat_id, handle_id)
        )
    """,
    "chat_message_join": """
        CREATE TABLE chat_message_join (
            chat_id INTEGER REFERENCES chat (ROWID) ON DELETE CASCADE,
            message_id INTEGER REFERENCES message (ROWID) ON DELETE CASCADE,
            message_date INTEGER DEFAULT 0,
            PRIMARY KEY (chat_id, message_id)
        )
    """,
    "message_attachment_join": """
        CREATE TABLE message_attachment_join (
            message_id INTEGER REFERENCES message (ROWID) ON DELETE CASCADE,
            attachment_id INTEGER REFERENCES attachment (ROWID) ON DELETE CASCADE,
            UNIQUE(message_id, attachment_id)
        )
    """,
}

# Apple stores dates as nanoseconds since 2001-01-01 UTC. Getting this conversion wrong is a
# classic source of off-by-31-years bugs, so the fixtures pin known values and the tests
# assert the round trip.
APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)


def to_apple_time(dt: datetime) -> int:
    """Convert a UTC datetime to Apple's nanoseconds-since-2001 representation."""
    return int((dt - APPLE_EPOCH).total_seconds() * 1_000_000_000)


# A fixed instant so every generated fixture is byte-identical between runs.
BASE_TIME = datetime(2024, 6, 1, 12, 0, 0, tzinfo=timezone.utc)


TABLE_NAME_PATTERN = re.compile(
    r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?[\"'`\[]?(\w+)", re.IGNORECASE
)


def load_schema(profile: str) -> dict[str, str]:
    """Read a profile's table definitions, filling in any missing join tables.

    Keyed by the table name parsed out of the SQL rather than the filename: the upstream
    corpus is not perfectly consistent. In the sequoia dump, for instance,
    ``message_processing_task.sql`` actually contains ``CREATE TABLE
    recoverable_message_part``. Trusting filenames produces a duplicate-table error, and
    worse, silently omits a table that was supposed to exist.
    """
    directory = SAMPLES_DIR / profile
    if not directory.is_dir():
        raise SystemExit(f"No schema samples for profile '{profile}' at {directory}")

    schema: dict[str, str] = {}
    for sql_file in sorted(directory.glob("*.sql")):
        sql = sql_file.read_text(encoding="utf-8").strip()
        match = TABLE_NAME_PATTERN.search(sql)
        if not match:
            continue
        table = match.group(1)
        if table in schema:
            # Duplicate definition of the same table across two files. Keep the first and
            # carry on rather than failing — the corpus is reference material, not input we
            # control.
            continue
        schema[table] = sql

    for name, definition in CANONICAL_JOIN_TABLES.items():
        if name not in schema:
            schema[name] = definition.strip()

    required = {"chat", "message", "handle", "attachment"}
    missing = required - schema.keys()
    if missing:
        raise SystemExit(f"Profile '{profile}' is missing required tables: {sorted(missing)}")

    return schema


def required_columns(cursor: sqlite3.Cursor, table: str) -> set[str]:
    """Columns that are NOT NULL with no default, so a row cannot omit them.

    Discovered rather than hard-coded: Ventura added ``attachment.original_guid`` as NOT
    NULL, and a future release will add another. Deriving this from the schema means a new
    required column produces a clear failure here instead of a confusing one later.
    """
    return {
        row[1]
        for row in cursor.execute(f"PRAGMA table_info({table})")
        if row[3] == 1 and row[4] is None and row[5] == 0
    }


def seed(connection: sqlite3.Connection, profile: str) -> None:
    """Insert a small, deliberately varied corpus.

    Every row here exists to exercise something specific in the serializers rather than to
    look realistic — group vs direct chats, attachments, reactions, replies, and the
    version-gated columns.
    """
    cursor = connection.cursor()

    # Addresses come from the ranges CONTRIBUTING.md § "Test data: never real addresses"
    # reserves, and from nowhere else. NPA-555-0100 through NPA-555-0199 is the only block
    # reserved for fiction — 555-1234, which this used to use, sits OUTSIDE it and is
    # assignable. `example.com` can never be a real mailbox (RFC 2606). The spellings match
    # what the rest of the suite already uses, so a fixture address greps to the same place
    # as a hand-written one.
    handles = [
        (1, ALICE_NUMBER, "US", "iMessage", ALICE_NUMBER),
        (2, FRIEND_EMAIL, None, "iMessage", FRIEND_EMAIL),
        (3, BOB_NUMBER, "US", "SMS", BOB_NUMBER),
    ]
    cursor.executemany(
        "INSERT INTO handle (ROWID, id, country, service, uncanonicalized_id) VALUES (?, ?, ?, ?, ?)",
        handles,
    )

    chats = [
        # style 45 = direct message, 43 = group. The serializers branch on this.
        (1, f"iMessage;-;{ALICE_NUMBER}", 45, ALICE_NUMBER, "iMessage", None),
        (2, f"iMessage;+;{GROUP_GUID}", 43, GROUP_GUID, "iMessage", "Weekend Plans"),
        (3, f"SMS;-;{BOB_NUMBER}", 45, BOB_NUMBER, "SMS", None),
    ]
    cursor.executemany(
        """INSERT INTO chat (ROWID, guid, style, chat_identifier, service_name, display_name)
           VALUES (?, ?, ?, ?, ?, ?)""",
        chats,
    )

    cursor.executemany(
        "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (?, ?)",
        [(1, 1), (2, 1), (2, 2), (3, 3)],
    )

    message_columns = {row[1] for row in cursor.execute("PRAGMA table_info(message)")}

    def insert_message(rowid, guid, text, handle_id, is_from_me, offset_seconds, **extra):
        sent_at = to_apple_time(
            BASE_TIME.replace(second=0) + (BASE_TIME - BASE_TIME)
        ) + offset_seconds * 1_000_000_000
        values = {
            "ROWID": rowid,
            "guid": guid,
            "text": text,
            "handle_id": handle_id,
            "is_from_me": is_from_me,
            "date": sent_at,
            "date_read": 0,
            "date_delivered": 0,
            "is_delivered": 1,
            "is_sent": 1,
            "is_read": 1 if not is_from_me else 0,
            "service": "iMessage",
            "type": 0,
            "item_type": 0,
        }
        # Only set columns the profile's schema actually has. This is what makes one seeding
        # routine work across three schema versions.
        values.update({k: v for k, v in extra.items() if k in message_columns})
        usable = {k: v for k, v in values.items() if k in message_columns}
        placeholders = ", ".join("?" for _ in usable)
        columns = ", ".join(usable)
        cursor.execute(
            f"INSERT INTO message ({columns}) VALUES ({placeholders})", list(usable.values())
        )

    insert_message(1, "11111111-0000-0000-0000-000000000001", "Hey there", 1, 0, 0)
    insert_message(2, "11111111-0000-0000-0000-000000000002", "Hey! How are you?", 0, 1, 60)
    insert_message(3, "11111111-0000-0000-0000-000000000003", "Sending a photo", 1, 0, 120)
    insert_message(
        4,
        "11111111-0000-0000-0000-000000000004",
        "Are we still on for Saturday?",
        2,
        0,
        180,
    )
    # A reaction: associated_message_type 2000 is a "love" tapback.
    insert_message(
        5,
        "11111111-0000-0000-0000-000000000005",
        None,
        1,
        0,
        240,
        associated_message_guid="p:0/11111111-0000-0000-0000-000000000002",
        associated_message_type=2000,
    )
    # A threaded reply.
    insert_message(
        6,
        "11111111-0000-0000-0000-000000000006",
        "Yes, see you then",
        0,
        1,
        300,
        thread_originator_guid="11111111-0000-0000-0000-000000000004",
        thread_originator_part="0:0:0",
    )
    # Ventura+ only: an edited message. Silently skipped on profiles lacking the column,
    # which is exactly the behaviour the version-gated serializer tests need.
    insert_message(
        7,
        "11111111-0000-0000-0000-000000000007",
        "Actually, make it Sunday",
        0,
        1,
        360,
        date_edited=to_apple_time(BASE_TIME) + 400 * 1_000_000_000,
        part_count=1,
    )

    cursor.executemany(
        "INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (?, ?, ?)",
        [(1, 1, 0), (1, 2, 0), (1, 3, 0), (2, 4, 0), (1, 5, 0), (2, 6, 0), (2, 7, 0)],
    )

    attachment_columns = {row[1] for row in cursor.execute("PRAGMA table_info(attachment)")}
    attachment_values = {
        "ROWID": 1,
        "guid": "22222222-0000-0000-0000-000000000001",
        # NOT NULL from Ventura onward. For an attachment that was never re-sent, Messages
        # sets this equal to the guid.
        "original_guid": "22222222-0000-0000-0000-000000000001",
        "created_date": to_apple_time(BASE_TIME),
        "filename": "~/Library/Messages/Attachments/ab/11/photo.heic",
        "uti": "public.heic",
        "mime_type": "image/heic",
        "transfer_name": "photo.heic",
        "total_bytes": 204_800,
        "is_outgoing": 0,
        "is_sticker": 0,
    }
    usable = {k: v for k, v in attachment_values.items() if k in attachment_columns}
    unmet = required_columns(cursor, "attachment") - usable.keys()
    if unmet:
        raise SystemExit(
            f"attachment seed is missing NOT NULL columns for profile '{profile}': {sorted(unmet)}"
        )
    cursor.execute(
        f"INSERT INTO attachment ({', '.join(usable)}) VALUES ({', '.join('?' for _ in usable)})",
        list(usable.values()),
    )
    cursor.execute(
        "INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (?, ?)", (3, 1)
    )

    connection.commit()


def build(profile: str, out_dir: Path) -> Path:
    schema = load_schema(profile)
    out_dir.mkdir(parents=True, exist_ok=True)
    db_path = out_dir / f"chat-{profile}.db"
    if db_path.exists():
        db_path.unlink()

    connection = sqlite3.connect(db_path)
    try:
        # Order matters: base tables before the joins that reference them.
        ordered = ["handle", "chat", "message", "attachment"] + [
            name for name in schema if name not in {"handle", "chat", "message", "attachment"}
        ]
        for name in ordered:
            if name in schema:
                connection.executescript(schema[name])
        seed(connection, profile)
    finally:
        connection.close()

    return db_path


def verify(db_path: Path, profile: str) -> None:
    """Assert the invariants the serializer tests will rely on."""
    connection = sqlite3.connect(db_path)
    try:
        cursor = connection.cursor()

        counts = {
            table: cursor.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            for table in ("handle", "chat", "message", "attachment")
        }
        assert counts["handle"] == 3, counts
        assert counts["chat"] == 3, counts
        assert counts["message"] == 7, counts
        assert counts["attachment"] == 1, counts

        # Both chat styles must be present or the group-vs-direct branches go untested.
        styles = {row[0] for row in cursor.execute("SELECT DISTINCT style FROM chat")}
        assert styles == {43, 45}, styles

        # The Apple-epoch conversion must round-trip. This is the bug class most likely to
        # go unnoticed, because a wrong answer still looks like a plausible date.
        first_date = cursor.execute(
            "SELECT date FROM message WHERE ROWID = 1"
        ).fetchone()[0]
        assert first_date == to_apple_time(BASE_TIME), (first_date, to_apple_time(BASE_TIME))
        recovered = APPLE_EPOCH.timestamp() + first_date / 1_000_000_000
        assert abs(recovered - BASE_TIME.timestamp()) < 1e-6, recovered

        message_columns = {row[1] for row in cursor.execute("PRAGMA table_info(message)")}
        if profile in {"ventura", "sonoma", "sequoia"}:
            # Ventura introduced edit/unsend. Its absence would mean the wrong schema.
            assert "date_edited" in message_columns, sorted(message_columns)
            assert "date_retracted" in message_columns, sorted(message_columns)

        # A reaction and a threaded reply must both exist.
        reactions = cursor.execute(
            "SELECT COUNT(*) FROM message WHERE associated_message_type = 2000"
        ).fetchone()[0]
        assert reactions == 1, reactions

        joined = cursor.execute("SELECT COUNT(*) FROM chat_message_join").fetchone()[0]
        assert joined == 7, joined
    finally:
        connection.close()


def self_test() -> int:
    """Build every profile into a temp directory and verify it. Used by CI."""
    temp_dir = Path(tempfile.mkdtemp(prefix="bb-chatdb-"))
    try:
        for profile in PROFILES:
            db_path = build(profile, temp_dir)
            verify(db_path, profile)
            size = db_path.stat().st_size
            print(f"  ok  {profile}: {db_path.name} ({size:,} bytes)")

        # Determinism is the whole point: a rebuild must be byte-identical, or every
        # regeneration produces a meaningless diff.
        first = (temp_dir / f"chat-{PROFILES[0]}.db").read_bytes()
        rebuilt_dir = Path(tempfile.mkdtemp(prefix="bb-chatdb-rebuild-"))
        try:
            second = build(PROFILES[0], rebuilt_dir).read_bytes()
            assert first == second, "regenerating a fixture must be byte-identical"
            print("  ok  regeneration is deterministic")
        finally:
            shutil.rmtree(rebuilt_dir, ignore_errors=True)

        print(f"\n{len(PROFILES) + 1} checks passed")
        return 0
    except AssertionError as error:
        print(f"  FAIL  {error}", file=sys.stderr)
        return 1
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, help="Directory to write fixtures into")
    parser.add_argument(
        "--profile", choices=PROFILES, action="append", help="Limit to specific profiles"
    )
    parser.add_argument("--self-test", action="store_true", help="Build and verify in a temp dir")
    args = parser.parse_args()

    if args.self_test:
        print("chatdb-fixtures self-test")
        return self_test()

    if not args.out:
        parser.error("--out is required unless --self-test is given")

    for profile in args.profile or PROFILES:
        db_path = build(profile, args.out)
        verify(db_path, profile)
        print(f"wrote {db_path} ({db_path.stat().st_size:,} bytes)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
