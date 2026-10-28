# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Validate opt-in GTID-bound transaction reports, rows, filters and EOF."""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from generate_format_fixtures import event
from generate_gtid_fixtures import fixtures, gtid_fde
from generate_transaction_fixtures import query, stream
from test_gtid_cli import details
from test_transactions_cli import packets

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / '_build/native/debug/build/cmd/moonbinlog/moonbinlog.exe'
SCHEMA = ROOT / 'examples/mysql-8.0-schema.json'


def main(executable):
    cases = 0

    def run(args, code=0, error=None):
        nonlocal cases
        result = subprocess.run([str(executable), *map(str, args)], cwd=ROOT,
                                capture_output=True, text=True, encoding='utf-8', timeout=45)
        cases += 1
        assert result.returncode == code, (args, result.returncode, result.stdout[:1200], result.stderr)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        if code:
            assert result.stderr.startswith('moonbinlog:'), result.stderr
            assert all(r['kind'] == 'transaction' for r in records), records
            if code == 2 or '--summary' in args:
                assert not records
            if error:
                assert error in result.stderr, result.stderr
        else:
            assert not result.stderr and records[-1]['kind'] == 'transaction_summary'
        return records

    def tx(path, options=(), schema=SCHEMA, bound=True, code=0, error=None):
        return run(['--transactions', '--schema', schema, *(['--with-gtid'] if bound else []),
                    *options, '--', path], code, error)

    def compare(bound, original, expected=None):
        assert bound[-1] == original[-1]
        assert len(bound) == len(original)
        for record, old in zip(bound[:-1], original[:-1]):
            record = dict(record)
            payload, span = record.pop('gtid'), record.pop('gtid_span')
            if expected is not None:
                assert payload == details(expected)
            assert int(span['start_offset']) < int(record['start_offset'])
            assert span['end_offset'] == record['end_offset']
            assert int(span['end_offset']) - int(span['start_offset']) == int(span['event_bytes'])
            if record['status'] == 'committed':
                assert span['events'] == record['events'] + 1
                assert int(span['event_bytes']) > int(record['event_bytes'])
            else:
                assert 'row_changes' not in record
            assert record == old

    captures = sorted(ROOT.glob('fixtures/mysql-*/*.binlog'))
    hashes = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in captures}
    oracles = json.loads((ROOT / 'fixtures/gtid/manifest.json').read_text(encoding='utf-8'))['real_anonymous_oracles']
    for oracle in oracles:
        path = ROOT / 'fixtures' / (oracle['capture'] + '.binlog')
        schema = ROOT / ('examples/mysql-8.0-json-schema.json' if oracle['capture'].startswith('mysql-json/') else 'examples/mysql-8.0-schema.json')
        for options in [[], ['--include-rows'], ['--summary'], ['--summary', '--include-rows'],
                        ['--include-rows', '--table', 'sample'], ['--summary', '--table', 'absent']]:
            original = tx(path, options, schema, bound=False)
            bound = tx(path, options, schema)
            compare(bound, original, oracle['expected'])
            if len(bound) > 1:
                assert bound[0]['gtid_span']['start_offset'] == str(oracle['offset'])

    original = packets((ROOT / 'fixtures/mysql-8.0/crc32-full.binlog').read_bytes())
    committed = original[3:13]
    valid, invalid = fixtures()
    with tempfile.TemporaryDirectory(prefix='gtid-tx-cli-', dir=ROOT / '_build') as directory:
        work = Path(directory)
        source = work / '事务 绑定.binlog'

        def write(parts, checksum=True):
            source.write_bytes(b'\xfebin' + stream([gtid_fde(int(checksum)), *parts], checksum=checksum))

        for kind, payload, expected in valid.values():
            for checksum in [True, False]:
                body = committed if checksum else [event(p[4], p[19:-4], checksum=False,
                        flags=struct.unpack_from('<H', p, 17)[0]) for p in committed]
                write([event(kind, payload, checksum=checksum), *body], checksum)
                for options in [[], ['--include-rows']]:
                    compare(tx(source, options), tx(source, options, bound=False), expected)
        prefix = event(33, valid['full'][1])
        anonymous = event(34, valid['anonymous'][1])
        for kind, payload in invalid.values():
            write([event(kind, payload), *committed])
            tx(source, bound=False)
            tx(source, code=1, error='InvalidGtidEvent')
            tx(source, ['--summary', '--table', 'absent'], code=1, error='InvalidGtidEvent')
        for parts in [[prefix], [prefix, *committed[:-1]], committed,
                      [prefix, prefix, *committed], [prefix, gtid_fde()],
                      [prefix, committed[0], prefix], [prefix, event(199, b'unknown')],
                      [prefix, *committed[:2], query(b'INSERT INTO t VALUES (1)')]]:
            write(parts)
            tx(source, code=1)
            tx(source, ['--summary'], code=1)
        # Original transactions without a GTID prefix remain valid only in legacy mode.
        write(committed)
        tx(source, bound=False)
        # Repeated assigned GTIDs are associated separately, never deduplicated.
        write([prefix, *committed, prefix, *committed, anonymous, *committed[:-1], query(b'ROLLBACK')])
        records = tx(source, ['--include-rows'])
        assert len(records) == 4
        assert records[0]['gtid']['identity'] == records[1]['gtid']['identity']
        assert records[2]['gtid']['identity'] is None and records[2]['status'] == 'rolled_back'
        assert 'row_changes' not in records[2]
        compare(records, tx(source, ['--include-rows'], bound=False))
        # Successful previous transactions may be emitted before a later incomplete span.
        write([prefix, *committed, prefix])
        assert len(tx(source, code=1, error='IncompleteGtidTransaction')) == 1
        tx(source, ['--summary'], code=1, error='IncompleteGtidTransaction')
        # Empty transactions do not match table filters; an empty file span needs no GTID.
        write([prefix, query(b'BEGIN'), query(b'COMMIT')])
        records = tx(source, ['--table', 'sample'])
        assert len(records) == 1 and records[0]['selected_committed_transactions'] == 0
        write([])
        compare(tx(source), tx(source, bound=False))
        # Missing schema for an unselected table must still fail.
        missing = work / 'empty.json'
        missing.write_text('{"schema_version":1,"tables":[]}', encoding='utf-8')
        write([prefix, *committed])
        tx(source, ['--table', 'absent'], schema=missing, code=1)
        for options in [['--max-event-bytes', '19'], ['--max-file-bytes', '4']]:
            tx(source, options, code=1)
        damaged = bytearray(prefix)
        damaged[-1] ^= 1
        source.write_bytes(b'\xfebin' + gtid_fde() + damaged)
        tx(source, ['--summary'], code=1, error='ChecksumMismatch')
        for options in [[], ['--summary'], ['--rows', '--schema', SCHEMA], ['--schema-template'],
                        ['--transactions'], ['--chain', 'another'],
                        ['--transactions', '--schema', SCHEMA, '--with-gtid'],
                        ['--transactions', '--schema', SCHEMA, '--decode-gtid'],
                        ['--transactions', '--schema', SCHEMA, '--decode-rotate'],
                        ['--transactions', '--schema', SCHEMA, '--decode-previous-gtids']]:
            run(['--with-gtid', *options, source], 2)
    assert all(hashlib.sha256(p.read_bytes()).hexdigest() == digest for p, digest in hashes.items())
    print(f'Passed {cases} GTID-bound transaction CLI scenarios; six captures unchanged')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=EXE)
    main(parser.parse_args().exe.resolve())
