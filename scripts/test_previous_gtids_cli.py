# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Verify opt-in historical GTID JSON in single-file and explicit-chain modes."""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import uuid
import zlib

sys.dont_write_bytecode = True
from generate_format_fixtures import event, fde
from generate_previous_gtids_fixtures import body, fixtures, SID_A
from generate_transaction_fixtures import stream

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / '_build/native/debug/build/cmd/moonbinlog/moonbinlog.exe'
FLAG = '--decode-previous-gtids'


def main(executable):
    cases = 0

    def run(args, code=0, error=None):
        nonlocal cases
        result = subprocess.run([str(executable), *map(str, args)], cwd=ROOT,
                                capture_output=True, text=True, encoding='utf-8', timeout=45)
        cases += 1
        assert result.returncode == code, (args, result.returncode, result.stdout[:1000], result.stderr)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        if code:
            assert result.stderr.startswith('moonbinlog:'), result.stderr
            assert all(record['kind'] == 'event' for record in records), records
            if code == 2:
                assert not records
            if error:
                assert error in result.stderr, result.stderr
        else:
            assert not result.stderr and records[-1]['kind'] in ('summary', 'chain_summary')
        return records

    paths = sorted(ROOT.glob('fixtures/mysql-*/*.binlog'))
    digests = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
    for path in paths:
        baseline = run(['--json', path])
        for options in [[], ['--json', '--decode-rotate'], ['--summary'], ['--summary', '--decode-rotate']]:
            records = run([FLAG, *options, path])
            assert records[-1] == baseline[-1]
            if '--summary' in options:
                assert len(records) == 1
                continue
            assert len(records) == len(baseline)
            for record, original in zip(records[:-1], baseline[:-1]):
                if record['type'] == 35:
                    assert record.pop('previous_gtids') == {'sids': []}
                else:
                    assert 'previous_gtids' not in record
                record.pop('rotate', None)
                assert record == original

    valid, invalid = fixtures()
    with tempfile.TemporaryDirectory(prefix='previous-gtids-cli-', dir=ROOT / '_build') as directory:
        source = Path(directory) / '历史日志.binlog'
        following = Path(directory) / 'next.binlog'

        def write(packets, checksum=True, format_data=None):
            source.write_bytes(b'\xfebin' + stream([format_data or fde(algorithm=int(checksum)), *packets], checksum=checksum))

        for name, entries in valid.items():
            expected = {'sids': [
                {'sid': str(uuid.UUID(bytes=sid)), 'intervals': [
                    {'start': str(start), 'end_exclusive': str(end)} for start, end in intervals]}
                for sid, intervals in entries]}
            for checksum in [True, False]:
                packet = event(35, body(entries), checksum=checksum)
                write([packet], checksum)
                baseline = run(['--json', source])
                for options in [[], ['--decode-rotate'], ['--summary']]:
                    records = run([FLAG, *options, '--', source])
                    assert records[-1] == baseline[-1]
                    if '--summary' in options:
                        assert len(records) == 1
                    else:
                        assert records[1].pop('previous_gtids') == expected
                        assert records[1] == baseline[1]
        for payload in invalid.values():
            write([event(35, payload)])
            assert run(['--json', source])[1]['type'] == 35
            for summary in [False, True]:
                records = run([FLAG, *(['--summary'] if summary else []), source], 1)
                assert len(records) == (0 if summary else 1)
        for count, post in [(41, 1), (34, None)]:
            format_data = bytearray(fde(count=count))
            if post is not None:
                format_data[76 + 34] = post
                format_data[-4:] = struct.pack('<I', zlib.crc32(format_data[:-4]))
            write([event(35, body([]))], format_data=bytes(format_data))
            run([FLAG, source], 1, 'InvalidPreviousGtidsEvent')
            run([FLAG, '--summary', source], 1, 'InvalidPreviousGtidsEvent')
        write([event(35, body(valid['single'])), event(199, b'unknown'), event(35, body([]))])
        records = run([FLAG, source])
        assert [r['type'] for r in records[:-1]] == [15, 35, 199, 35]
        assert 'previous_gtids' not in records[2]
        source.write_bytes(b'\xfebin' + fde() + event(35, body(valid['single'])) +
                           fde(algorithm=0) + event(35, body([]), checksum=False))
        records = run([FLAG, source])
        assert records[1]['checksum'] == 'CRC32' and records[3]['checksum'] == 'OFF'
        assert records[3]['previous_gtids'] == {'sids': []}
        packet = event(35, body(valid['single']))
        for length in range(1, len(packet)):
            source.write_bytes(b'\xfebin' + fde() + packet[:length])
            assert not run([FLAG, '--summary', source], 1)
        damaged = bytearray(packet)
        damaged[-1] ^= 1
        source.write_bytes(b'\xfebin' + fde() + damaged)
        run([FLAG, source], 1, 'ChecksumMismatch')
        # Quotas are cumulative and not relaxed by --summary.
        for entries in [[(SID_A, [])] * 1025,
                        [(SID_A, [(2 * i + 1, 2 * i + 2) for i in range(65537)])],
                        [(SID_A, [(2 * i + 1, 2 * i + 2) for i in range(32769)])] * 2]:
            write([event(35, body(entries))])
            for summary in [False, True]:
                run([FLAG, *(['--summary'] if summary else []), source], 1, 'GtidSetLimitExceeded')
        # Exact supported budgets succeed at their boundaries.
        write([event(35, body([(SID_A, [])] * 1024))])
        assert len(run([FLAG, source])[1]['previous_gtids']['sids']) == 1024
        write([event(35, body([(SID_A, [(2 * i + 1, 2 * i + 2) for i in range(65536)])]))])
        assert len(run([FLAG, source])[1]['previous_gtids']['sids'][0]['intervals']) == 65536
        for options in [[FLAG], ['--rows', '--schema', 'x'], ['--transactions', '--schema', 'x'],
                        ['--schema-template'], ['--use-table-metadata'], ['--include-rows'],
                        ['--schema', 'x'], ['--database', 'db'], ['--table', 't']]:
            run([FLAG, *options, source], 2)
        run([FLAG], 2)
        write([packet])
        for options in [['--max-event-bytes', '19'], ['--max-file-bytes', '4']]:
            run([FLAG, *options, source], 1)
        # Raising the event budget must reach the semantic parser too.
        large = event(35, body([]) + bytes(16_777_216))
        write([large])
        run([FLAG, '--summary', source], 1, 'EventTooLarge')
        run([FLAG, '--summary', '--max-event-bytes', len(large), source], 1, 'InvalidPreviousGtidsEvent')
        # A chain may show independent histories; this does not prove continuity.
        write([packet, event(4, struct.pack('<Q', 4) + following.name.encode())])
        following.write_bytes(b'\xfebin' + stream([fde(algorithm=0), event(35, body(valid['boundary']), checksum=False)], checksum=False))
        baseline = run(['--chain', source, following])
        for options in [[], ['--decode-rotate'], ['--summary'], ['--summary', '--decode-rotate']]:
            records = run(['--chain', FLAG, *options, source, following])
            assert records[-1] == baseline[-1]
            if '--summary' in options:
                assert len(records) == 1
            else:
                histories = [r for r in records if 'previous_gtids' in r]
                assert [r['source']['index'] for r in histories] == [0, 1]
                assert histories[1]['previous_gtids']['sids'][0]['intervals'][0]['end_exclusive'] == str(2**63 - 1)
        following.write_bytes(b'\xfebin' + stream([fde(), event(35, b'bad')]))
        for options in [[], ['--summary']]:
            records = run(['--chain', FLAG, *options, source, following], 1, 'InvalidPreviousGtidsEvent')
            assert not any(r.get('source', {}).get('index') == 1 and r.get('type') == 35 for r in records)
        run(['--chain', source, following])  # Default event inspection keeps opaque bodies.
    assert all(hashlib.sha256(path.read_bytes()).hexdigest() == digest for path, digest in digests.items())
    print(f'Passed {cases} previous-GTID CLI scenarios; original six captures unchanged')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=EXE)
    main(parser.parse_args().exe.resolve())
