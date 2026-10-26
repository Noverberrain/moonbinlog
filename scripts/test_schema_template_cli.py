# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Verify physical schema drafts, explicit review and all-or-nothing output."""

import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from generate_format_fixtures import event, fde
from generate_table_map_fixtures import body, fixtures as table_fixtures, tlv
from generate_transaction_fixtures import query, stream

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / '_build/native/debug/build/cmd/moonbinlog/moonbinlog.exe'


def main(executable):
    cases = 0

    def run(args, code=0, error=None):
        nonlocal cases
        result = subprocess.run([str(executable), *map(str, args)], cwd=ROOT,
                                capture_output=True, text=True, encoding='utf-8', timeout=30)
        cases += 1
        assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
        if code:
            assert result.stdout == '' and result.stderr.startswith('moonbinlog:'), result
            if error:
                assert error in result.stderr, result.stderr
        else:
            assert not result.stderr, result.stderr
        return result.stdout

    paths = [*ROOT.glob('fixtures/mysql-*/*.binlog'), *ROOT.glob('examples/*schema.json')]
    digests = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
    with tempfile.TemporaryDirectory(prefix='schema-template-', dir=ROOT / '_build') as directory:
        work = Path(directory)
        source, reviewed_path = work / '--日志.binlog', work / '确认后的配置.json'
        for family, schema_name in [('mysql-8.0', 'mysql-8.0-schema.json'),
                                    ('mysql-json', 'mysql-8.0-json-schema.json')]:
            expected = json.loads((ROOT / 'examples' / schema_name).read_text(encoding='utf-8'))
            for path in sorted((ROOT / 'fixtures' / family).glob('*.binlog')):
                text = run(['--schema-template', path])
                draft = json.loads(text)
                assert set(draft) == {'schema_version', 'tables'}
                assert draft['schema_version'] == 1 and len(draft['tables']) == 1
                want = copy.deepcopy(expected)
                for i, column in enumerate(want['tables'][0]['columns']):
                    column['name'] = f'column_{i + 1}'
                    if 'unsigned' in column:
                        column['unsigned'] = None
                assert draft == want, (path, draft, want)
                assert json.loads(run([path, '--schema-template', '--json'])) == draft
                reviewed_path.write_text(text, encoding='utf-8')
                run(['--rows', '--schema', reviewed_path, path], 1, 'InvalidSchema')
                # Confirm names and signedness using this test table's known DDL.
                for got, original in zip(draft['tables'][0]['columns'], expected['tables'][0]['columns']):
                    got['name'] = original['name']
                    if 'unsigned' in original:
                        got['unsigned'] = original['unsigned']
                reviewed_path.write_text(json.dumps(draft), encoding='utf-8')
                for mode in [['--rows'], ['--transactions', '--include-rows']]:
                    actual = run([*mode, '--schema', reviewed_path, path])
                    original = run([*mode, '--schema', ROOT / 'examples' / schema_name, path])
                    assert [json.loads(line) for line in actual.splitlines()] == [json.loads(line) for line in original.splitlines()]

        def scan(parts, options=(), code=0, error=None):
            source.write_bytes(b'\xfebin' + stream([fde(), *parts]))
            return run(['--schema-template', *options, '--', source], code, error)

        maps = table_fixtures()
        basic = maps['tm_basic']
        draft = json.loads(scan([basic, maps['tm_second_id'], maps['tm_optional'],
                                 maps['tm_padding_bits'], maps['tm_renamed'], maps['tm_unicode']]))
        assert [(t['database'], t['table']) for t in draft['tables']] == [
            ('shop', 'orders'), ('shop', 'orders_archive'), ('商店', '订单')]
        assert draft['tables'][0]['columns'][0]['name'] == 'column_1'
        # Exact name pairs do not collide; table IDs and optional metadata aren't identities.
        unusual = '表.名*"\\\n'
        raw = [event(19, body(database=db.encode(), table=name.encode()))
               for db, name in [('a.b', 'c'), ('a', 'b.c'), ('库', unusual)]]
        result = json.loads(scan(raw))
        assert [(t['database'], t['table']) for t in result['tables']] == [('a.b', 'c'), ('a', 'b.c'), ('库', unusual)]
        renamed_metadata = event(19, body(optional=tlv(4, b'\x02id')))
        assert len(json.loads(scan([basic, renamed_metadata]))['tables']) == 1
        for changed in [body(metadata=b'\x59\x02\x0a\x02\x06\x04'),
                        body(nullable=b'\x94\x01'),
                        body(types=b'\x03', metadata=b'', nullable=b'\0')]:
            for envelope in [[], [query(b'ALTER TABLE orders ADD COLUMN x INT')], [fde()]]:
                scan([basic, *envelope, event(19, changed)], code=1, error='ConflictingTable')
        for name in ['tm_short_metadata', 'tm_zero_columns', 'tm_short_tlv',
                     'tm_invalid_utf8', 'tm_empty_name', 'tm_nul_name', 'tm_unknown_type']:
            scan([basic, maps[name]], code=1)
        # Other bodies are deliberately opaque in schema discovery mode.
        assert json.loads(scan([event(199, b'opaque'), event(30, b'not-a-valid-row')]))['tables'] == []
        assert json.loads(scan([])) == {'schema_version': 1, 'tables': []}
        scan([basic], options=['--max-file-bytes', '4'], code=1)
        scan([basic], options=['--max-event-bytes', '19'], code=1)
        for extra in [['--summary'], ['--schema', reviewed_path], ['--rows'],
                      ['--transactions', '--schema', reviewed_path], ['--include-rows'],
                      ['--database', 'shop'], ['--table', 'orders'], ['--schema-template']]:
            scan([basic], options=extra, code=2)
        for changed in [b'bad!', b'\xfebin', b'\xfebin' + fde()[:-1]]:
            source.write_bytes(changed)
            run(['--schema-template', source], 1)
        valid = b'\xfebin' + stream([fde(), basic, event(199, b'unknown')])
        corrupted = bytearray(valid)
        corrupted[-1] ^= 1
        for changed in [bytes(corrupted), valid[:-1], valid + b'\0']:
            source.write_bytes(changed)
            run(['--schema-template', source], 1)
        # Table limit is independent of reused table_id, with no partial result on failure.
        many = [event(19, body(types=b'\x06', metadata=b'', nullable=b'\1', table=f't{i}'.encode()))
                for i in range(1025)]
        assert len(json.loads(scan(many[:1024]))['tables']) == 1024
        scan(many, code=1, error='TemplateLimit')
        wide = [event(19, body(types=b'\x06' * 16, metadata=b'', nullable=b'\xff\xff', table=f't{i}'.encode()))
                for i in range(1024)]
        scan(wide, code=1, error='TemplateLimit')
    assert all(hashlib.sha256(path.read_bytes()).hexdigest() == digest for path, digest in digests.items())
    print(f'Passed {cases} schema-template CLI scenarios; six real captures and reviewed drafts verified')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=EXE)
    main(parser.parse_args().exe.resolve())
