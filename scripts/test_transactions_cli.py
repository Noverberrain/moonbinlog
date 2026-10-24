# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Validate native explicit transaction reports, isolation and failure prefixes."""

import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from generate_format_fixtures import event
from generate_transaction_fixtures import query, stream
from test_rows_cli import canonical
from verify_mysql_fixtures import oracle_images

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "fixtures/mysql-8.0"
SCHEMA = ROOT / "examples/mysql-8.0-schema.json"
EXE = ROOT / "_build/native/debug/build/cmd/moonbinlog/moonbinlog.exe"


def packets(data):
    result, offset = [], 4
    while offset < len(data):
        size = int.from_bytes(data[offset + 9:offset + 13], "little")
        assert size >= 19 and offset + size <= len(data)
        result.append(data[offset:offset + size])
        offset += size
    assert offset == len(data)
    return result


def main(executable):
    cases = 0

    def run(args, code=0):
        nonlocal cases
        result = subprocess.run([str(executable), *map(str, args)], cwd=ROOT,
                                capture_output=True, text=True, encoding="utf-8", timeout=30)
        cases += 1
        assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        if code == 0:
            assert result.stderr == "" and records[-1]["kind"] == "transaction_summary"
        else:
            assert result.stderr.startswith("moonbinlog:"), result.stderr
            assert all(record["kind"] == "transaction" for record in records)
        return result, records

    paths = [SCHEMA, *FIXTURES.glob("*.binlog")]
    digests = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
    full_path = FIXTURES / "crc32-full.binlog"
    for args in [["--transactions", full_path],
                 ["--transactions", "--rows", "--schema", SCHEMA, full_path],
                 ["--transactions", "--transactions", "--schema", SCHEMA, full_path],
                 ["--include-rows", full_path],
                 ["--include-rows", "--schema", SCHEMA, full_path],
                 ["--rows", "--include-rows", "--schema", SCHEMA, full_path],
                 ["--transactions", "--include-rows", "--include-rows", "--schema", SCHEMA, full_path],
                 ["--transactions", "--schema"]]:
        result, records = run(args, 2)
        assert not records and "Usage:" in result.stderr

    for profile in ["crc32-full", "crc32-minimal", "off-full"]:
        path = FIXTURES / f"{profile}.binlog"
        data = path.read_bytes()
        dump = (FIXTURES / f"{profile}.mysqlbinlog.txt").read_bytes()
        offsets = [int(n) for n in re.findall(rb"^# at (\d+)\r?$", dump, re.M)]
        for summary_only, include_rows in [(False, False), (True, False), (False, True), (True, True)]:
            _, records = run(["--transactions", "--schema", SCHEMA,
                              *(["--include-rows"] if include_rows else []),
                              *(["--json", "--summary"] if summary_only else []), path])
            summary = records[-1]
            assert summary["schema_version"] == 1 and summary["events"] == 14
            assert summary["committed_transactions"] == 1 and summary["rolled_back_transactions"] == 0
            assert summary["committed_row_events"] == 4 and summary["committed_changes"] == 4
            assert summary["discarded_changes"] == 0 and summary["file_bytes"] == len(data)
            assert summary["event_bytes"] == str(len(data) - 4)
            if summary_only:
                assert len(records) == 1
            else:
                assert len(records) == 2
                transaction = records[0]
                assert transaction["schema_version"] == 1 and transaction["kind"] == "transaction"
                assert transaction["status"] == "committed"
                assert transaction["start_offset"] == str(offsets[3])
                assert transaction["end_offset"] == str(offsets[13])
                assert transaction["event_bytes"] == str(offsets[13] - offsets[3])
                assert transaction["xid"] == re.search(rb"Xid = (\d+)", dump)[1].decode()
                assert transaction["events"] == 10 and transaction["row_events"] == 4
                assert transaction["changes"] == 4
                assert transaction["tables"] == [{"database": "moonbinlog_fixture", "table": "sample",
                                                   "row_events": 4, "changes": 4}]
                if include_rows:
                    changes = transaction["row_changes"]
                    assert len(changes) == 4
                    assert [change["operation"] for change in changes] == ["insert", "insert", "update", "delete"]
                    assert [change["offset"] for change in changes] == [str(offsets[i]) for i in [5, 7, 9, 11]]
                    names = [column["name"] for column in json.loads(SCHEMA.read_text(encoding="utf-8"))["tables"][0]["columns"]]
                    images = []
                    for change in changes:
                        assert change["kind"] == "row_change" and change["schema_version"] == 1
                        assert change["transaction_status"] == "committed" and change["change_index"] == 0
                        for side in ["before", "after"]:
                            if change[side] is not None:
                                assert [cell["index"] for cell in change[side]] == list(range(20))
                                assert [cell["name"] for cell in change[side]] == names
                                images.append([canonical(cell) for cell in change[side]])
                    assert images == oracle_images(dump), (profile, images)
                else:
                    assert "row_changes" not in transaction

    original = packets(full_path.read_bytes())
    fde, begin, table, rows, xid = [original[i] for i in [0, 3, 4, 5, 12]]
    committed = original[3:13]
    with tempfile.TemporaryDirectory(prefix="transactions-cli-", dir=ROOT / "_build") as directory:
        work = Path(directory)
        source = work / "事务 日志.binlog"

        def scan(parts, code=0, error=None, summary=False, schema=SCHEMA, include_rows=False):
            source.write_bytes(b"\xfebin" + stream([fde, *parts]))
            result, records = run(["--transactions", "--schema", schema,
                                   *(["--include-rows"] if include_rows else []),
                                   *(["--summary"] if summary else []), source], code)
            if error:
                assert error in result.stderr, result.stderr
            if code and summary:
                assert not records
            return records

        records = scan([query(b"BEGIN"), query(b"COMMIT")])
        assert records[0]["changes"] == 0 and records[0]["tables"] == [] and records[0]["xid"] is None
        records = scan([begin, table, rows, query(b"ROLLBACK")])
        assert records[0]["status"] == "rolled_back" and records[0]["discarded_changes"] == 1
        assert "tables" not in records[0] and "changes" not in records[0]
        assert records[-1]["committed_changes"] == 0 and records[-1]["discarded_changes"] == 1
        assert records[-1]["rolled_back_transactions"] == 1
        records = scan([*committed, *committed])
        assert len(records) == 3 and records[-1]["committed_changes"] == 8
        assert records[0]["end_offset"] == records[1]["start_offset"]
        assert scan([])[-1]["committed_transactions"] == 0
        high_xid = event(16, (2**64 - 1).to_bytes(8, "little"))
        assert scan([begin, high_xid])[0]["xid"] == str(2**64 - 1)

        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        second = copy.deepcopy(schema["tables"][0])
        second["table"] = "second"
        schema["tables"].append(second)
        custom_schema = work / "配置.json"
        custom_schema.write_bytes(b"\xef\xbb\xbf" + json.dumps(schema, ensure_ascii=False).encode())
        second_table = event(19, table[19:-4].replace(b"sample", b"second"))
        records = scan([begin, table, rows, second_table, rows, xid], schema=custom_schema)
        assert [item["table"] for item in records[0]["tables"]] == ["sample", "second"]
        assert all(item["changes"] == 1 for item in records[0]["tables"])
        schema["tables"][0]["columns"][0]["name"] = '原始列"\\\n'
        schema["tables"][1]["columns"][0]["name"] = "第二张表"
        custom_schema.write_bytes(b"\xef\xbb\xbf" + json.dumps(schema, ensure_ascii=False).encode())
        records = scan([begin, table, rows, second_table, rows, xid], schema=custom_schema, include_rows=True)
        changes = records[0]["row_changes"]
        assert changes[0]["table_id"] == changes[1]["table_id"]
        assert [change["table"] for change in changes] == ["sample", "second"]
        assert [change["after"][0]["name"] for change in changes] == ['原始列"\\\n', "第二张表"]

        custom_schema.write_text('{"schema_version":1,"tables":[]}', encoding="utf-8")
        scan(committed, 1, "MissingTableSchema", schema=custom_schema)
        custom_schema.write_text("{}", encoding="utf-8")
        scan(committed, 1, "InvalidSchema", schema=custom_schema)
        scan(committed, 1, schema=work / "missing.json")
        custom = json.loads(SCHEMA.read_text(encoding="utf-8"))
        custom["tables"][0]["columns"][0]["wire_type"] = 8
        custom_schema.write_text(json.dumps(custom), encoding="utf-8")
        scan(committed, 1, "SchemaMismatch", schema=custom_schema)

        assert not scan(committed[:-1], 1, "IncompleteTransaction")
        scan(committed[:-1], 1, "IncompleteTransaction", summary=True)
        assert len(scan([*committed, *committed[:-1]], 1, "IncompleteTransaction")) == 1
        scan([begin, begin], 1, "InvalidTransactionState")
        for item in [xid, table, rows]:
            scan([item], 1, "InvalidTransactionState")
        for parts in [[query(b"INSERT INTO log VALUES ('COMMIT')")],
                      [begin, query(b"ROLLBACK TO SAVEPOINT s")]]:
            scan(parts, 1, "UnsupportedTransactionStatement")
        for kind in [3, 4, 27, 33, 34, 35]:
            envelope = event(kind, b"not interpreted")
            scan([envelope, begin, xid])
            scan([begin, envelope, xid], 1, "UnsupportedTransactionEvent")
        scan([begin, fde], 1, "IncompleteTransaction")
        scan([event(255, b"unknown")], 1, "UnsupportedTransactionEvent")
        scan([begin, table, rows, rows, xid], 1, "MissingTableMap")
        scan([begin, table, event(30, rows[19:-4][:10]), xid], 1, "InvalidRowsEvent")
        bad_body = bytearray(rows[19:-4])
        bad_body[10] = 19  # complete framing/CRC, mismatching physical column count
        scan([begin, table, event(30, bad_body), xid], 1, "InvalidRowsEvent")
        scan([begin, *([table] * 4095), xid], 1, "TransactionLimitExceeded", summary=True)
        body = rows[19:-4]
        assert body[10] == 20  # one-byte length-encoded count + three-byte bitmap
        thousand_rows = event(30, body[:14] + body[14:] * 1000)
        scan([begin, *([table, thousand_rows] * 11), xid], 1, "TransactionLimitExceeded", summary=True)

        # Export has the same transaction boundary checks, without leaking pending values.
        records = scan([begin, query(b"COMMIT")], include_rows=True)
        assert records[0]["row_changes"] == [] and records[0]["xid"] is None
        records = scan([*committed[:-1], query(b"COMMIT")], include_rows=True)
        assert len(records[0]["row_changes"]) == 4 and records[0]["xid"] is None
        records = scan([*committed, begin, table, rows, query(b"ROLLBACK")], include_rows=True)
        assert len(records[0]["row_changes"]) == 4 and "row_changes" not in records[1]
        assert records[-1]["committed_changes"] == 4 and records[-1]["discarded_changes"] == 1
        records = scan([*committed, *committed], include_rows=True)
        assert len(records[0]["row_changes"]) == len(records[1]["row_changes"]) == 4
        assert records[0]["row_changes"][0]["offset"] != records[1]["row_changes"][0]["offset"]
        two_rows = event(30, body[:14] + body[14:] * 2)
        records = scan([begin, table, two_rows, xid], include_rows=True)
        assert [change["change_index"] for change in records[0]["row_changes"]] == [0, 1]
        assert not scan(committed[:-1], 1, "IncompleteTransaction", include_rows=True)
        scan(committed[:-1], 1, "IncompleteTransaction", summary=True, include_rows=True)
        records = scan([*committed, *committed[:-1]], 1, "IncompleteTransaction", include_rows=True)
        assert len(records) == 1 and len(records[0]["row_changes"]) == 4
        assert not scan([begin, table, event(30, bad_body), xid], 1, "InvalidRowsEvent", include_rows=True)
        assert not scan([begin, event(255, b"unknown"), xid], 1, "UnsupportedTransactionEvent", include_rows=True)
        scan([begin, *([table, thousand_rows] * 11), xid], 1, "TransactionLimitExceeded", include_rows=True)

        # Failures after previously completed transactions retain only that prefix.
        source.write_bytes(b"\xfebin" + stream([fde, *committed, *committed])[:-1])
        _, records = run(["--transactions", "--schema", SCHEMA, source], 1)
        assert len(records) == 1
        damaged = bytearray(b"\xfebin" + stream([fde, *committed]))
        damaged[-1] ^= 1
        source.write_bytes(damaged)
        result, records = run(["--transactions", "--schema", SCHEMA, source], 1)
        assert not records and "ChecksumMismatch" in result.stderr

    assert all(hashlib.sha256(path.read_bytes()).hexdigest() == digest for path, digest in digests.items())
    print(f"Verified {cases} transaction CLI scenarios and 300 exported oracle column positions; inputs unchanged")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, default=EXE)
    main(parser.parse_args().executable.resolve())
