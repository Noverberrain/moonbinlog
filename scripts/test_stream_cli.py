# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Compare streamed event browsing with the in-memory CLI, including large files."""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from generate_format_fixtures import event, fde

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / '_build/native/debug/build/cmd/moonbinlog/moonbinlog.exe'


def main(executable):
    cases = 0

    def run(args, code=0, error=None):
        nonlocal cases
        result = subprocess.run([str(executable), *map(str, args)], cwd=ROOT,
                                capture_output=True, text=True, encoding='utf-8', timeout=90)
        cases += 1
        assert result.returncode == code, (args, result.returncode, result.stdout[:1000], result.stderr)
        if code:
            assert result.stderr.startswith('moonbinlog:'), result.stderr
            if error:
                assert error in result.stderr, result.stderr
        else:
            assert not result.stderr
        return result

    paths = sorted(p for folder in ['mysql-8.0', 'mysql-json', 'gtid-real']
                   for p in (ROOT / 'fixtures' / folder).glob('*.binlog'))
    hashes = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    for path in paths:
        for options in [[], ['--json'], ['--summary'], ['--json', '--summary'],
                        ['--decode-gtid', '--decode-previous-gtids', '--decode-rotate'],
                        ['--summary', '--decode-gtid', '--decode-previous-gtids', '--decode-rotate']]:
            baseline = run([*options, path])
            streamed = run(['--stream', *options, path])
            assert streamed.stdout == baseline.stdout
    with tempfile.TemporaryDirectory(prefix='event-stream-cli-', dir=ROOT / '_build') as directory:
        source = Path(directory) / '大日志.binlog'
        magic = b'\xfebin'
        valid = fde() + event(16, bytes(8))
        for size in range(len(magic + valid)):
            source.write_bytes((magic + valid)[:size])
            # Exactly magic + FDE is a valid clean EOF.
            code = 0 if size == 4 + len(fde()) else 1
            old = run(['--json', '--summary', source], code)
            new = run(['--stream', '--json', '--summary', source], code)
            assert old.stdout == new.stdout
        for data, error, options in [
            (b'bad!', 'InvalidMagic', []),
            (magic, 'MissingFormatDescription', []),
            (magic + event(16, bytes(8)), 'MissingFormatDescription', []),
            (magic + fde() + event(199, b'bad')[:-1], 'TruncatedEvent', []),
        ]:
            source.write_bytes(data)
            run(['--stream', '--json', '--summary', *options, source], 1, error)
        bad = bytearray(event(16, bytes(8)))
        bad[-1] ^= 1
        source.write_bytes(magic + fde() + bad)
        output = run(['--stream', '--json', source], 1, 'ChecksumMismatch').stdout
        assert [json.loads(line)['type'] for line in output.splitlines()] == [15]
        run(['--stream', '--json', '--summary', source], 1, 'ChecksumMismatch')
        # An oversized declaration is rejected before any large body allocation.
        huge_header = bytearray(event(199, b'', checksum=False))
        struct.pack_into('<I', huge_header, 9, 0xffffffff)
        source.write_bytes(magic + fde(algorithm=0) + huge_header)
        run(['--stream', '--summary', source], 1, 'EventTooLarge')
        run(['--stream', '--summary', '--max-event-bytes', '4294967295', source], 1, 'TruncatedEvent')
        # A new FDE switches CRC policy and an OFF event may have an empty body.
        source.write_bytes(magic + fde() + event(16, bytes(8)) + fde(algorithm=0) + event(3, b'', checksum=False))
        assert run(['--stream', '--json', source]).stdout == run(['--json', source]).stdout
        large_event = event(199, bytes(16_777_216), checksum=False)
        source.write_bytes(magic + fde(algorithm=0) + large_event)
        run(['--stream', '--json', '--summary', source], 1, 'EventTooLarge')
        options = ['--json', '--summary', '--max-event-bytes', str(len(large_event))]
        assert run(['--stream', *options, source]).stdout == run([*options, source]).stdout
        for options in [['--stream'], ['--chain', 'other'], ['--rows', '--schema', 's'],
                        ['--transactions', '--schema', 's'], ['--schema-template'],
                        ['--include-rows'], ['--with-gtid'], ['--database', 'd'], ['--table', 't']]:
            run(['--stream', *options, source], 2)
        run(['--stream'], 2)
        run(['--stream', '--max-file-bytes', '4', source], 1, 'InvalidFile')
        # An actual >64 MiB file built incrementally; one event is about 1 MiB.
        packet = event(199, bytes(1_048_576), checksum=False)
        with source.open('wb') as output:
            output.write(magic + fde(algorithm=0))
            for _ in range(65):
                output.write(packet)
        size = source.stat().st_size
        assert size > 67_108_864
        run(['--stream', '--json', '--summary', source], 1, 'InvalidFile')
        options = ['--json', '--summary', '--max-file-bytes', str(size)]
        streamed = run(['--stream', *options, source])
        assert streamed.stdout == run([*options, source]).stdout
        summary = json.loads(streamed.stdout)
        assert summary['events'] == 66 and summary['file_bytes'] == size
    assert all(hashlib.sha256(p.read_bytes()).hexdigest() == digest for p, digest in hashes.items())
    print(f'Passed {cases} streamed-event CLI scenarios, including a {size}-byte file; nine captures unchanged')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=EXE)
    main(parser.parse_args().exe.resolve())
