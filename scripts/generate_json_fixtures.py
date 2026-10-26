# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Independently encode MySQL binary JSON layouts, not upstream implementation code."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

sys.dont_write_bytecode = True
from generate_format_fixtures import event
from generate_table_map_fixtures import body
from generate_transaction_fixtures import query, stream

ROOT = Path(__file__).resolve().parents[1]
TABLE_ID = 0x010203040506


def varint(length):
    result = bytearray()
    while length >= 128:
        result.append((length & 127) | 128)
        length >>= 7
    return bytes(result + bytes([length]))


def scalar(tag, value):
    if tag == 4:
        return tag, bytes([0 if value is None else 1 if value else 2]), value
    if 5 <= tag <= 10:
        width = {5: 2, 6: 2, 7: 4, 8: 4, 9: 8, 10: 8}[tag]
        return tag, value.to_bytes(width, 'little', signed=tag in {5, 7, 9}), value
    if tag == 11:
        return tag, struct.pack('<d', value), value
    encoded = value.encode('utf-8')
    return 12, varint(len(encoded)) + encoded, value


def container(children, object=False, large=False, gap=0, reverse=False):
    width = 4 if large else 2
    if object:
        children = sorted(children, key=lambda item: (len(item[0].encode()), item[0].encode()))
        keys = [key.encode() for key, _ in children]
        values = [value for _, value in children]
        expected = {key: value[2] for key, value in children}
    else:
        keys, values = [], children
        expected = [value[2] for value in values]
    count = len(values)
    header = 2 * width + len(keys) * (width + 2) + count * (width + 1)
    data, key_entries, entries = bytearray(), bytearray(), {}
    for key in keys:
        key_entries += (header + len(data)).to_bytes(width, 'little') + len(key).to_bytes(2, 'little')
        data += key
    data += b'\xee' * gap
    indices = list(range(count))
    for i in (reversed(indices) if reverse else indices):
        tag, payload, _ = values[i]
        inline = tag in {4, 5, 6} or (large and tag in {7, 8})
        if inline:
            encoded = payload.ljust(width, b'\xa5')  # ignored inline padding
        else:
            encoded = (header + len(data)).to_bytes(width, 'little')
            data += payload
        entries[i] = bytes([tag]) + encoded
    size = header + len(data)
    payload = count.to_bytes(width, 'little') + size.to_bytes(width, 'little') + key_entries
    payload += b''.join(entries[i] for i in indices) + data
    return (1 if large else 0) if object else (3 if large else 2), payload, expected


def document(value):
    return bytes([value[0]]) + value[1]


def field(payload, width=4):
    return len(payload).to_bytes(width, 'little') + payload


def vectors():
    values = [scalar(4, value) for value in [None, True, False]]
    for tag, limits in [(5, [-32768, 32767]), (6, [0, 65535]),
                        (7, [-2**31, 2**31 - 1]), (8, [0, 2**32 - 1]),
                        (9, [-2**63, 2**63 - 1]), (10, [0, 2**64 - 1])]:
        values += [scalar(tag, value) for value in limits]
    values += [scalar(11, value) for value in [-0.0, 1.5, 5e-324]]
    values += [scalar(12, value) for value in ['', '中文😀\x00"\\\n', 'a' * 128, '\ufeffabc']]
    nested = container([('u', scalar(10, 2**64 - 1)), ('i', scalar(9, -2**63)),
                        ('text', scalar(12, '中文')), ('array', container(values[:5]))], object=True)
    for large in [False, True]:
        values += [container([], large=large), container([], object=True, large=large),
                   container([scalar(4, None), scalar(7, -123456), scalar(8, 2**32 - 1), nested], large=large),
                   container([('long', scalar(12, 'x')), ('a', scalar(5, -1)), ('ab', nested)],
                             object=True, large=large, gap=3, reverse=True)]
    values.append(nested)
    valid = [(document(value), json.dumps(value[2], ensure_ascii=False, separators=(',', ':'))) for value in values]
    bad = [b'', b'\x04\xff', b'\x0d', b'\x0f\xf6\0', b'\x04\0x', b'\x0c\x80',
           b'\x0c' + b'\x80' * 5, b'\x0c\xff\xff\xff\xff\x7f', b'\x0c\x01\xff']
    bad += [b'\x0b' + struct.pack('<Q', bits) for bits in [0x7ff0000000000000, 0xfff0000000000000, 0x7ff8000000000001]]
    array = bytearray(document(container([scalar(12, 'first'), scalar(12, 'second')])))
    alias = array.copy()
    alias[9:11] = alias[6:8]
    bad.append(bytes(alias))
    for offset in [0, 4, 65535]:
        changed = array.copy()
        changed[6:8] = offset.to_bytes(2, 'little')
        bad.append(bytes(changed))
    for size in [0, 3, 65535]:
        changed = array.copy()
        changed[3:5] = size.to_bytes(2, 'little')
        bad.append(bytes(changed))
    obj = bytearray(document(container([('a', scalar(4, True)), ('b', scalar(12, 'x'))], object=True)))
    key_start = int.from_bytes(obj[5:7], 'little') + 1
    for replacement in [b'ba', b'aa', b'a\xff']:
        changed = obj.copy()
        changed[key_start:key_start + 2] = replacement
        bad.append(bytes(changed))
    changed = obj.copy()
    changed[9:11] = changed[5:7]
    bad.append(bytes(changed))
    bad += [b'\x03' + (2**32 - 1).to_bytes(4, 'little') + (8).to_bytes(4, 'little')]
    return valid, bad


def fixtures():
    valid, _ = vectors()
    payload = valid[-1][0]
    table = event(19, body(types=bytes([3, 245]), metadata=b'\x04', nullable=b'\x02'))
    row = b'\0' + struct.pack('<i', 1) + field(payload)
    images = row + b'\x02' + struct.pack('<i', 2) + b'\0' + struct.pack('<i', 3) + field(b'\x04\0')
    fixed = TABLE_ID.to_bytes(6, 'little') + struct.pack('<HH', 1, 2) + b'\x02'
    insert = event(30, fixed + b'\x03' + images)
    update = event(31, fixed + b'\x03\x02' + row + b'\0' + field(document(scalar(12, '更新'))))
    delete_row = b'\0' + struct.pack('<i', 1) + field(document(scalar(12, '更新')))
    delete = event(32, fixed + b'\x03' + delete_row)
    xid = event(16, (2**64 - 1).to_bytes(8, 'little'))
    return {
        'tm_json': event(19, body(types=bytes([245] * 6), metadata=bytes([1, 2, 3, 4, 0, 5]), nullable=b'\x3f')),
        'tm_json_rows': table, 'rows_json_insert': insert, 'rows_json_update': update,
        'rows_json_delete': delete,
        'rows_json_bad': event(30, fixed + b'\x03\0' + struct.pack('<i', 1) + field(b'\x04\xff')),
        'json_transaction': stream([query(b'BEGIN'), table, insert, table, update, table, delete, xid]),
    }


def generated_files():
    valid, bad = vectors()
    samples = fixtures()
    lines = ['// Copyright 2026 Noverberrain.', '// SPDX-License-Identifier: Apache-2.0', '',
             '// Generated by scripts/generate_json_fixtures.py.']
    def literal(data):
        return 'b"' + ''.join(f'\\x{byte:02x}' for byte in data) + '"'
    for name, data in samples.items():
        lines += ['', '///|', f'let {name} : Bytes = {literal(data)}']
    lines += ['', '///|', 'let json_valid_cases : ReadOnlyArray[(Bytes, String)] = [']
    lines += [f'  ({literal(data)}, {json.dumps(text, ensure_ascii=False)}),' for data, text in valid]
    lines += [']', '', '///|', 'let json_invalid_cases : ReadOnlyArray[Bytes] = [']
    lines += [f'  {literal(data)},' for data in bad]
    lines += [']', '']
    manifest = {'valid': [{'sha256': hashlib.sha256(data).hexdigest(), 'json': text} for data, text in valid],
                'invalid': [hashlib.sha256(data).hexdigest() for data in bad],
                'events': {key: hashlib.sha256(data).hexdigest() for key, data in samples.items()}}
    return {ROOT / 'json_fixture_test.mbt': '\n'.join(lines),
            ROOT / 'fixtures/json/manifest.json': json.dumps(manifest, ensure_ascii=False, indent=2) + '\n'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    for path, expected in generated_files().items():
        if args.check:
            normalize = lambda text: re.sub(r',([\)\]])', r'\1', re.sub(r'\s+', '', text))
            if normalize(path.read_text(encoding='utf-8')) != normalize(expected):
                raise SystemExit(f'JSON fixture differs: {path}')
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(expected, encoding='utf-8', newline='\n')
    valid, invalid = vectors()
    print(f'{"Verified" if args.check else "Generated"} {len(valid)} valid / {len(invalid)} invalid binary JSON vectors')
