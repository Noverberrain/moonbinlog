# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Encode MySQL 8.0 assigned/anonymous GTID events independently with struct/zlib."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import uuid
import zlib

sys.dont_write_bytecode = True
from generate_format_fixtures import event, fde

ROOT = Path(__file__).resolve().parents[1]
SID = bytes.fromhex('00112233445566778899aabbccddeeff')


def gtid_fde(algorithm=1, count=41, width=42):
    raw = bytearray(fde(algorithm=algorithm, count=count))
    for kind in [33, 34]:
        if kind <= count:
            raw[76 + kind - 1] = width
    raw[-4:] = struct.pack('<I', zlib.crc32(raw[:-4]))
    return bytes(raw)


def packed(value, width=None):
    if width is None:
        width = 1 if value <= 250 else 2 if value <= 65535 else 3 if value <= 16777215 else 8
    return bytes([value]) if width == 1 else bytes([{2: 252, 3: 253, 8: 254}[width]]) + value.to_bytes(width, 'little')


def fixtures():
    valid = {}

    def add(name, kind=33, sid=SID, flags=0, gno=1, last=0, sequence=1,
            times=None, length=None, versions=None, ticket=None, length_width=None):
        payload = bytes([flags]) + sid + struct.pack('<QBQQ', gno, 2, last, sequence)
        if times is not None:
            immediate, original = times
            payload += (immediate | ((1 << 55) if immediate != original else 0)).to_bytes(7, 'little')
            if immediate != original:
                payload += original.to_bytes(7, 'little')
        if length is not None:
            payload += packed(length, length_width)
        if versions is not None:
            immediate, original = versions
            payload += struct.pack('<I', immediate | ((1 << 31) if immediate != original else 0))
            if immediate != original:
                payload += struct.pack('<I', original)
        if ticket is not None:
            payload += struct.pack('<Q', ticket)
        expected = dict(kind=kind, sid=sid.hex(), flags=flags, gno=gno, last=last,
                        sequence=sequence, times=times, length=length, versions=versions, ticket=ticket)
        valid[name] = (kind, payload, expected)

    add('base')
    add('timestamp_zero', times=(0, 0))
    add('timestamp_distinct', times=(2**55 - 1, 2**56 - 1))
    for value in [0, 250, 251, 65535, 65536, 16777215, 16777216, 2**64 - 1]:
        add(f'length_{value}', times=(100, 100), length=value)
    for width in [2, 3, 8]:
        add(f'nonminimal_{width}', times=(1, 1), length=1, length_width=width)
    add('versions_zero', times=(0, 0), length=0, versions=(0, 0))
    add('versions_distinct', times=(10, 9), length=65536, versions=(2**31 - 1, 2**32 - 1))
    add('ticket_zero', times=(0, 0), length=0, versions=(0, 0), ticket=0)
    add('ticket_max', times=(0, 0), length=0, versions=(0, 0), ticket=2**64 - 1)
    add('max_gno', flags=0x81, gno=2**63 - 2, last=2**64 - 1, sequence=2**64 - 1)
    add('anonymous', kind=34, gno=0, sid=bytes(16), times=(1793013538890013, 1793013538890013),
        length=962, versions=(80043, 80043))
    add('anonymous_raw_sid', kind=34, gno=0, flags=0xff)
    add('full', flags=1, gno=2**32 + 1, last=5, sequence=6,
        times=(1793013538890013, 1793013538890000), length=65536,
        versions=(80043, 80036), ticket=31)

    base = valid['base'][1]
    ts = base + bytes(7)
    length = ts + packed(0)
    server = length + bytes(4)
    invalid = {f'short_base_{n}': (33, base[:n]) for n in range(42)}
    for value in [0, 2**63 - 1, 2**63, 2**64 - 1]:
        invalid[f'bad_gno_{value}'] = (33, base[:17] + struct.pack('<Q', value) + base[25:])
    invalid['anonymous_gno'] = (34, base)
    for code in [0, 1, 3, 255]:
        invalid[f'logical_type_{code}'] = (33, base[:25] + bytes([code]) + base[26:])
    for size in range(1, 7):
        invalid[f'short_immediate_ts_{size}'] = (33, base + bytes(size))
    flagged_ts = base + (1 << 55).to_bytes(7, 'little')
    for size in range(7):
        invalid[f'short_original_ts_{size}'] = (33, flagged_ts + bytes(size))
    for marker, width in [(252, 2), (253, 3), (254, 8)]:
        for size in range(width):
            invalid[f'short_length_{marker}_{size}'] = (33, ts + bytes([marker]) + bytes(size))
    for marker in [251, 255]:
        invalid[f'length_marker_{marker}'] = (33, ts + bytes([marker]))
    for size in range(1, 4):
        invalid[f'short_version_{size}'] = (33, length + bytes(size))
    for size in range(4):
        invalid[f'short_original_version_{size}'] = (33, length + struct.pack('<I', 1 << 31) + bytes(size))
    for size in range(1, 8):
        invalid[f'short_ticket_{size}'] = (33, server + bytes(size))
    invalid['trailing_ticket'] = (33, server + bytes(9))
    return valid, invalid


def literal(data):
    return 'b"' + ''.join(f'\\x{byte:02x}' for byte in data) + '"'


def expectation(e):
    pair = lambda value, suffix: 'None' if value is None else f'Some(({value[0]}{suffix}, {value[1]}{suffix}))'
    optional = lambda value: 'None' if value is None else f'Some({value}UL)'
    return ('{ ' + f'kind: {e["kind"]}, sid: {literal(bytes.fromhex(e["sid"]))}, flags: {e["flags"]}, '
            + f'gno: {e["gno"]}UL, last: {e["last"]}UL, sequence: {e["sequence"]}UL, '
            + f'times: {pair(e["times"], "UL")}, length: {optional(e["length"])}, '
            + f'versions: {pair(e["versions"], "U")}, ticket: {optional(e["ticket"])}' + ' }')


def generated():
    valid, invalid = fixtures()
    lines = ['// Copyright 2026 Noverberrain.', '// SPDX-License-Identifier: Apache-2.0', '',
             '// Generated independently by scripts/generate_gtid_fixtures.py.']
    manifest = {'valid': {}, 'invalid': {}, 'real_anonymous_oracles': []}
    auxiliary = {'gtid_fde_crc32': gtid_fde(), 'gtid_fde_off': gtid_fde(0),
                 'gtid_fde_missing': gtid_fde(count=32), 'gtid_fde_short': gtid_fde(width=25),
                 'gtid_fde_wrong': gtid_fde(width=43)}
    anonymous_short = bytearray(gtid_fde())
    anonymous_short[76 + 33] = 25
    anonymous_short[-4:] = struct.pack('<I', zlib.crc32(anonymous_short[:-4]))
    auxiliary['gtid_fde_anonymous_short'] = bytes(anonymous_short)
    bad = bytearray(event(33, valid['full'][1]))
    bad[-1] ^= 1
    auxiliary['gtid_bad_crc'] = bytes(bad)
    for name, raw in auxiliary.items():
        lines += ['', '///|', f'let {name} : Bytes = {literal(raw)}']
    lines += ['', '///|', 'fn gtid_valid() -> Array[(String, Bytes, Bytes, GtidExpected)] {', '  [']
    for name, (kind, payload, expected) in valid.items():
        crc, off = event(kind, payload), event(kind, payload, checksum=False)
        lines.append(f'    ("{name}", {literal(crc)}, {literal(off)}, {expectation(expected)}),')
        manifest['valid'][name] = {'crc32_sha256': hashlib.sha256(crc).hexdigest(),
                                 'off_sha256': hashlib.sha256(off).hexdigest(), 'expected': expected}
    lines += ['  ]', '}', '', '///|', 'fn gtid_invalid() -> Array[(String, Bytes)] {', '  [']
    for name, (kind, payload) in invalid.items():
        raw = event(kind, payload)
        lines.append(f'    ("{name}", {literal(raw)}),')
        manifest['invalid'][name] = hashlib.sha256(raw).hexdigest()
    lines += ['  ]', '}', '', '///|', 'fn gtid_real_oracles() -> Array[(Bytes, UInt64, GtidExpected)] {', '  [']
    for family, prefix in [('mysql-8.0', 'mysql'), ('mysql-json', 'mysql_json')]:
        folder = ROOT / 'fixtures' / family
        captures = json.loads((folder / 'manifest.json').read_text(encoding='utf-8'))
        for profile in ['crc32-full', 'crc32-minimal', 'off-full']:
            data = (folder / f'{profile}.binlog').read_bytes()
            dump = (folder / f'{profile}.mysqlbinlog.txt').read_bytes()
            hashes = captures['profiles'][profile]
            assert hashlib.sha256(data).hexdigest() == hashes['sha256']
            assert hashlib.sha256(dump).hexdigest() == hashes['oracle_sha256']
            pattern = (rb'# at (\d+)\r?\n[^\r\n]*Anonymous_GTID\s+last_committed=(\d+)\s+'
                       rb'sequence_number=(\d+)\s+rbr_only=(yes|no)\s+original_committed_timestamp=(\d+)\s+'
                       rb'immediate_commit_timestamp=(\d+)\s+transaction_length=(\d+)')
            matches = list(re.finditer(pattern, dump))
            assert len(matches) == 1
            offset, last, sequence, rbr, original, immediate, length = matches[0].groups()
            versions = re.findall(rb'SET @@session\.(?:original|immediate)_server_version=(\d+)', dump)
            assert len(versions) == 2
            expected = dict(kind=34, sid=bytes(16).hex(), flags=0 if rbr == b'yes' else 1,
                            gno=0, last=int(last), sequence=int(sequence), times=(int(immediate), int(original)),
                            length=int(length), versions=(int(versions[1]), int(versions[0])), ticket=None)
            lines.append(f'    ({prefix}_{profile.replace("-", "_")}, {int(offset)}UL, {expectation(expected)}),')
            manifest['real_anonymous_oracles'].append({'capture': f'{family}/{profile}', 'offset': int(offset),
                                                      'sha256': hashes['sha256'], 'oracle_sha256': hashes['oracle_sha256'],
                                                      'expected': expected})
    lines += ['  ]', '}']
    return {ROOT / 'gtid_fixture_test.mbt': '\n'.join(lines) + '\n',
            ROOT / 'fixtures/gtid/manifest.json': json.dumps(manifest, indent=2) + '\n'}


def verify_mysqlbinlog(executable):
    print(subprocess.run([executable, '--version'], capture_output=True, text=True, check=True).stdout.strip())
    valid, _ = fixtures()
    count = 0
    with tempfile.TemporaryDirectory(prefix='moonbinlog-gtid-') as folder:
        for name in ['base', 'anonymous', 'full', 'length_18446744073709551615']:
            kind, payload, expected = valid[name]
            for checksum in [True, False]:
                format_data = gtid_fde(int(checksum))
                raw = bytearray(event(kind, payload, checksum=checksum))
                struct.pack_into('<I', raw, 13, 4 + len(format_data) + len(raw))
                if checksum:
                    raw[-4:] = struct.pack('<I', zlib.crc32(raw[:-4]))
                path = Path(folder) / f'{name}-{checksum}.binlog'
                path.write_bytes(b'\xfebin' + format_data + raw)
                result = subprocess.run([executable, '--verify-binlog-checksum', str(path)],
                                        capture_output=True, text=True, check=True)
                identity = 'ANONYMOUS' if kind == 34 else f'{uuid.UUID(bytes=bytes.fromhex(expected["sid"]))}:{expected["gno"]}'
                assert re.search(r"SET @@SESSION.GTID_NEXT= '" + re.escape(identity) + r"'", result.stdout), result.stdout
                assert f'last_committed={expected["last"]}\tsequence_number={expected["sequence"]}' in result.stdout
                if expected['times'] is not None:
                    assert f'original_committed_timestamp={expected["times"][1]}' in result.stdout
                    assert f'immediate_commit_timestamp={expected["times"][0]}' in result.stdout
                    assert f'transaction_length={expected["length"]}' in result.stdout
                if expected['versions'] is not None:
                    for label, value in zip(['immediate', 'original'], expected['versions']):
                        assert f'@@session.{label}_server_version={value}' in result.stdout
                count += 1
    print(f'Official mysqlbinlog matched {count} assigned/anonymous synthetic GTID events')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--mysqlbinlog', help='Optional local official-tool comparison')
    args = parser.parse_args()
    for path, expected in generated().items():
        if args.check:
            normalize = lambda text: re.sub(r',([\)\]}])', r'\1', re.sub(r'\s+', '', text))
            assert normalize(path.read_text(encoding='utf-8')) == normalize(expected), path
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(expected, encoding='utf-8', newline='\n')
    valid, invalid = fixtures()
    print(f'{"Verified" if args.check else "Generated"} {len(valid) * 2} valid / {len(invalid)} invalid GTID vectors and 6 real anonymous oracles')
    if args.mysqlbinlog:
        verify_mysqlbinlog(args.mysqlbinlog)
