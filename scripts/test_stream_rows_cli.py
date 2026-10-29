# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Check streamed rows against existing output, failures and a >64 MiB input."""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import zlib

sys.dont_write_bytecode = True
from generate_format_fixtures import event
from test_transactions_cli import packets

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / '_build/native/debug/build/cmd/moonbinlog/moonbinlog.exe'
SCHEMA = ROOT / 'examples/mysql-8.0-schema.json'


def main(executable):
    cases = 0

    def run(args, code=0, error=None):
        nonlocal cases
        result = subprocess.run([str(executable), *map(str, args)], cwd=ROOT,
                                capture_output=True, text=True, encoding='utf-8', timeout=90)
        cases += 1
        assert result.returncode == code, (args, result.returncode, result.stdout[:1000], result.stderr)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        if code:
            assert result.stderr.startswith('moonbinlog:'), result.stderr
            assert all(record['kind'] == 'row_change' for record in records)
            if '--summary' in args:
                assert not records
            if error:
                assert error in result.stderr, result.stderr
        else:
            assert not result.stderr and records[-1]['kind'] == 'row_summary'
            assert all(record['transaction_status'] == 'unconfirmed' for record in records)
        return result, records

    def compare(path, schema=SCHEMA, options=(), code=0, error=None):
        args = ['--rows', '--schema', schema, *options, path]
        old, records = run(args, code, error)
        streamed, actual = run(['--stream', *args], code, error)
        assert streamed.stdout == old.stdout
        assert actual == records
        return records

    paths = sorted(p for folder in ['mysql-8.0', 'mysql-json', 'gtid-real']
                   for p in (ROOT / 'fixtures' / folder).glob('*.binlog'))
    hashes = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    for path in paths:
        schema = SCHEMA if path.parent.name == 'mysql-8.0' else ROOT / 'examples/mysql-8.0-json-schema.json'
        for options in [[], ['--summary'], ['--json'],
                        ['--database', 'moonbinlog_fixture', '--table', 'sample'],
                        ['--database', 'other'], ['--table', 'SAMPLE', '--summary'],
                        ['--max-file-bytes', str(path.stat().st_size)]]:
            compare(path, schema, options)
        compare(path, schema, ['--max-file-bytes', str(path.stat().st_size - 1)], 1, 'InvalidFile')
        compare(path, schema, ['--max-event-bytes', '19'], 1, 'EventTooLarge')

    original = (ROOT / 'fixtures/mysql-8.0/crc32-full.binlog').read_bytes()
    chunks = packets(original)
    row_index = next(i for i, chunk in enumerate(chunks) if chunk[4] in (30, 31, 32))
    with tempfile.TemporaryDirectory(prefix='stream-rows-cli-', dir=ROOT / '_build') as directory:
        source = Path(directory) / '行日志.binlog'
        bad_schema = Path(directory) / '配置.json'
        source.write_bytes(original)
        for contents, error in [(b'{}', 'InvalidSchema'), (b'\xff', None),
                                (b'{"schema_version":1,"tables":[]}', 'MissingTableSchema'),
                                (b' ' * 4_194_305, 'exceeds limit')]:
            bad_schema.write_bytes(contents)
            compare(source, bad_schema, code=1, error=error)
        compare(source, Path(directory) / 'missing.json', code=1)
        wrong = json.loads(SCHEMA.read_text(encoding='utf-8'))
        wrong['tables'][0]['columns'][0]['wire_type'] = 8
        bad_schema.write_text(json.dumps(wrong), encoding='utf-8')
        compare(source, bad_schema, ['--database', 'other', '--summary'], 1, 'SchemaMismatch')
        names = json.loads(SCHEMA.read_text(encoding='utf-8'))
        names['tables'][0]['columns'][0]['name'] = '列"\\\n'
        bad_schema.write_bytes(b'\xef\xbb\xbf' + json.dumps(names, ensure_ascii=False).encode())
        assert compare(source, bad_schema)[0]['after'][0]['name'] == '列"\\\n'

        # Every header prefix of the first ROWS event must fail without a summary.
        prefix = original[:4 + sum(map(len, chunks[:row_index]))]
        for size in range(1, 19):
            source.write_bytes(prefix + chunks[row_index][:size])
            compare(source, options=['--summary'], code=1, error='TruncatedInput')
        variants = []
        corrupt = bytearray(chunks[row_index])
        corrupt[-1] ^= 1
        variants.append((prefix + corrupt, 'ChecksumMismatch'))
        malformed = bytearray(chunks[row_index])
        malformed[29] = 19  # wrong column count, with a correct CRC
        struct.pack_into('<I', malformed, len(malformed) - 4, zlib.crc32(malformed[:-4]))
        variants.append((prefix + malformed, 'InvalidRowsEvent'))
        variants.append((b'\xfebin' + chunks[0] + chunks[row_index], 'MissingTableMap'))
        variants.append((original[:-1], 'TruncatedEvent'))
        variants.append((original + event(199, b''), 'UnsupportedEvent'))
        for data, error in variants:
            source.write_bytes(data)
            for options in [[], ['--summary'], ['--database', 'other'],
                            ['--table', 'missing', '--summary']]:
                compare(source, options=options, code=1, error=error)
        # Complete ROWS EOF remains unconfirmed, independent of a later XID.
        source.write_bytes(prefix + chunks[row_index])
        records = compare(source)
        assert records[-1]['row_events'] == 1
        # Replacing the FDE clears old table maps; decoding cannot reuse them.
        source.write_bytes(prefix + chunks[0] + chunks[row_index])
        compare(source, code=1, error='MissingTableMap')
        # A CRC32 -> OFF format switch must decode both sets of row values.
        off = (ROOT / 'fixtures/mysql-8.0/off-full.binlog').read_bytes()
        source.write_bytes(original + off[4:])
        assert compare(source)[-1]['row_events'] == 8

        # Build incrementally. Envelopes are explicitly accepted by row mode;
        # they pad input size without manufacturing millions of output rows.
        packet = event(3, bytes(1_048_576))
        with source.open('wb') as output:
            output.write(b'\xfebin' + chunks[0])
            for _ in range(65):
                output.write(packet)
            output.write(b''.join(chunks[1:]))
        size = source.stat().st_size
        assert size > 67_108_864
        compare(source, options=['--summary'], code=1, error='InvalidFile')
        options = ['--max-file-bytes', str(size)]
        records = compare(source, options=options)
        assert records[-1]['file_bytes'] == size and records[-1]['row_events'] == 4
        compare(source, options=[*options, '--summary', '--database', 'other'])

    assert all(hashlib.sha256(p.read_bytes()).hexdigest() == digest for p, digest in hashes.items())
    print(f'Passed {cases} streamed-row CLI scenarios, including a {size}-byte file; nine captures unchanged')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=EXE)
    main(parser.parse_args().exe.resolve())
