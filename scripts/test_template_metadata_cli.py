# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Independently encode optional metadata and verify opt-in schema extraction."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from generate_format_fixtures import event, fde
from generate_table_map_fixtures import body, packed, tlv
from generate_transaction_fixtures import stream

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / '_build/native/debug/build/cmd/moonbinlog/moonbinlog.exe'


def names_bytes(names, width=None):
    return b''.join(packed(len(name.encode('utf-8')), width) + name.encode('utf-8') for name in names)


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
    with tempfile.TemporaryDirectory(prefix='template-metadata-', dir=ROOT / '_build') as directory:
        work = Path(directory)
        source, config = work / '元数据.binlog', work / '提取配置.json'
        for family, schema_name in [('mysql-8.0', 'mysql-8.0-schema.json'), ('mysql-json', 'mysql-8.0-json-schema.json')]:
            expected_path = ROOT / 'examples' / schema_name
            expected = json.loads(expected_path.read_text(encoding='utf-8'))
            for path in sorted((ROOT / 'fixtures' / family).glob('*.binlog')):
                text = run(['--schema-template', '--use-table-metadata', path])
                assert json.loads(text) == expected
                config.write_text(text, encoding='utf-8')
                for mode in [['--rows'], ['--transactions', '--include-rows']]:
                    actual = run([*mode, '--schema', config, path])
                    baseline = run([*mode, '--schema', expected_path, path])
                    assert [json.loads(line) for line in actual.splitlines()] == [json.loads(line) for line in baseline.splitlines()]

        kinds = bytes([0, 13, 15, 4, 246, 5, 1, 8, 2, 9, 3, 16])
        metadata = b'\x10\0\x04\x0a\x02\x08\0\x01'
        names = ['旧小数', '年份', '中文' * 90, 'float', 'decimal', 'double',
                 'tiny', 'big', 'small', 'medium', '整数"\\\n', '\ufeffbits']
        signedness = b'\xaa\x80'
        encoded_names = names_bytes(names)
        complete = tlv(1, signedness) + tlv(4, encoded_names)

        def table(optional=b''):
            return event(19, body(types=kinds, metadata=metadata, nullable=b'\xff\x0f', optional=optional))

        def scan(options, enabled=True, code=0, error=None):
            source.write_bytes(b'\xfebin' + stream([fde(), *[table(option) for option in options]]))
            text = run(['--schema-template', *(['--use-table-metadata'] if enabled else []), source], code, error)
            return json.loads(text)['tables'][0]['columns'] if code == 0 else None

        columns = scan([complete])
        assert [column['name'] for column in columns] == names
        assert [columns[i]['unsigned'] for i in [6, 7, 8, 9, 10]] == [False, True, False, True, False]
        assert all('unsigned' not in columns[i] for i in [0, 1, 2, 3, 4, 5, 11])
        for width in [2, 3, 8]:
            assert scan([tlv(4, names_bytes(names, width)) + tlv(1, signedness)]) == columns
        for options in [
            [b'', complete], [complete, b''], [tlv(4, encoded_names), tlv(1, signedness)],
            [tlv(1, signedness), tlv(4, encoded_names)], [complete] * 40,
            [complete, tlv(1, b'\xaa\xbf')],  # unused low padding bits are ignored
            [complete + tlv(255, b'\xff\xfb')],
        ]:
            assert scan(options) == columns
        names_only = scan([tlv(4, encoded_names)])
        assert [column['name'] for column in names_only] == names
        assert all(names_only[i]['unsigned'] is None for i in [6, 7, 8, 9, 10])
        signs_only = scan([tlv(1, signedness)])
        assert [column['name'] for column in signs_only] == [f'column_{i + 1}' for i in range(12)]
        assert [signs_only[i]['unsigned'] for i in [6, 7, 8, 9, 10]] == [False, True, False, True, False]
        assert scan([b'']) == scan([complete], enabled=False)
        renamed = names.copy()
        renamed[0] = 'changed'
        for conflict in [tlv(4, names_bytes(renamed)), tlv(1, b'\xae\x80')]:
            scan([complete, conflict], code=1, error='ConflictingTable')
        # Changing noninteger flags changes no exported schema signedness.
        assert scan([complete, tlv(1, b'\x2a\x80')]) == columns

        rest = names_bytes(names[1:])
        bad_names = [
            b'', encoded_names[:-1], encoded_names + b'\x01x', b'\0' + rest,
            b'\x01\xff' + rest, b'\x01\0' + rest, b'\xfb' + rest, b'\xff' + rest,
            b'\xfc\x01', b'\xfd\x01\0', b'\xfe' + b'\xff' * 8,
            names_bytes(['same'] * 12), names_bytes(['a' * 257, *names[1:]]),
            names_bytes(['😀' * 129, *names[1:]]),
        ]
        malformed = [tlv(4, value) for value in bad_names]
        malformed += [tlv(1, value) for value in [b'', b'\0', b'\0\0\0']]
        malformed += [tlv(4, encoded_names) * 2, tlv(1, signedness) * 2]
        for option in malformed:
            scan([complete, option], code=1, error='InvalidTemplateMetadata')
            scan([option], enabled=False)  # Legacy mode still treats TLV contents as opaque.
        # Valid TLVs may be omitted for tables with no numeric columns.
        source.write_bytes(b'\xfebin' + stream([fde(), event(19, body(types=b'\x06', metadata=b'', nullable=b'\1', optional=tlv(1, b'') + tlv(4, b'\x01x')))]))
        assert json.loads(run(['--schema-template', '--use-table-metadata', source]))['tables'][0]['columns'][0]['name'] == 'x'
        for args in [['--use-table-metadata', source],
                     ['--rows', '--schema', config, '--use-table-metadata', source],
                     ['--schema-template', '--use-table-metadata', '--use-table-metadata', source]]:
            run(args, 2)
        # Enrichment replaces, rather than appends, a table's output budget.
        # Missing -> long real labels eventually crosses the default output cap.
        base, enriched = [], []
        long_names = names_bytes([str(i) + 'a' * 255 for i in range(4)])
        for i in range(1024):
            args = dict(types=b'\x06' * 4, metadata=b'', nullable=b'\x0f', table=f't{i}'.encode())
            base.append(event(19, body(**args)))
            enriched.append(event(19, body(**args, optional=tlv(4, long_names))))
        source.write_bytes(b'\xfebin' + stream([fde(), *base, *enriched]))
        run(['--schema-template', '--use-table-metadata', source], 1, 'TemplateLimit')
        assert len(json.loads(run(['--schema-template', source]))['tables']) == 1024
    assert all(hashlib.sha256(path.read_bytes()).hexdigest() == digest for path, digest in digests.items())
    print(f'Passed {cases} template-metadata CLI scenarios; source captures unchanged')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=EXE)
    main(parser.parse_args().exe.resolve())
