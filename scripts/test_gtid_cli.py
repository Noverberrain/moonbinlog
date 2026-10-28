# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Verify assigned/anonymous GTID JSON, precision and opt-in validation."""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True
from generate_format_fixtures import event
from generate_gtid_fixtures import fixtures, gtid_fde
from generate_transaction_fixtures import stream

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / '_build/native/debug/build/cmd/moonbinlog/moonbinlog.exe'
FLAG = '--decode-gtid'


def details(expected):
    sid = str(uuid.UUID(bytes=bytes.fromhex(expected['sid'])))
    pair = lambda values, convert: None if values is None else dict(zip(['immediate', 'original'], map(convert, values)))
    decimal = lambda value: None if value is None else str(value)
    return dict(anonymous=expected['kind'] == 34,
                identity=None if expected['kind'] == 34 else f'{sid}:{expected["gno"]}',
                sid=sid, gno=str(expected['gno']), flags=expected['flags'],
                may_have_sbr_statements=bool(expected['flags'] & 1),
                last_committed=str(expected['last']), sequence_number=str(expected['sequence']),
                commit_timestamps=pair(expected['times'], str),
                transaction_length=decimal(expected['length']),
                server_versions=pair(expected['versions'], int),
                commit_group_ticket=decimal(expected['ticket']))


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
            if '--chain' in args:
                assert 'ChainFileFailure' in result.stderr and 'file_index=1' in result.stderr and 'path=' in result.stderr
        else:
            assert not result.stderr and records[-1]['kind'] in ('summary', 'chain_summary')
        return records

    originals = sorted(ROOT.glob('fixtures/mysql-*/*.binlog'))
    hashes = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in originals}
    oracles = json.loads((ROOT / 'fixtures/gtid/manifest.json').read_text(encoding='utf-8'))['real_anonymous_oracles']
    for oracle in oracles:
        source = ROOT / 'fixtures' / (oracle['capture'] + '.binlog')
        baseline = run(['--json', source])
        for options in [[], ['--json', '--decode-rotate', '--decode-previous-gtids'],
                        ['--summary'], ['--summary', '--decode-rotate', '--decode-previous-gtids']]:
            records = run([FLAG, *options, source])
            assert records[-1] == baseline[-1]
            if '--summary' in options:
                assert len(records) == 1
                continue
            assert len(records) == len(baseline)
            found = 0
            for record, original in zip(records[:-1], baseline[:-1]):
                if record['type'] == 34:
                    assert record.pop('gtid') == details(oracle['expected'])
                    assert record['offset'] == str(oracle['offset'])
                    found += 1
                else:
                    assert 'gtid' not in record
                record.pop('rotate', None)
                record.pop('previous_gtids', None)
                assert record == original
            assert found == 1

    valid, invalid = fixtures()
    with tempfile.TemporaryDirectory(prefix='gtid-cli-', dir=ROOT / '_build') as directory:
        source = Path(directory) / '事务标识.binlog'
        following = Path(directory) / '下一份.binlog'

        def write(packets, checksum=True, format_data=None):
            source.write_bytes(b'\xfebin' + stream([format_data or gtid_fde(int(checksum)), *packets], checksum=checksum))

        for kind, payload, expected in valid.values():
            for checksum in [True, False]:
                write([event(kind, payload, checksum=checksum)], checksum)
                baseline = run(['--json', source])
                for options in [[], ['--decode-rotate', '--decode-previous-gtids'], ['--summary']]:
                    records = run([FLAG, *options, '--', source])
                    assert records[-1] == baseline[-1]
                    if '--summary' in options:
                        assert len(records) == 1
                    else:
                        assert records[1].pop('gtid') == details(expected)
                        assert records[1] == baseline[1]
        for kind, payload in invalid.values():
            write([event(kind, payload)])
            assert run(['--json', source])[1]['type'] == kind
            for summary in [False, True]:
                records = run([FLAG, *(['--summary'] if summary else []), source], 1, 'InvalidGtidEvent')
                assert len(records) == (0 if summary else 1)
        full_kind, full_body, _ = valid['full']
        full = event(full_kind, full_body)
        for format_data in [gtid_fde(count=32), gtid_fde(width=25), gtid_fde(width=43)]:
            write([full], format_data=format_data)
            for options in [[], ['--summary']]:
                run([FLAG, *options, source], 1, 'InvalidGtidEvent')
        for size in range(1, len(full)):
            source.write_bytes(b'\xfebin' + gtid_fde() + full[:size])
            assert not run([FLAG, '--summary', source], 1)
        damaged = bytearray(full)
        damaged[-1] ^= 1
        source.write_bytes(b'\xfebin' + gtid_fde() + damaged)
        run([FLAG, source], 1, 'ChecksumMismatch')
        # Detail flags interpret only their own event kinds.
        write([event(33, b'bad')])
        run(['--decode-previous-gtids', source])
        write([event(35, b'bad'), full])
        run([FLAG, source])
        run([FLAG, '--decode-previous-gtids', source], 1, 'InvalidPreviousGtidsEvent')
        write([full, event(199, b'unknown'), full])
        records = run([FLAG, source])
        assert [r['type'] for r in records[:-1]] == [15, 33, 199, 33]
        assert 'gtid' not in records[2]
        source.write_bytes(b'\xfebin' + gtid_fde() + full + gtid_fde(0) + event(34, valid['anonymous'][1], checksum=False))
        records = run([FLAG, source])
        assert records[1]['checksum'] == 'CRC32' and records[3]['checksum'] == 'OFF'
        assert records[3]['gtid']['anonymous'] is True
        for options in [[FLAG], ['--rows', '--schema', 'x'], ['--transactions', '--schema', 'x'],
                        ['--schema-template'], ['--use-table-metadata'], ['--include-rows'],
                        ['--schema', 'x'], ['--database', 'db'], ['--table', 't']]:
            run([FLAG, *options, source], 2)
        run([FLAG], 2)
        write([full])
        for options in [['--max-event-bytes', '19'], ['--max-file-bytes', '4']]:
            run([FLAG, *options, source], 1)
        large = event(33, full_body + bytes(16_777_216))
        write([large])
        run([FLAG, '--summary', source], 1, 'EventTooLarge')
        run([FLAG, '--summary', '--max-event-bytes', len(large), source], 1, 'InvalidGtidEvent')
        # Assigned and anonymous records stay separate, even in a connected chain.
        write([event(35, bytes(8)), full, event(4, struct.pack('<Q', 4) + following.name.encode())])
        following.write_bytes(b'\xfebin' + stream([gtid_fde(0), event(34, valid['anonymous'][1], checksum=False)], checksum=False))
        baseline = run(['--chain', source, following])
        for options in [[], ['--decode-rotate', '--decode-previous-gtids'], ['--summary'],
                        ['--summary', '--decode-rotate', '--decode-previous-gtids']]:
            records = run(['--chain', FLAG, *options, source, following])
            assert records[-1] == baseline[-1]
            if '--summary' in options:
                assert len(records) == 1
            else:
                identities = [r for r in records if 'gtid' in r]
                assert sum('rotate' in r for r in records) == int('--decode-rotate' in options)
                assert sum('previous_gtids' in r for r in records) == int('--decode-previous-gtids' in options)
                assert [r['source']['index'] for r in identities] == [0, 1]
                assert identities[0]['gtid'] == details(valid['full'][2])
                assert identities[1]['gtid'] == details(valid['anonymous'][2])
        following.write_bytes(b'\xfebin' + stream([gtid_fde(), event(34, b'bad')]))
        for options in [[], ['--summary']]:
            records = run(['--chain', FLAG, *options, source, following], 1, 'InvalidGtidEvent')
            assert not any(r.get('source', {}).get('index') == 1 and r.get('type') == 34 for r in records)
        run(['--chain', source, following])
    assert all(hashlib.sha256(p.read_bytes()).hexdigest() == digest for p, digest in hashes.items())
    print(f'Passed {cases} GTID detail CLI scenarios; six real captures unchanged')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=EXE)
    main(parser.parse_args().exe.resolve())
