# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Verify fixed GTID=ON captures against server snapshots and official text."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
import uuid

sys.dont_write_bytecode = True
from generate_gtid_fixtures import expectation
from verify_json_fixtures import oracle_images
from verify_mysql_fixtures import event_offsets

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'fixtures/gtid-real'
PROFILES = ('crc32-full', 'crc32-minimal', 'off-full')


def profiles():
    manifest = json.loads((FIXTURES / 'manifest.json').read_text(encoding='utf-8'))
    assert manifest['gtid_mode'] == manifest['enforce_gtid_consistency'] == 'ON'
    for name in ('schema', 'workload', 'seed'):
        text = (FIXTURES / f'{name}.sql').read_text(encoding='utf-8')
        assert hashlib.sha256(text.encode()).hexdigest() == manifest[f'{name}_sha256']
    result = []
    for index, profile in enumerate(PROFILES):
        path = FIXTURES / f'{profile}.binlog'
        raw = path.read_bytes()
        dump = path.with_suffix('.mysqlbinlog.txt').read_bytes()
        entry = manifest['profiles'][profile]
        assert len(raw) == entry['bytes'] and hashlib.sha256(raw).hexdigest() == entry['sha256']
        assert hashlib.sha256(dump).hexdigest() == entry['oracle_sha256']
        offsets = event_offsets(raw)
        assert offsets == [int(x) for x in re.findall(rb'^# at (\d+)\r?$', dump, re.M)]
        kinds = [raw[offset + 4] for offset in offsets]
        assert kinds.count(33) == kinds.count(16) == 3 and 34 not in kinds
        assert kinds[:2] == [15, 35] and kinds[-1] == 4
        assert len(offsets) == 18
        algorithm = raw[4 + struct.unpack_from('<I', raw, 13)[0] - 5]
        assert algorithm == (0 if profile == 'off-full' else 1)
        prior = re.findall(rb'Previous-GTIDs\r?\n# ([^\r\n]+)', dump)[0].decode()
        assert prior == entry['gtid_executed_before']
        sid = manifest['server_uuid']
        history_end = 2 + 3 * index
        before = f'{sid}:1' if index == 0 else f'{sid}:1-{history_end - 1}'
        assert prior == before
        assert entry['gtid_executed_after'] == f'{sid}:1-{history_end + 2}'
        assert entry['final_rows'] == '2\t1'
        # Independently check the nonempty binary SID/interval representation.
        start = offsets[1]
        size = struct.unpack_from('<I', raw, start + 9)[0]
        payload = raw[start + 19:start + size - (4 if algorithm else 0)]
        assert len(payload) == 48 and struct.unpack_from('<Q', payload)[0] == 1
        assert str(uuid.UUID(bytes=payload[8:24])) == sid
        assert struct.unpack_from('<QQQ', payload, 24) == (1, 1, history_end)
        gtids = []
        for order, position in enumerate(i for i, kind in enumerate(kinds) if kind == 33):
            offset = offsets[position]
            terminal = position + 4  # GTID, BEGIN, TABLE_MAP, ROWS, XID.
            assert kinds[position:terminal + 1] == [33, 2, 19, 30 if order == 0 else 31 if order == 1 else 32, 16]
            end = offsets[terminal] + struct.unpack_from('<I', raw, offsets[terminal] + 9)[0]
            section = dump.split(f'# at {offset}\n'.encode()) if b'\r\n' not in dump else dump.split(f'# at {offset}\r\n'.encode())
            assert len(section) == 2
            # End at the next GTID/rotation, retaining all text for this transaction.
            next_offset = offsets[terminal + 1]
            block = section[1].split(f'# at {next_offset}'.encode())[0]
            clock = re.search(rb'\tGTID\s+last_committed=(\d+)\s+sequence_number=(\d+)\s+rbr_only=(yes|no)\s+original_committed_timestamp=(\d+)\s+immediate_commit_timestamp=(\d+)\s+transaction_length=(\d+)', block)
            assert clock
            last, sequence, rbr, original, immediate, length = clock.groups()
            identity = re.findall(rb"SET @@SESSION.GTID_NEXT= '([^']+)'", block)
            assert identity == [f'{sid}:{history_end + order}'.encode()]
            versions = re.findall(rb'SET @@session\.(?:original|immediate)_server_version=(\d+)', block)
            assert len(versions) == 2
            xid = re.findall(rb'Xid = (\d+)', block)
            assert len(xid) == 1 and b'\nBEGIN' in block and b'COMMIT' in block
            assert int(length) == end - offset
            expected = dict(kind=33, sid=uuid.UUID(sid).hex, flags=0 if rbr == b'yes' else 1,
                            gno=history_end + order, last=int(last), sequence=int(sequence),
                            times=(int(immediate), int(original)), length=int(length),
                            versions=(int(versions[1]), int(versions[0])), ticket=None)
            gtids.append(dict(offset=offset, begin=offsets[position + 1], end=end, xid=int(xid[0]),
                              events=5, row_events=1, changes=[3, 1, 2][order], expected=expected))
        images = oracle_images(dump)
        result.append(dict(profile=profile, path=path, raw=raw, history_end=history_end,
                           transactions=gtids, images=images, offsets=offsets))
    return result


def generated():
    lines = ['// Copyright 2026 Noverberrain.', '// SPDX-License-Identifier: Apache-2.0', '',
             '// Real GTID=ON MySQL captures and official oracle; generated by verify_assigned_gtid_fixtures.py.']
    entries = profiles()
    for profile in entries:
        key = 'mysql_gtid_' + profile['profile'].replace('-', '_')
        lines += ['', '///|', f'let {key} : Bytes = [']
        for start in range(0, len(profile['raw']), 12):
            lines.append('  ' + ', '.join(f'0x{x:02x}' for x in profile['raw'][start:start + 12]) + ',')
        lines.append(']')
    lines += ['', '///|', 'fn assigned_gtid_profiles() -> Array[(Bytes, UInt64, Array[AssignedGtidOracle], Array[Array[String]])] {', '  [']
    for profile in entries:
        key = 'mysql_gtid_' + profile['profile'].replace('-', '_')
        lines.append(f'    ({key}, {profile["history_end"]}UL, [')
        for tx in profile['transactions']:
            lines.append('      { ' + f'offset: {tx["offset"]}UL, begin_offset: {tx["begin"]}UL, end_offset: {tx["end"]}UL, '
                         + f'xid: {tx["xid"]}UL, events: {tx["events"]}, changes: {tx["changes"]}, gtid: {expectation(tx["expected"])}' + ' },')
        lines.append('    ], [')
        for row in profile['images']:
            lines.append('      [' + ', '.join(json.dumps(value, ensure_ascii=False) for value in row) + '],')
        lines += ['    ]),']
    lines += ['  ]', '}']
    return '\n'.join(lines) + '\n'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--write', action='store_true')
    mode.add_argument('--check', action='store_true')
    args = parser.parse_args()
    expected = generated()
    path = ROOT / 'mysql_gtid_fixture_test.mbt'
    if args.write:
        path.write_text(expected, encoding='utf-8', newline='\n')
    else:
        normalize = lambda text: re.sub(r',([\)\]}])', r'\1', re.sub(r'\s+', '', text))
        assert normalize(path.read_text(encoding='utf-8')) == normalize(expected), path
    print('Verified 3 GTID=ON captures, 9 assigned transactions, nonempty history and 42 official column positions')
