#!/usr/bin/env python3
"""Generate typedstream golden vectors for the Swift decoder.

`message.attributedBody` holds an Apple `typedstream` archive, and it is where the message
text actually lives — `message.text` is frequently NULL, especially from Ventura onward. A
decoder bug there means messages with no text, so it is worth testing against bytes rather
than intuition.

There is no real chat.db here to sample, so this ENCODES blobs following the format, and
`verify.mjs` decodes them with node-typedstream — the reference implementation. If the
reference agrees, the fixture is valid and the format understanding is confirmed.

SCOPE: these cover the primitive grammar — header, byte order, class chains, string values,
and the integer-widening edge cases. They do NOT cover a full NSAttributedString, which
carries attribute ranges and nested dictionaries; a hand-rolled approximation that the
reference rejects would be worse than no fixture at all. Capture those from a real Mac with
Tools/chatdb-fixtures/capture_attributed_bodies.py and commit them separately.

    python3 typedstream_vectors.py --out ../../Tests/ProtocolTests/ProtocolFixtures
    node verify.mjs   # cross-checks with node-typedstream
"""

from __future__ import annotations

import argparse
import base64
import json
import struct
from pathlib import Path

# Tags, as signed bytes. Values outside [FIRST_TAG, LAST_TAG] are literal integers.
TAG_INTEGER_2 = -127
TAG_INTEGER_4 = -126
TAG_FLOATING_POINT = -125
TAG_NEW = -124
TAG_NIL = -123
TAG_END_OF_OBJECT = -122
FIRST_TAG = -128
LAST_TAG = -111


def signed_byte(value: int) -> bytes:
    return struct.pack("b", value)


def encode_integer(value: int) -> bytes:
    """A literal byte where it fits without colliding with the tag range."""
    if FIRST_TAG <= value <= LAST_TAG:
        # Would be read as a tag, so it must be widened.
        return signed_byte(TAG_INTEGER_2) + struct.pack("<h", value)
    if -128 <= value <= 127:
        return signed_byte(value)
    if -32768 <= value <= 32767:
        return signed_byte(TAG_INTEGER_2) + struct.pack("<h", value)
    return signed_byte(TAG_INTEGER_4) + struct.pack("<i", value)


def encode_unshared_string(text: str) -> bytes:
    raw = text.encode("utf-8")
    return encode_integer(len(raw)) + raw


def encode_shared_string(text: str) -> bytes:
    """Literal form: TAG_NEW then the length-prefixed bytes."""
    return signed_byte(TAG_NEW) + encode_unshared_string(text)


def header() -> bytes:
    """Streamer version 4, signature "streamtyped" (little-endian), system version 1000."""
    return (
        encode_integer(4)
        + encode_integer(len("streamtyped"))
        + b"streamtyped"
        + encode_integer(1000)
    )


def type_encoding(encoding: str) -> bytes:
    """A type encoding is a SHARED string, so its literal form is TAG_NEW + length + bytes.

    This is the part the first attempt got wrong: a typedstream is a sequence of
    (type-encoding, value) groups, not a bare sequence of strings. The reference decoder
    reads the first shared string as an encoding and rejects "NSString" because N is not a
    type code.
    """
    return encode_shared_string(encoding)


def encode_class_chain(names: list[str], version: int = 1) -> bytes:
    """TAG_NEW + shared name + version per class, terminated by TAG_NIL for the superclass."""
    blob = b""
    for name in names:
        blob += signed_byte(TAG_NEW) + encode_shared_string(name) + encode_integer(version)
    blob += signed_byte(TAG_NIL)
    return blob


def encode_bytes_value(raw: bytes) -> bytes:
    """The `+` encoding: length-prefixed bytes. NSString decodes itself from this."""
    return type_encoding("+") + encode_integer(len(raw)) + raw


def simple_string_archive(text: str) -> bytes:
    """A plain NSString archive.

        header
        "@"                     type encoding: object
        TAG_NEW                 object begins
          TAG_NEW "NSString" 1  class
          TAG_NIL               superclass terminator
          "+" <len> <bytes>     the string
        TAG_END_OF_OBJECT
    """
    return (
        header()
        + type_encoding("@")
        + signed_byte(TAG_NEW)
        + encode_class_chain(["NSString"])
        + encode_bytes_value(text.encode("utf-8"))
        + signed_byte(TAG_END_OF_OBJECT)
    )


VECTORS = [
    {
        "name": "plain-text",
        "expectedText": "Hello there",
        "bytes": simple_string_archive("Hello there"),
        "note": "The simplest case: one literal string after the class chain.",
    },
    {
        "name": "unicode-text",
        "expectedText": "emoji 🎉 accents éàü",
        "bytes": simple_string_archive("emoji 🎉 accents éàü"),
        "note": "Length is in BYTES, not characters — a UTF-16 assumption breaks here.",
    },
    {
        "name": "empty-text",
        "expectedText": "",
        "bytes": simple_string_archive(""),
        "note": "A zero-length string must not be mistaken for absent.",
    },
    {
        "name": "long-text-multibyte-length",
        "expectedText": "x" * 400,
        "bytes": simple_string_archive("x" * 400),
        "note": "Length exceeds one byte, exercising the TAG_INTEGER_2 widening.",
    },
    {
        "name": "text-length-in-tag-range",
        "expectedText": "y" * 130,
        "bytes": simple_string_archive("y" * 130),
        "note": (
            "Length 130 encodes as signed -126, which collides with TAG_INTEGER_4. It must "
            "be widened, or the reader consumes the following bytes as an integer."
        ),
    },
]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    payload = {
        "_README": (
            "Generated by Tools/protocol-vectors/typedstream_vectors.py and cross-checked "
            "against node-typedstream by verify.mjs. `base64` decodes to a typedstream "
            "archive; the Swift decoder must return `expectedText`."
        ),
        "vectors": [
            {
                "name": vector["name"],
                "expectedText": vector["expectedText"],
                "note": vector["note"],
                "base64": base64.b64encode(vector["bytes"]).decode("ascii"),
                "byteLength": len(vector["bytes"]),
            }
            for vector in VECTORS
        ],
    }

    args.out.mkdir(parents=True, exist_ok=True)
    target = args.out / "typedstream-vectors.json"
    target.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")

    print(f"wrote {target}")
    for vector in payload["vectors"]:
        print(f"  {vector['name']:32s} {vector['byteLength']:5d} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
