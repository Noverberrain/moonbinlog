# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Exercise explicit ordered file chains, provenance, limits and failed links."""

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
from generate_transaction_fixtures import stream

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / '_build/native/debug/build/cmd/moonbinlog/moonbinlog.exe'


def rotation(name, position=4):
    return event(4, struct.pack('<Q', position) + name.encode('utf-8'))


def log(parts):
    return b'\xfebin' + stream([fde(), *parts])


def main(executable):
    cases = 0

    def run(args, code=0, error=None):
        nonlocal cases
        result = subprocess.run([str(executable), *map(str, args)], cwd=ROOT,
                                capture_output=True, text=True, encoding='utf-8', timeout=30)
        cases += 1
        assert result.returncode == code, (args, result.returncode, result.stdout[:1200], result.stderr)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        if code:
            assert result.stderr.startswith('moonbinlog:'), result.stderr
            assert all(record['kind'] == 'event' for record in records), records
            if code == 2:
                assert not records
            else:
                assert 'ChainFileFailure' in result.stderr and 'file_index=' in result.stderr and 'path=' in result.stderr, result.stderr
            if error:
                assert error in result.stderr, result.stderr
        else:
            assert not result.stderr, result.stderr
        return records

    originals = sorted(ROOT.glob('fixtures/mysql-*/*.binlog'))
    digests = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in originals}
    with tempfile.TemporaryDirectory(prefix='chain-cli-', dir=ROOT / '_build') as directory:
        work = Path(directory)
        for family in ['mysql-8.0', 'mysql-json']:
            dest = work / family
            dest.mkdir()
            fixture_paths = [ROOT / 'fixtures' / family / f'{name}.binlog'
                             for name in ['crc32-full', 'crc32-minimal', 'off-full']]
            targets = [re.findall(rb'Rotate to ([^\r\n]+?)  pos: (\d+)\r?$',
                                  path.with_suffix('.mysqlbinlog.txt').read_bytes(), re.M)[0][0].decode()
                       for path in fixture_paths]
            paths = [dest / '头文件.binlog', dest / targets[0], dest / targets[1]]
            for source, path in zip(fixture_paths, paths):
                path.write_bytes(source.read_bytes())
            baseline = [run(['--json', path]) for path in paths]
            total_bytes = sum(path.stat().st_size for path in paths)
            for options in [[], ['--json', '--decode-rotate'], ['--summary'], ['--summary', '--decode-rotate']]:
                records = run(['--chain', *options, '--', *paths])
                summary = records[-1]
                assert summary['kind'] == 'chain_summary' and summary['file_count'] == 3
                assert summary['file_bytes'] == total_bytes
                assert int(summary['event_bytes']) == total_bytes - 12
                assert summary['events'] == sum(items[-1]['events'] for items in baseline)
                assert len(summary['files']) == 3
                for index, file_summary in enumerate(summary['files']):
                    assert file_summary['source'] == {'index': index, 'path': str(paths[index])}
                    assert file_summary['kind'] == 'file_summary'
                    assert {key: file_summary[key] for key in ['events', 'event_bytes', 'file_bytes', 'types']} == {
                        key: baseline[index][-1][key] for key in ['events', 'event_bytes', 'file_bytes', 'types']}
                if '--summary' in options:
                    assert len(records) == 1
                    continue
                cursor = 0
                for index, items in enumerate(baseline):
                    for expected in items[:-1]:
                        actual = records[cursor].copy()
                        cursor += 1
                        assert actual.pop('source') == {'index': index, 'path': str(paths[index])}
                        if '--decode-rotate' in options and actual['type'] == 4:
                            assert actual.pop('rotate')['next_binlog_utf8'] == targets[index]
                        assert actual == expected
                assert cursor == len(records) - 1
            run(['--chain', '--summary', '--max-total-bytes', total_bytes,
                 '--max-file-bytes', max(path.stat().st_size for path in paths), *paths])
            assert not run(['--chain', '--summary', '--max-total-bytes', total_bytes - 1, *paths], 1)
            run(['--chain', '--summary', '--max-file-bytes', 4, *paths], 1)
            run(['--chain', '--summary', '--max-event-bytes', 19, *paths], 1)
            run(['--chain', '--summary', paths[1], paths[0]], 1, 'InvalidChainLink')

        first, second = work / '--首份.binlog', work / 'next.binlog'
        second.write_bytes(log([event(199, b'opaque body'), event(3, b'')]))
        normal = log([rotation(second.name)])
        first.write_bytes(normal)
        assert run(['--chain', '--summary', '--', first, second])[-1]['file_count'] == 2
        # The supplied next path can be elsewhere; the tool compares only its basename.
        archive = work / '归档'
        archive.mkdir()
        elsewhere = archive / second.name
        elsewhere.write_bytes(second.read_bytes())
        run(['--chain', '--summary', first, elsewhere])
        run(['--chain', first, work / 'does-not-exist'], 1, 'InvalidChainLink')
        first.write_bytes(log([rotation('missing.binlog')]))
        run(['--chain', '--summary', first, work / 'missing.binlog'], 1)
        for position in [0, 1, 5, 2**64 - 1]:
            first.write_bytes(log([rotation(second.name, position)]))
            for summary in [False, True]:
                run(['--chain', *(['--summary'] if summary else []), first, second], 1, 'InvalidChainLink')
        for parts in [[], [event(3, b'')], [rotation(second.name), event(199, b'after-rotate')],
                      [rotation(second.name), rotation(second.name)]]:
            first.write_bytes(log(parts))
            for summary in [False, True]:
                run(['--chain', *(['--summary'] if summary else []), first, second], 1, 'InvalidChainLink')
        first.write_bytes(normal)
        valid_second = second.read_bytes()
        # A final valid ROTATE does not request opening an unprovided successor.
        second.write_bytes(log([rotation('unprovided.binlog', 2**64 - 1)]))
        run(['--chain', '--summary', first, second])
        second.write_bytes(log([event(4, bytes(8))]))
        run(['--chain', '--summary', first, second], 1, 'InvalidRotateEvent')
        for bad in [b'bad!', b'\xfebin', valid_second[:-1], bytes([valid_second[0] ^ 1]) + valid_second[1:]]:
            second.write_bytes(bad)
            for summary in [False, True]:
                records = run(['--chain', *(['--summary'] if summary else []), first, second], 1)
                if summary:
                    assert not records
                else:
                    assert records[0]['source']['index'] == 0
        broken = bytearray(normal)
        broken[-1] ^= 1
        first.write_bytes(broken)
        second.write_bytes(valid_second)
        assert not run(['--chain', '--summary', first, second], 1, 'ChecksumMismatch')
        first.write_bytes(normal)
        for options in [['--chain'], ['--rows', '--schema', 's'], ['--transactions', '--schema', 's'],
                        ['--schema-template'], ['--use-table-metadata'], ['--include-rows'],
                        ['--database', 'shop'], ['--table', 'sample'], ['--max-total-bytes', '0'],
                        ['--max-total-bytes', '2147483648'], ['--max-total-bytes', 'a'],
                        ['--max-total-bytes', '1', '--max-total-bytes', '2']]:
            run(['--chain', *options, first, second], 2)
        for args in [['--chain'], ['--chain', first], [first, second],
                     ['--max-total-bytes', '100', first], ['--chain', '--max-total-bytes']]:
            run(args, 2)
        # Explicit filename bytes are matched exactly, including Unicode and quotes.
        special = archive / '日志.名\".binlog' if sys.platform != 'win32' else archive / '日志.名.binlog'
        special.write_bytes(log([]))
        first.write_bytes(log([rotation(special.name)]))
        run(['--chain', '--decode-rotate', '--', first, special])
        first.write_bytes(log([rotation('../next.binlog')]))
        run(['--chain', '--summary', first, second], 1, 'InvalidChainLink')
        first.write_bytes(log([rotation(first.name)]))
        run(['--chain', '--summary', first, first], 1, 'repeated basename')
        alias = archive / first.name
        alias.write_bytes(log([]))
        run(['--chain', '--summary', first, alias], 1, 'repeated basename')
        # The file-count limit is checked before I/O; the last file may end at FDE.
        many = [work / f'file{i:03}.binlog' for i in range(128)]
        for i, path in enumerate(many):
            path.write_bytes(log([rotation(many[i + 1].name)]) if i + 1 < len(many) else log([]))
        result = run(['--chain', '--summary', *many])
        assert result[0]['file_count'] == 128 and result[0]['events'] == 255
        run(['--chain', *many, work / 'file129.binlog'], 2)
    assert all(hashlib.sha256(path.read_bytes()).hexdigest() == digest for path, digest in digests.items())
    print(f'Passed {cases} explicit-chain CLI scenarios; six real captures unchanged')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=EXE)
    main(parser.parse_args().exe.resolve())
