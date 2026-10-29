# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Compare real GTID=ON CLI output with fixed official identities and row images."""

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
from verify_assigned_gtid_fixtures import ROOT, profiles
from test_gtid_cli import details
from test_json_cli import canonical
from test_transactions_cli import packets
from generate_transaction_fixtures import stream

EXE = ROOT / '_build/native/debug/build/cmd/moonbinlog/moonbinlog.exe'
SCHEMA = ROOT / 'examples/mysql-8.0-json-schema.json'


def main(executable):
    cases = 0

    def run(args, code=0, error=None):
        nonlocal cases
        result = subprocess.run([str(executable), *map(str, args)], cwd=ROOT,
                                capture_output=True, text=True, encoding='utf-8', timeout=45)
        cases += 1
        assert result.returncode == code, (args, result.returncode, result.stdout[:1200], result.stderr)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        if code:
            assert result.stderr.startswith('moonbinlog:'), result.stderr
            assert not any(r['kind'].endswith('summary') for r in records)
            if '--summary' in args:
                assert not records
            if error:
                assert error in result.stderr, result.stderr
        else:
            assert not result.stderr and records
        return records

    def tx(path, options=(), bound=True, schema=SCHEMA, code=0, error=None):
        return run(['--transactions', '--schema', schema, *(['--with-gtid'] if bound else []),
                    *options, path], code, error)

    entries = profiles()
    hashes = {p: hashlib.sha256(p.read_bytes()).hexdigest()
              for folder in ['gtid-real', 'mysql-8.0', 'mysql-json']
              for p in (ROOT / 'fixtures' / folder).glob('*.binlog')}
    with tempfile.TemporaryDirectory(prefix='assigned-gtid-cli-', dir=ROOT / '_build') as directory:
        work = Path(directory)
        for entry in entries:
            path, expected = entry['path'], entry['transactions']
            baseline = run(['--json', path])
            records = run(['--decode-gtid', '--decode-previous-gtids', '--decode-rotate', path])
            assert records[-1] == baseline[-1]
            history = records[1]['previous_gtids']['sids']
            assert history == [{'sid': str(uuid.UUID(hex=expected[0]['expected']['sid'])),
                                'intervals': [{'start': '1', 'end_exclusive': str(entry['history_end'])}]}]
            assigned = [r for r in records if 'gtid' in r]
            assert len(assigned) == 3
            for event, oracle in zip(assigned, expected):
                assert event['gtid'] == details(oracle['expected'])
                assert event['offset'] == str(oracle['offset'])
            for options in [[], ['--include-rows'], ['--summary'], ['--summary', '--include-rows'],
                            ['--include-rows', '--database', 'moonbinlog_fixture', '--table', 'sample'],
                            ['--summary', '--table', 'absent']]:
                original, bound = tx(path, options, bound=False), tx(path, options)
                assert bound[-1] == original[-1]
                assert bound[-1]['committed_transactions'] == 3 and bound[-1]['committed_changes'] == 6
                assert bound[-1]['rolled_back_transactions'] == 0
                if '--summary' in options:
                    assert len(bound) == 1
                    continue
                assert len(bound) == 4
                images = []
                for record, old, oracle in zip(bound[:-1], original[:-1], expected):
                    record = dict(record)
                    assert record.pop('gtid') == details(oracle['expected'])
                    assert record.pop('gtid_span') == dict(start_offset=str(oracle['offset']),
                        end_offset=str(oracle['end']), events=5, event_bytes=str(oracle['end'] - oracle['offset']))
                    assert record['start_offset'] == str(oracle['begin']) and record['xid'] == str(oracle['xid'])
                    assert record['changes'] == oracle['changes'] and record == old
                    for change in record.get('row_changes', []):
                        assert change['transaction_status'] == 'committed'
                        for side in ['before', 'after']:
                            if change[side] is not None:
                                images.append([canonical(cell) for cell in change[side]])
                if '--include-rows' in options:
                    assert images == entry['images']
            # FULL metadata provides an immediately usable schema, not placeholders.
            template = run(['--schema-template', '--use-table-metadata', path])[0]
            assert template == json.loads(SCHEMA.read_text(encoding='utf-8'))
            draft = work / (entry['profile'] + '.json')
            draft.write_text(json.dumps(template), encoding='utf-8')
            assert tx(path, ['--include-rows'], schema=draft) == tx(path, ['--include-rows'])
            source = work / (entry['profile'] + '.binlog')
            # A valid pair of previous commits cannot hide a lone final GTID.
            raw = entry['raw']
            source.write_bytes(raw[:expected[2]['begin']])
            assert len(tx(source, code=1, error='IncompleteGtidTransaction')) == 2
            tx(source, ['--summary'], code=1, error='IncompleteGtidTransaction')
            source.write_bytes(raw[:expected[2]['end'] - 1])
            assert len(tx(source, code=1)) == 2
            # Well-framed assigned GNO=0 fails even when no table would match.
            parts = packets(raw)
            packet = bytearray(parts[2])
            packet[36:44] = bytes(8)
            checksum = entry['profile'] != 'off-full'
            if checksum:
                packet[-4:] = struct.pack('<I', zlib.crc32(packet[:-4]))
            source.write_bytes(b'\xfebin' + stream([*parts[:2], bytes(packet), *parts[3:]], checksum=checksum))
            tx(source, ['--summary', '--table', 'absent'], code=1, error='InvalidGtidEvent')
            tx(source, bound=False)
            tx(path, ['--max-file-bytes', str(len(raw))])
            tx(path, ['--max-file-bytes', str(len(raw) - 1)], code=1)
    assert all(hashlib.sha256(p.read_bytes()).hexdigest() == digest for p, digest in hashes.items())
    print(f'Passed {cases} real assigned-GTID CLI scenarios; nine captures unchanged')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=EXE)
    main(parser.parse_args().exe.resolve())
