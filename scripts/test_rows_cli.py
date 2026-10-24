# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Compare native row-mode JSON with official mysqlbinlog and exercise failures."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import zlib

sys.dont_write_bytecode = True
from verify_mysql_fixtures import oracle_images

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "fixtures/mysql-8.0"
SCHEMA = ROOT / "examples/mysql-8.0-schema.json"
EXE = ROOT / "_build/native/debug/build/cmd/moonbinlog/moonbinlog.exe"


def canonical(cell):
    if cell["state"] != "value":
        return {"null": "NULL", "absent": "ABSENT"}[cell["state"]]
    kind, value = cell["type"], cell["value"]
    if kind in {"integer", "decimal", "bit", "enum", "set"}:
        assert type(value) is str
        return value
    if kind in {"string_bytes", "blob_bytes"}:
        assert cell["encoding"] == "hex"
        assert bytes.fromhex(value).hex() == value
        return "hex:" + value
    if kind in {"float32", "float64"}:
        bits = int(cell["bits"])
        width, fmt = (4, "<f") if kind == "float32" else (8, "<d")
        assert struct.unpack(fmt, bits.to_bytes(width, "little"))[0] == value
        return str(value)
    if kind == "year":
        return str(value["year"])
    keys = {"date": ["year", "month", "day"],
            "datetime": ["year", "month", "day", "hour", "minute", "second", "microsecond"],
            "time": ["hour", "minute", "second", "microsecond"],
            "timestamp": ["seconds", "microsecond"]}[kind]
    prefix = kind + ":" + (("-" if value["negative"] else "+") if kind == "time" else "")
    return prefix + ",".join(str(value[key]) for key in keys)


def main(executable):
    cases = 0

    def run(args, code=0):
        nonlocal cases
        result = subprocess.run([str(executable), *map(str, args)], cwd=ROOT,
                                capture_output=True, text=True, encoding="utf-8", timeout=20)
        cases += 1
        assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        if code == 0:
            assert result.stderr == ""
        else:
            assert result.stderr.startswith("moonbinlog:"), result.stderr
            assert all(record["kind"] == "row_change" for record in records)
        return result, records

    def verify(records, profile, summary_only=False):
        raw = (FIXTURES / f"{profile}.binlog").read_bytes()
        summary = records[-1]
        assert summary["kind"] == "row_summary" and summary["transaction_status"] == "unconfirmed"
        assert summary["schema_version"] == 1
        assert summary["row_events"] == 4 and summary["changes"] == 4
        assert summary["events"] == 14 and summary["file_bytes"] == len(raw)
        assert summary["event_bytes"] == str(len(raw) - 4)
        if summary_only:
            assert len(records) == 1
            return
        assert len(records) == 5
        names = [column["name"] for column in json.loads(SCHEMA.read_text(encoding="utf-8"))["tables"][0]["columns"]]
        operations = ["insert", "insert", "update", "delete"]
        dump = (FIXTURES / f"{profile}.mysqlbinlog.txt").read_bytes()
        offsets = [int(n) for n in re.findall(rb"^# at (\d+)\r?$", dump, re.M)]
        images = []
        for record, operation, event_index in zip(records[:-1], operations, [5, 7, 9, 11]):
            assert record["schema_version"] == 1 and record["kind"] == "row_change"
            assert record["transaction_status"] == "unconfirmed"
            assert record["operation"] == operation and record["change_index"] == 0
            assert record["database"] == "moonbinlog_fixture" and record["table"] == "sample"
            assert record["offset"] == str(offsets[event_index])
            assert record["type"] == raw[offsets[event_index] + 4]
            assert type(record["table_id"]) is str
            assert record["table_id"] == str(int.from_bytes(raw[offsets[4] + 19:offsets[4] + 25], "little"))
            for side in ["before", "after"]:
                if record[side] is not None:
                    assert [cell["index"] for cell in record[side]] == list(range(20))
                    assert [cell["name"] for cell in record[side]] == names
                    images.append([canonical(cell) for cell in record[side]])
            assert (record["before"] is None) == (operation == "insert")
            assert (record["after"] is None) == (operation == "delete")
        assert images == oracle_images(dump), (profile, images)
        assert records[0]["after"][4]["unsigned"] is True
        assert records[0]["after"][0]["unsigned"] is False

    paths = [SCHEMA, *FIXTURES.glob("*.binlog")]
    digests = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
    full_path = FIXTURES / "crc32-full.binlog"
    for args in [["--rows", full_path], ["--schema", SCHEMA, full_path],
                 ["--rows", "--rows", "--schema", SCHEMA, full_path],
                 ["--rows", "--schema"], ["--rows", "--schema", "", full_path]]:
        result, records = run(args, 2)
        assert not records and "Usage:" in result.stderr
    for profile in ["crc32-full", "crc32-minimal", "off-full"]:
        path = FIXTURES / f"{profile}.binlog"
        _, records = run(["--rows", "--schema", SCHEMA, path])
        verify(records, profile)
        _, records = run(["--json", "--summary", path, "--schema", SCHEMA, "--rows"])
        verify(records, profile, True)

    original = full_path.read_bytes()
    dump = (FIXTURES / "crc32-full.mysqlbinlog.txt").read_bytes()
    offsets = [int(n) for n in re.findall(rb"^# at (\d+)\r?$", dump, re.M)]
    with tempfile.TemporaryDirectory(prefix="rows-cli-", dir=ROOT / "_build") as directory:
        work = Path(directory)

        def failure(schema, source=full_path, error=None, summary=False):
            result, records = run(["--rows", "--schema", schema, *( ["--summary"] if summary else []), source], 1)
            if error:
                assert error in result.stderr, result.stderr
            if summary:
                assert not records
            return records

        failure(work / "missing.json")
        failure(work)
        bad_schema = work / "bad-schema.json"
        for contents, error in [
            (b"\xff", None), (b"{}", "InvalidSchema"),
            (b'{"schema_version":1,"schema_version":1,"tables":[]}', "InvalidSchema"),
            (b'{"schema_version":1,"tables":[]}', "MissingTableSchema"),
            (b" " * 1_048_577, "SchemaLimitExceeded"),
            (b" " * 4_194_305, "exceeds limit"),
        ]:
            bad_schema.write_bytes(contents)
            assert not failure(bad_schema, error=error)
        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        schema["tables"][0]["columns"][0]["wire_type"] = 8
        bad_schema.write_text(json.dumps(schema), encoding="utf-8")
        assert not failure(bad_schema, error="SchemaMismatch")

        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        unusual_name = '列"\\\n'
        schema["tables"][0]["columns"][0]["name"] = unusual_name
        unicode_schema = work / "中文 配置.json"
        unicode_schema.write_bytes(b"\xef\xbb\xbf" + json.dumps(schema, ensure_ascii=False).encode())
        _, records = run(["--rows", "--schema", unicode_schema, full_path])
        assert records[0]["after"][0]["name"] == unusual_name and len(records) == 5

        source = work / "invalid.binlog"
        corrupted = bytearray(original)
        corrupted[offsets[5] + 19] ^= 1
        source.write_bytes(corrupted)
        failure(SCHEMA, source, "ChecksumMismatch", True)
        malformed = bytearray(original)
        malformed[offsets[5] + 29] = 19  # column count, valid CRC but wrong semantics
        end = offsets[6]
        struct.pack_into("<I", malformed, end - 4, zlib.crc32(malformed[offsets[5]:end - 4]))
        source.write_bytes(malformed)
        failure(SCHEMA, source, "InvalidRowsEvent", True)
        source.write_bytes(original[:offsets[4]] + original[offsets[5]:])
        assert not failure(SCHEMA, source, "MissingTableMap")
        source.write_bytes(original[:-1])
        assert len(failure(SCHEMA, source, "TruncatedEvent")) == 4

        off = bytearray((FIXTURES / "off-full.binlog").read_bytes())
        off_dump = (FIXTURES / "off-full.mysqlbinlog.txt").read_bytes()
        off_offsets = [int(n) for n in re.findall(rb"^# at (\d+)\r?$", off_dump, re.M)]
        off[off_offsets[-1] + 4] = 255
        source.write_bytes(off)
        assert len(failure(SCHEMA, source, "UnsupportedEvent")) == 4
        off[off_offsets[5] + 4] = 39
        source.write_bytes(off)
        assert not failure(SCHEMA, source, "UnsupportedEvent")

        # A file ending at a complete row-event boundary is NOT proof of COMMIT.
        source.write_bytes(original[:offsets[12]])
        _, records = run(["--rows", "--schema", SCHEMA, source])
        assert len(records) == 5 and records[-1]["events"] == 12
        assert all(record["transaction_status"] == "unconfirmed" for record in records)

    assert all(hashlib.sha256(path.read_bytes()).hexdigest() == digest for path, digest in digests.items())
    print(f"Verified {cases} row CLI scenarios and 300 oracle column positions; inputs unchanged")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, default=EXE)
    main(parser.parse_args().executable.resolve())
