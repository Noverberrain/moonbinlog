# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Check exact output selection without skipping validation or splitting transactions."""

import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from generate_format_fixtures import event
from generate_transaction_fixtures import query, stream
from test_transactions_cli import packets

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "fixtures/mysql-8.0"
SCHEMA = ROOT / "examples/mysql-8.0-schema.json"
EXE = ROOT / "_build/native/debug/build/cmd/moonbinlog/moonbinlog.exe"


def main(executable):
    cases = 0

    def run(args, code=0, error=None):
        nonlocal cases
        result = subprocess.run([str(executable), *map(str, args)], cwd=ROOT,
                                capture_output=True, text=True, encoding="utf-8", timeout=30)
        cases += 1
        assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        if code:
            assert result.stderr.startswith("moonbinlog:"), result.stderr
            assert all(record["kind"] in {"row_change", "transaction"} for record in records)
            if error:
                assert error in result.stderr, result.stderr
        else:
            assert result.stderr == "" and records[-1]["kind"] in {"row_summary", "transaction_summary"}
        return records

    paths = [SCHEMA, *FIXTURES.glob("*.binlog")]
    digests = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
    full = FIXTURES / "crc32-full.binlog"
    for args in [
        ["--database", "shop", full], ["--table", "sample", "--json", full],
        ["--rows", "--schema", SCHEMA, "--table", "", full],
        ["--rows", "--schema", SCHEMA, full, "--database"],
        ["--rows", "--schema", SCHEMA, "--database", "a", "--database", "a", full],
        ["--transactions", "--schema", SCHEMA, "--table", "a", "--table", "b", full],
        ["--rows", "--schema", SCHEMA, "--table", "x" * 257, full],
    ]:
        assert not run(args, 2)

    modes = [["--rows"], ["--transactions"], ["--transactions", "--include-rows"]]
    for path in sorted(FIXTURES.glob("*.binlog")):
        for mode in modes:
            for selection, matched in [
                (["--database", "moonbinlog_fixture"], True),
                (["--database", "moonbinlog_fixture", "--table", "sample"], True),
                (["--table", "Sample"], False),
            ]:
                for summary_only in [False, True]:
                    records = run([*mode, "--schema", SCHEMA, *selection,
                                   *(["--summary"] if summary_only else []), path])
                    summary = records[-1]
                    assert summary["events"] == 14 and summary["file_bytes"] == path.stat().st_size
                    assert summary["filter"]["table"] == ("Sample" if not matched else "sample" if "--table" in selection else None)
                    if mode == ["--rows"]:
                        assert summary["filter"]["scope"] == "row_events"
                        assert summary["row_events"] == summary["changes"] == 4
                        assert summary["selected_row_events"] == summary["selected_changes"] == (4 if matched else 0)
                        assert len(records) == (5 if matched and not summary_only else 1)
                    else:
                        assert summary["filter"]["scope"] == "whole_transactions"
                        assert summary["committed_transactions"] == 1 and summary["committed_changes"] == 4
                        assert summary["selected_committed_transactions"] == int(matched)
                        assert summary["selected_committed_row_events"] == summary["selected_committed_changes"] == (4 if matched else 0)
                        assert len(records) == (2 if matched and not summary_only else 1)
                        if matched and not summary_only and "--include-rows" in mode:
                            assert len(records[0]["row_changes"]) == 4

    original = packets(full.read_bytes())
    fde, begin, table, rows, xid = [original[i] for i in [0, 3, 4, 5, 12]]
    with tempfile.TemporaryDirectory(prefix="filters-cli-", dir=ROOT / "_build") as directory:
        work = Path(directory)
        source, schema_path = work / "筛选.binlog", work / "配置.json"
        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        second = copy.deepcopy(schema["tables"][0])
        second["table"] = "second"
        schema["tables"].append(second)
        schema_path.write_text(json.dumps(schema), encoding="utf-8")
        second_table = event(19, table[19:-4].replace(b"sample", b"second"))
        mixed = [begin, table, rows, second_table, rows, xid]

        def scan(parts, mode, selection, code=0, error=None, schema_file=schema_path):
            source.write_bytes(b"\xfebin" + stream([fde, *parts]))
            return run([*mode, "--schema", schema_file, *selection, source], code, error)

        for name in ["sample", "second"]:
            records = scan(mixed, ["--rows"], ["--table", name])
            assert len(records) == 2 and records[0]["table"] == name
            assert records[-1]["row_events"] == 2 and records[-1]["selected_changes"] == 1
            for mode in modes[1:]:
                records = scan(mixed, mode, ["--table", name])
                assert len(records) == 2 and records[0]["changes"] == 2
                assert [item["table"] for item in records[0]["tables"]] == ["sample", "second"]
                assert records[-1]["selected_committed_changes"] == 2
                if "--include-rows" in mode:
                    assert [change["table"] for change in records[0]["row_changes"]] == ["sample", "second"]
                    assert records[0]["row_changes"][0]["table_id"] == records[0]["row_changes"][1]["table_id"]
        records = scan([*mixed, begin, table, rows, query(b"ROLLBACK"), begin, query(b"COMMIT")],
                       ["--transactions", "--include-rows"], ["--table", "sample"])
        assert len(records) == 3 and records[1]["status"] == "rolled_back"
        assert "row_changes" not in records[1] and records[1]["discarded_changes"] == 1
        assert records[-1]["committed_transactions"] == 2 and records[-1]["selected_committed_transactions"] == 1
        assert records[-1]["selected_rolled_back_transactions"] == 1 and records[-1]["selected_discarded_changes"] == 1
        records = scan([begin, second_table, rows, query(b"ROLLBACK")], ["--transactions"], ["--table", "sample"])
        assert len(records) == 1 and records[-1]["rolled_back_transactions"] == 1
        assert records[-1]["selected_rolled_back_transactions"] == 0
        records = scan([begin, table, query(b"ROLLBACK")], ["--transactions"], ["--table", "sample"])
        assert len(records) == 1  # TABLE_MAP alone does not select a transaction.
        records = scan(mixed, ["--rows"], ["--database", "wrong", "--table", "sample"])
        assert len(records) == 1 and records[-1]["selected_changes"] == 0

        # Exact Unicode/punctuation names are not split, globbed or interpreted as SQL.
        unusual = '表.名*"\\'
        special = copy.deepcopy(schema)
        special["tables"][1]["table"] = unusual
        schema_path.write_text(json.dumps(special, ensure_ascii=False), encoding="utf-8")
        body = second_table[19:-4]
        marker = b"\x06second\x00"
        assert body.count(marker) == 1
        encoded = unusual.encode()
        special_table = event(19, body.replace(marker, bytes([len(encoded)]) + encoded + b"\0"))
        records = scan([begin, special_table, rows, xid], ["--rows"], ["--table", unusual])
        assert records[0]["table"] == unusual and records[-1]["selected_changes"] == 1
        schema_path.write_text(json.dumps(schema), encoding="utf-8")

        # Nonmatching events still require schema, valid row semantics and complete EOF.
        bad_body = bytearray(rows[19:-4])
        bad_body[10] = 19
        for mode in modes:
            scan([begin, table, event(30, bad_body), xid], mode, ["--table", "absent"], 1, "InvalidRowsEvent")
            scan(mixed, mode, ["--table", "absent"], 1, "MissingTableSchema", schema_file=SCHEMA)
            scan([begin, table, rows, event(255, b"unknown"), xid], mode, ["--table", "absent"], 1,
                 "UnsupportedEvent" if mode == ["--rows"] else "UnsupportedTransactionEvent")
        for mode in modes[1:]:
            assert not scan(mixed[:-1], mode, ["--table", "absent"], 1, "IncompleteTransaction")
            assert not scan([begin, table, rows, fde], mode, ["--table", "absent"], 1, "IncompleteTransaction")
        source.write_bytes(b"\xfebin" + stream([fde, *mixed])[:-1])
        for mode in modes:
            assert not run([*mode, "--schema", schema_path, "--table", "absent", source], 1, "TruncatedEvent")
        # A completed selected prefix is retained when a later unselected span fails.
        records = scan([*mixed, begin, second_table, rows], modes[2], ["--table", "sample"], 1, "IncompleteTransaction")
        assert len(records) == 1 and len(records[0]["row_changes"]) == 2

    assert all(hashlib.sha256(path.read_bytes()).hexdigest() == digest for path, digest in digests.items())
    print(f"Verified {cases} output filter CLI scenarios; input fixtures unchanged")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, default=EXE)
    main(parser.parse_args().executable.resolve())
