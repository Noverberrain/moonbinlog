# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Compare streamed explicit transactions with in-memory reports and failures."""

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
            assert all(record['kind'] == 'transaction' for record in records)
            if '--summary' in args:
                assert not records
            if error:
                assert error in result.stderr, result.stderr
        else:
            assert not result.stderr and records[-1]['kind'] == 'transaction_summary'
        return result, records

    def compare(path, schema=SCHEMA, options=(), code=0, error=None):
        args = ['--transactions', '--schema', schema, *options, path]
        old, records = run(args, code, error)
        actual, _ = run(['--stream', *args], code, error)
        assert actual.stdout == old.stdout
        return records

    paths = sorted(p for folder in ['mysql-8.0', 'mysql-json', 'gtid-real']
                   for p in (ROOT / 'fixtures' / folder).glob('*.binlog'))
    hashes = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    for path in paths:
        schema = SCHEMA if path.parent.name == 'mysql-8.0' else ROOT / 'examples/mysql-8.0-json-schema.json'
        for bound in [[], ['--with-gtid']]:
            for options in [[], ['--include-rows'], ['--summary'], ['--include-rows', '--summary'],
                            ['--include-rows', '--database', 'moonbinlog_fixture', '--table', 'sample'],
                            ['--table', 'SAMPLE'], ['--database', 'other', '--summary']]:
                compare(path, schema, [*bound, *options])
            for options, code, error in [
                (['--max-file-bytes', str(path.stat().st_size)], 0, None),
                (['--max-file-bytes', str(path.stat().st_size - 1)], 1, 'InvalidFile'),
                (['--max-event-bytes', '19'], 1, 'EventTooLarge'),
            ]:
                compare(path, schema, [*bound, *options], code, error)

    original = packets((ROOT / 'fixtures/mysql-8.0/crc32-full.binlog').read_bytes())
    committed = original[3:13]  # BEGIN, four TABLE_MAP/ROWS pairs, XID
    valid, invalid = fixtures()
    prefix = event(33, valid['full'][1])
    anonymous = event(34, valid['anonymous'][1])
    with tempfile.TemporaryDirectory(prefix='stream-tx-cli-', dir=ROOT / '_build') as directory:
        source = Path(directory) / '事务日志.binlog'
        bad_schema = Path(directory) / '配置.json'

        def write(parts, checksum=True):
            source.write_bytes(b'\xfebin' + stream([gtid_fde(int(checksum)), *parts], checksum=checksum))

        # Distinct event allocations must preserve rows until COMMIT and release
        # rolled-back rows; repeated identities are not a deduplication rule.
        for checksum in [True, False]:
            parts = [prefix, *committed, prefix, *committed,
                     anonymous, *committed[:-1], query(b'ROLLBACK')]
            if not checksum:
                parts = [event(p[4], p[19:-4], False, flags=struct.unpack_from('<H', p, 17)[0]) for p in parts]
            write(parts, checksum)
            for bound in [[], ['--with-gtid']]:
                records = compare(source, options=[*bound, '--include-rows'])
                assert len(records) == 4
                assert [{k: v for k, v in row.items() if k != 'offset'} for row in records[0]['row_changes']] == [
                    {k: v for k, v in row.items() if k != 'offset'} for row in records[1]['row_changes']]
                assert records[2]['status'] == 'rolled_back' and 'row_changes' not in records[2]
                if bound:
                    assert records[0]['gtid']['identity'] == records[1]['gtid']['identity']
                    assert records[2]['gtid']['identity'] is None
                compare(source, options=[*bound, '--table', 'absent', '--summary'])
        write([prefix, query(b'BEGIN'), query(b'COMMIT')])
        for bound in [[], ['--with-gtid']]:
            records = compare(source, options=[*bound, '--table', 'sample'])
            assert len(records) == 1 and records[-1]['selected_committed_transactions'] == 0

        # EOF before the terminal event must not emit the pending transaction.
        for parts in [[prefix], [prefix, *committed[:-1]],
                      [prefix, *committed, prefix],
                      [prefix, *committed, prefix, *committed[:-1]],
                      [prefix, prefix], [prefix, gtid_fde()],
                      [prefix, committed[0], event(199, b'unknown')],
                      [prefix, committed[0], query(b'INSERT INTO t VALUES (1)')]]:
            write(parts)
            for options in [['--with-gtid', '--include-rows'],
                            ['--with-gtid', '--summary', '--table', 'absent']]:
                compare(source, options=options, code=1)
        write(committed[:-1])
        compare(source, code=1, error='IncompleteTransaction')
        write(committed)
        compare(source)
        compare(source, options=['--with-gtid'], code=1)
        for kind, payload in list(invalid.values())[:8]:
            write([event(kind, payload), *committed])
            compare(source)  # legacy envelope semantics remain unchanged
            compare(source, options=['--with-gtid', '--summary', '--table', 'absent'],
                    code=1, error='InvalidGtidEvent')
        write([prefix, *committed])
        complete = source.read_bytes()
        for end in range(len(complete) - len(committed[-1]) + 1, len(complete)):
            source.write_bytes(complete[:end])
            compare(source, options=['--with-gtid', '--include-rows'], code=1)
        corrupt = bytearray(complete)
        corrupt[-1] ^= 1
        source.write_bytes(corrupt)
        compare(source, options=['--with-gtid', '--summary'], code=1, error='ChecksumMismatch')
        for contents, error in [(b'{}', 'InvalidSchema'), (b'\xff', None),
                                (b'{"schema_version":1,"tables":[]}', 'MissingTableSchema'),
                                (b' ' * 4_194_305, 'exceeds limit')]:
            source.write_bytes(complete)
            bad_schema.write_bytes(contents)
            compare(source, bad_schema, ['--with-gtid', '--table', 'absent', '--summary'], 1, error)
        write([prefix, committed[0], *([committed[1]] * 4095), committed[-1]])
        for bound in [[], ['--with-gtid']]:
            compare(source, options=[*bound, '--summary'], code=1, error='TransactionLimitExceeded')
        # A new OFF FDE follows a complete CRC32 transaction. Each segment
        # retains its own valid CRC policy; physical offsets come from framing.
        first = stream([gtid_fde(), prefix, *committed])
        second = gtid_fde(0) + b''.join(
            event(p[4], p[19:-4], False, flags=struct.unpack_from('<H', p, 17)[0])
            for p in [prefix, *committed])
        source.write_bytes(b'\xfebin' + first + second)
        compare(source, options=['--with-gtid', '--include-rows'])

        # >64 MiB file, mostly idle envelopes; pending transaction limits remain.
        padding = event(3, bytes(1_048_576))
        with source.open('wb') as output:
            output.write(b'\xfebin' + original[0])
            for _ in range(65):
                output.write(padding)
            output.write(b''.join(original[1:]))
        size = source.stat().st_size
        assert size > 67_108_864
        compare(source, options=['--summary'], code=1, error='InvalidFile')
        for bound in [[], ['--with-gtid']]:
            records = compare(source, options=[*bound, '--max-file-bytes', str(size), '--include-rows'])
            assert records[-1]['file_bytes'] == size and len(records) == 2
            compare(source, options=[*bound, '--max-file-bytes', str(size), '--summary', '--table', 'absent'])
    assert all(hashlib.sha256(p.read_bytes()).hexdigest() == digest for p, digest in hashes.items())
    print(f'Passed {cases} streamed-transaction CLI scenarios, including a {size}-byte file; nine captures unchanged')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=EXE)
    main(parser.parse_args().exe.resolve())
