# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Export a schema v1 example from the fixed real capture and its known SQL DDL."""

import argparse
import json
from pathlib import Path
import re
import struct

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "fixtures/mysql-8.0"
OUTPUT = ROOT / "examples/mysql-8.0-schema.json"


def generated():
    raw = (FIXTURES / "crc32-full.binlog").read_bytes()
    cursor = 4
    while cursor < len(raw):
        size = struct.unpack_from("<I", raw, cursor + 9)[0]
        if size < 23 or cursor + size > len(raw):
            raise ValueError("invalid fixed CRC fixture framing")
        if raw[cursor + 4] == 19:
            body = raw[cursor + 19:cursor + size - 4]
            break
        cursor += size
    else:
        raise ValueError("capture has no TABLE_MAP")

    position = 8

    def take(count):
        nonlocal position
        result = body[position:position + count]
        if len(result) != count:
            raise ValueError("truncated TABLE_MAP fixture")
        position += count
        return result

    def packed():
        first = take(1)[0]
        if first < 251:
            return first
        widths = {252: 2, 253: 3, 254: 8}
        if first not in widths:
            raise ValueError("invalid packed integer in fixture")
        return int.from_bytes(take(widths[first]), "little")

    def name():
        value = take(take(1)[0]).decode("utf-8")
        if take(1) != b"\0":
            raise ValueError("invalid name terminator")
        return value

    database, table = name(), name()
    count = packed()
    types = take(count)
    metadata = take(packed())
    nullable = take((count + 7) // 8)
    declarations = re.findall(r"^  (\w+) (\w+)([^\n]*)", (FIXTURES / "schema.sql").read_text(encoding="utf-8"), re.M)
    if len(declarations) != count:
        raise ValueError("SQL/capture column count differs")
    # Widths needed by this fixed 20-column fixture; not a general SQL parser.
    widths = {1: 0, 2: 0, 3: 0, 8: 0, 9: 0, 10: 0, 13: 0,
              4: 1, 5: 1, 17: 1, 18: 1, 19: 1, 252: 1,
              15: 2, 16: 2, 246: 2, 254: 2}
    columns = []
    offset = 0
    for i, (column_name, sql_type, attributes) in enumerate(declarations):
        width = widths[types[i]]
        column = {"name": column_name, "wire_type": types[i],
                  "metadata": metadata[offset:offset + width].hex(),
                  "nullable": bool(nullable[i // 8] & (1 << (i % 8)))}
        if sql_type in {"TINYINT", "SMALLINT", "MEDIUMINT", "INT", "BIGINT"}:
            column["unsigned"] = "UNSIGNED" in attributes.upper()
        columns.append(column)
        offset += width
    if offset != len(metadata):
        raise ValueError("metadata width sum differs")
    return json.dumps({"schema_version": 1, "tables": [
        {"database": database, "table": table, "columns": columns}
    ]}, ensure_ascii=False, indent=2) + "\n"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    expected = generated()
    if args.check:
        if OUTPUT.read_text(encoding="utf-8") != expected:
            raise SystemExit("schema example differs from capture/SQL; regenerate it")
    else:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(expected, encoding="utf-8", newline="\n")
    print("Verified schema example against 20 real TABLE_MAP columns and SQL signedness")
