# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Encode rotation vectors independently and extract six official capture oracles."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
import zlib

sys.dont_write_bytecode = True
from generate_format_fixtures import event, fde

ROOT = Path(__file__).resolve().parents[1]


def fixtures():
    target = b'mysql-bin.000002'
    samples = {}
    for name, position in [('zero', 0), ('start', 4), ('wide', 2**32 + 4), ('max', 2**64 - 1)]:
        samples[f'rotate_{name}'] = event(4, struct.pack('<Q', position) + target)
    samples['rotate_off'] = event(4, struct.pack('<Q', 0xfedcba9876543210) + b'off.000099', checksum=False)
    samples['rotate_raw_name'] = event(4, struct.pack('<Q', 4) + b'../\xff\0\xef\xbb\xbf\\name')
    samples['rotate_one_byte_name'] = event(4, struct.pack('<Q', 4) + b'\0')
    synthetic = bytearray(event(4, struct.pack('<Q', 4) + target, flags=0x8020))
    synthetic[:4] = bytes(4)  # A zero timestamp does not change the body layout.
    synthetic[13:17] = bytes(4)
    synthetic[-4:] = struct.pack('<I', zlib.crc32(synthetic[:-4]))
    samples['rotate_zero_timestamp'] = bytes(synthetic)
    for size in range(9):
        samples[f'rotate_short_{size}'] = event(4, bytes(size))
    bad = bytearray(samples['rotate_start'])
    bad[-1] ^= 1
    samples['rotate_bad_crc'] = bytes(bad)
    for width in [0, 7, 9]:
        raw = bytearray(fde())
        raw[76 + 3] = width
        raw[-4:] = struct.pack('<I', zlib.crc32(raw[:-4]))
        samples[f'fde_rotate_{width}'] = bytes(raw)
    return samples


def generated():
    samples = fixtures()
    lines = ['// Copyright 2026 Noverberrain.', '// SPDX-License-Identifier: Apache-2.0', '',
             '// Generated independently by scripts/generate_rotate_fixtures.py.']
    for name, data in samples.items():
        lines += ['', '///|', f'let {name} : Bytes = [']
        for i in range(0, len(data), 12):
            lines.append('  ' + ', '.join(f'0x{n:02x}' for n in data[i:i + 12]) + ',')
        lines.append(']')
    manifest = {'synthetic': {name: hashlib.sha256(data).hexdigest() for name, data in samples.items()},
                'real_oracles': []}
    lines += ['', '///|', 'let rotate_real_oracles : ReadOnlyArray[(Bytes, UInt64, Bytes)] = [']
    for family, prefix in [('mysql-8.0', 'mysql'), ('mysql-json', 'mysql_json')]:
        capture = ROOT / 'fixtures' / family
        source_manifest = json.loads((capture / 'manifest.json').read_text(encoding='utf-8'))
        for profile in ['crc32-full', 'crc32-minimal', 'off-full']:
            raw = (capture / f'{profile}.binlog').read_bytes()
            dump = (capture / f'{profile}.mysqlbinlog.txt').read_bytes()
            expected = source_manifest['profiles'][profile]
            assert hashlib.sha256(raw).hexdigest() == expected['sha256']
            assert hashlib.sha256(dump).hexdigest() == expected['oracle_sha256']
            matches = re.findall(rb'Rotate to ([^\r\n]+?)  pos: (\d+)\r?$', dump, re.M)
            assert len(matches) == 1
            filename, position = matches[0]
            literal = 'b"' + ''.join(f'\\x{byte:02x}' for byte in filename) + '"'
            lines.append(f'  ({prefix}_{profile.replace("-", "_")}, {int(position)}UL, {literal}),')
            manifest['real_oracles'].append({'capture': f'{family}/{profile}', 'sha256': expected['sha256'],
                                            'oracle_sha256': expected['oracle_sha256'],
                                            'position': int(position), 'next_binlog_hex': filename.hex()})
    lines.append(']')
    return {ROOT / 'rotate_fixture_test.mbt': '\n'.join(lines) + '\n',
            ROOT / 'fixtures/rotate/manifest.json': json.dumps(manifest, indent=2) + '\n'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    for path, expected in generated().items():
        if args.check:
            normalize = lambda text: re.sub(r',([\)\]])', r'\1', re.sub(r'\s+', '', text))
            assert normalize(path.read_text(encoding='utf-8')) == normalize(expected), path
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(expected, encoding='utf-8', newline='\n')
    print(f'{"Verified" if args.check else "Generated"} {len(fixtures())} rotation vectors and 6 official rotation oracles')
