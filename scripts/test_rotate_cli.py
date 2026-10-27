# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Verify opt-in rotation JSON, official targets and summary-mode validation."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from generate_format_fixtures import event, fde
from generate_rotate_fixtures import fixtures
from generate_transaction_fixtures import stream

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / '_build/native/debug/build/cmd/moonbinlog/moonbinlog.exe'


def main(executable):
    cases = 0

    def run(args, code=0, error=None):
        nonlocal cases
        result = subprocess.run([str(executable), *map(str, args)], cwd=ROOT,
                                capture_output=True, text=True, encoding='utf-8', timeout=45)
        cases += 1
        assert result.returncode == code, (args, result.returncode, result.stdout[:2000], result.stderr)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        if code:
            assert result.stderr.startswith('moonbinlog:'), result.stderr
            assert all(record['kind'] == 'event' for record in records), records
            if code == 2:
                assert not records
            if error:
                assert error in result.stderr, result.stderr
        else:
            assert not result.stderr and records[-1]['kind'] == 'summary'
        return records

    paths = sorted(ROOT.glob('fixtures/mysql-*/*.binlog'))
    digests = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
    for path in paths:
        baseline = run(['--json', path])
        dump = path.with_suffix('.mysqlbinlog.txt').read_bytes()
        target, position = re.findall(rb'Rotate to ([^\r\n]+?)  pos: (\d+)\r?$', dump, re.M)[0]
        for options in [[], ['--json'], ['--summary'], ['--json', '--summary']]:
            records = run(['--decode-rotate', *options, path])
            assert records[-1] == baseline[-1]
            if '--summary' in options:
                assert len(records) == 1
                continue
            assert len(records) == len(baseline)
            for record, original in zip(records[:-1], baseline[:-1]):
                if record['type'] == 4:
                    payload = record.pop('rotate')
                    assert payload == {'position': position.decode(), 'next_binlog_hex': target.hex(),
                                       'next_binlog_utf8': target.decode('utf-8')}
                assert record == original

    with tempfile.TemporaryDirectory(prefix='rotate-cli-', dir=ROOT / '_build') as directory:
        source = Path(directory) / '轮转日志.binlog'
        samples = fixtures()

        def scan(packets, summary=False, code=0, error=None, legacy=False, format_bytes=None):
            source.write_bytes(b'\xfebin' + stream([format_bytes or fde(), *packets]))
            return run([*(['--json'] if legacy else ['--decode-rotate']),
                        *(['--summary'] if summary else []), '--', source], code, error)

        for name, position in [('zero', 0), ('start', 4), ('wide', 2**32 + 4), ('max', 2**64 - 1)]:
            records = scan([samples[f'rotate_{name}']])
            assert records[1]['rotate']['position'] == str(position)
            assert type(records[1]['rotate']['position']) is str
            assert records[1]['rotate']['next_binlog_utf8'] == 'mysql-bin.000002'
            assert records[-1]['events'] == 2
            assert len(scan([samples[f'rotate_{name}']], summary=True)) == 1
        for name in [b'\0', b'../\xff\0\xef\xbb\xbf\\name',
                     '日志.000002'.encode(), b'\xef\xbb\xbfBOM', b'line\n"\\\t', b'no-such-file.000009']:
            records = scan([event(4, struct.pack('<Q', 4) + name)])
            payload = records[1]['rotate']
            try:
                text = name.decode('utf-8')
            except UnicodeDecodeError:
                text = None
            assert payload == {'position': '4', 'next_binlog_hex': name.hex(), 'next_binlog_utf8': text}
            assert len(records) == 3  # Embedded newlines/NUL stay inside one JSON record.
        for size in range(9):
            for summary in [False, True]:
                records = scan([samples[f'rotate_short_{size}']], summary=summary, code=1, error='InvalidRotateEvent')
                assert len(records) == (0 if summary else 1)
            assert scan([samples[f'rotate_short_{size}']], legacy=True)[1]['type'] == 4
        for width in [0, 7, 9]:
            for summary in [False, True]:
                scan([samples['rotate_start']], summary=summary, code=1, error='InvalidRotateEvent',
                     format_bytes=samples[f'fde_rotate_{width}'])
            assert scan([samples['rotate_start']], legacy=True, format_bytes=samples[f'fde_rotate_{width}'])[1]['type'] == 4
        # A normal rotation list describes one input only; no target is opened.
        records = scan([samples['rotate_start'], event(199, b'unknown'), samples['rotate_max']])
        assert [record['type'] for record in records[:-1]] == [15, 4, 199, 4]
        assert records[-1]['events'] == 4
        assert 'rotate' not in records[2]
        # Context changes from CRC32 to OFF in the same input.
        source.write_bytes(b'\xfebin' + fde() + samples['rotate_start'] + fde(algorithm=0) + samples['rotate_off'])
        records = run(['--decode-rotate', source])
        assert records[1]['checksum'] == 'CRC32' and records[3]['checksum'] == 'OFF'
        assert records[3]['rotate']['position'] == str(0xfedcba9876543210)
        for summary in [False, True]:
            valid = b'\xfebin' + stream([fde(), samples['rotate_start']])
            broken = bytearray(valid)
            broken[-1] ^= 1
            for raw in [bytes(broken), valid[:-1], valid + b'\0']:
                source.write_bytes(raw)
                # A valid earlier rotation may precede a later truncated header.
                records = run(['--decode-rotate', *(['--summary'] if summary else []), source], 1)
                rotations = [record for record in records if record['type'] == 4]
                assert len(rotations) == (1 if raw == valid + b'\0' and not summary else 0)
        for length in range(1, len(samples['rotate_start'])):
            source.write_bytes(b'\xfebin' + fde() + samples['rotate_start'][:length])
            assert not run(['--decode-rotate', '--summary', source], 1)
        for options in [['--decode-rotate'], ['--rows', '--schema', 'x'],
                        ['--transactions', '--schema', 'x'], ['--schema-template'],
                        ['--use-table-metadata'], ['--include-rows'], ['--table', 'sample'],
                        ['--database', 'shop'], ['--schema', 'x']]:
            run(['--decode-rotate', *options, source], 2)
        run(['--decode-rotate'], 2)
        source.write_bytes(b'\xfebin' + stream([fde(), samples['rotate_start']]))
        for options in [['--max-event-bytes', '19'], ['--max-file-bytes', '4']]:
            run(['--decode-rotate', *options, source], 1)
        # A custom event budget must reach the rotation parser in --summary too.
        large = event(4, struct.pack('<Q', 4) + b'a' * 16_777_216)
        source.write_bytes(b'\xfebin' + stream([fde(), large]))
        run(['--decode-rotate', '--summary', source], 1, 'EventTooLarge')
        assert len(run(['--decode-rotate', '--summary', '--max-event-bytes', str(len(large)), source])) == 1
    assert all(hashlib.sha256(path.read_bytes()).hexdigest() == digest for path, digest in digests.items())
    print(f'Passed {cases} decoded-rotation CLI scenarios; six official rotation targets verified')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=EXE)
    main(parser.parse_args().exe.resolve())
