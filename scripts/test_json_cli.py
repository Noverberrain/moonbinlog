# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Check JSON precision, real mysqlbinlog images and CLI failure isolation."""

import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from generate_format_fixtures import event, fde
from generate_json_fixtures import TABLE_ID, container, document, field, fixtures, scalar, vectors
from generate_transaction_fixtures import query, stream
from verify_json_fixtures import FIXTURES, PROFILES, oracle_images

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / 'examples/mysql-8.0-json-schema.json'
EXE = ROOT / '_build/native/debug/build/cmd/moonbinlog/moonbinlog.exe'


def canonical(cell):
    if cell['state'] != 'value':
        return {'null': 'NULL', 'absent': 'ABSENT'}[cell['state']]
    if cell['type'] == 'integer':
        return cell['value']
    assert cell['type'] == 'json' and cell['encoding'] == 'json_text'
    assert type(cell['value']) is str
    return 'json:' + json.dumps(json.loads(cell['value']), ensure_ascii=False, separators=(',', ':'))


def main(executable):
    cases = 0

    def run(mode, path, schema=SCHEMA, options=(), code=0, error=None):
        nonlocal cases
        result = subprocess.run([str(executable), *mode, '--schema', str(schema),
                                 *options, str(path)], cwd=ROOT, capture_output=True,
                                text=True, encoding='utf-8', timeout=30)
        cases += 1
        assert result.returncode == code, (result.returncode, result.stdout, result.stderr)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        if code:
            assert result.stderr.startswith('moonbinlog:'), result.stderr
            assert not records, records  # No pending transaction or partial row event escapes.
            if error:
                assert error in result.stderr, result.stderr
        else:
            assert not result.stderr and records[-1]['kind'].endswith('_summary')
        return records

    paths = [SCHEMA, *FIXTURES.glob('*.binlog'), *FIXTURES.glob('*.mysqlbinlog.txt')]
    digests = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
    for profile in PROFILES:
        path = FIXTURES / f'{profile}.binlog'
        expected = oracle_images((FIXTURES / f'{profile}.mysqlbinlog.txt').read_bytes())
        for mode in [['--rows'], ['--transactions', '--include-rows']]:
            records = run(mode, path)
            changes = records[:-1] if mode == ['--rows'] else records[0]['row_changes']
            assert len(changes) == 6
            assert [change['operation'] for change in changes] == ['insert'] * 3 + ['update', 'delete', 'delete']
            images = []
            for change in changes:
                assert change['transaction_status'] == ('unconfirmed' if mode == ['--rows'] else 'committed')
                images += [[canonical(cell) for cell in change[side]]
                           for side in ['before', 'after'] if change[side] is not None]
            assert images == expected, (profile, images, expected)
            first = json.loads(changes[0]['after'][1]['value'])
            assert first['u'] == 2**64 - 1 and first['i'] == -2**63
            assert changes[1]['after'][1]['state'] == 'null'
            assert changes[2]['after'][1]['value'] == 'null'
            for options in [['--summary'], ['--database', 'moonbinlog_fixture', '--table', 'sample'],
                            ['--table', 'Sample']]:
                selected = run(mode, path, options=options)
                assert len(selected) == (len(records) if '--database' in options else 1)
                assert selected[-1]['events'] == 12

    with tempfile.TemporaryDirectory(prefix='json-cli-', dir=ROOT / '_build') as directory:
        work = Path(directory)
        source, schema_path = work / 'JSON样本.binlog', work / '配置.json'
        schema = json.loads(SCHEMA.read_text(encoding='utf-8'))
        schema['tables'][0]['database'] = 'shop'
        schema['tables'][0]['table'] = 'orders'
        schema_path.write_text(json.dumps(schema), encoding='utf-8')
        samples = fixtures()
        table, begin = samples['tm_json_rows'], query(b'BEGIN')
        xid = event(16, bytes(8))
        fixed = TABLE_ID.to_bytes(6, 'little') + struct.pack('<HH', 1, 2) + b'\x02\x03\0' + struct.pack('<i', 1)

        def scan(payload, mode=('--rows',), options=(), code=0, error=None, commit=True):
            row = event(30, fixed + field(payload))
            source.write_bytes(b'\xfebin' + stream([fde(), begin, table, row, *([xid] if commit else [])]))
            return run(mode, source, schema_path, options, code, error)

        valid, bad = vectors()
        for payload, text in valid:
            records = scan(payload)
            cell = records[0]['after'][1]
            assert cell['encoding'] == 'json_text' and type(cell['value']) is str
            actual, expected = json.loads(cell['value']), json.loads(text)
            assert actual == expected, (actual, expected)
            if text == '-0.0':
                assert math.copysign(1, actual) == -1 and cell['value'] == '-0.0'
        for payload in bad:
            scan(payload, code=1)
            scan(payload, mode=('--transactions', '--include-rows'), options=('--table', 'missing'), code=1)
        # Default recursion budget counts the root, including scalar leaves.
        nested = scalar(4, None)
        for _ in range(64):
            nested = container([nested])
        scan(document(nested), code=1, error='JsonLimitExceeded')
        scan(valid[-1][0], mode=('--transactions', '--include-rows'), commit=False, code=1)
        scan(valid[-1][0], mode=('--transactions', '--include-rows'))
        for mode in [('--rows',), ('--transactions', '--include-rows')]:
            scan(b'\x0f\xf6\0', mode=mode, options=('--summary',), code=1, error='UnsupportedJsonType')
            # Partial JSON row events remain unsupported even with a valid checksum.
            source.write_bytes(b'\xfebin' + stream([fde(), begin, table, event(39, fixed + field(valid[-1][0])), xid]))
            run(mode, source, schema_path, code=1)
            source.write_bytes(b'\xfebin' + stream([fde(), begin, table, event(30, fixed + b'\xff\xff\xff\xff'), xid]))
            run(mode, source, schema_path, code=1)
        source.write_bytes(b'\xfebin' + stream([fde(), begin, table, samples['rows_json_insert'], query(b'ROLLBACK')]))
        records = run(('--transactions', '--include-rows'), source, schema_path)
        assert records[0]['status'] == 'rolled_back' and 'row_changes' not in records[0]
        assert records[0]['discarded_changes'] == 3
    assert all(hashlib.sha256(path.read_bytes()).hexdigest() == digest for path, digest in digests.items())
    print(f'Passed {cases} JSON CLI scenarios, including 42 official column positions in both output modes')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=EXE)
    main(parser.parse_args().exe.resolve())
