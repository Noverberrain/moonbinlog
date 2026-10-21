// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn bit_test_table() -> @moonbinlog.TableMap raise {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  @moonbinlog.TableMap::parse(format, tm_bits, file_offset=126)
}

///|
fn bit_decode_error(
  column : @moonbinlog.TableColumn,
  data : BytesView,
) -> @moonbinlog.DecodeError raise {
  try column.decode_bit(data, file_offset=0x100000123, column_index=7) catch {
    err => err
  } noraise {
    _ => fail("invalid BIT was accepted")
  }
}

///|
test "BIT matches independent Python integers for every width from one to sixty-four" {
  let table = bit_test_table()
  for (index, bytes, expected) in bit_vectors {
    let decoded = table.columns[index].decode_bit(
      bytes,
      file_offset=256,
      column_index=index,
    )
    assert_eq(decoded.value, expected)
    assert_eq(decoded.bit_length, index + 1)
    assert_eq(decoded.bytes_read, bytes.length())
  }
}

///|
test "partial-byte high padding is ignored while all declared bits are retained" {
  let table = bit_test_table()
  for (index, bytes, expected) in bit_vectors {
    let remainder = (index + 1) % 8
    if remainder == 0 {
      continue
    }
    let padding = 255 ^ ((1 << remainder) - 1)
    let padded = Bytes::makei(bytes.length(), i => {
      if i == 0 {
        (bytes[i].to_int() | padding).to_byte()
      } else {
        bytes[i]
      }
    })
    let decoded = table.columns[index].decode_bit(
      padded,
      file_offset=256,
      column_index=index,
    )
    assert_eq(decoded.value, expected)
    assert_eq(decoded.bit_length, index + 1)
    assert_eq(decoded.bytes_read, bytes.length())
  }
}

///|
test "invalid zero excessive and malformed BIT widths fail before reading data" {
  let table = bit_test_table()
  for index in 64..<table.columns.length() {
    match bit_decode_error(table.columns[index], b"") {
      InvalidBitMetadata(file_offset~, column_index~, ..) => {
        assert_eq(file_offset, 0x100000123UL)
        assert_eq(column_index, 7)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "every truncated BIT prefix reports total field size and physical location" {
  let table = bit_test_table()
  for (index, bytes, _) in bit_vectors {
    for available in 0..<bytes.length() {
      match bit_decode_error(table.columns[index], bytes[:available]) {
        TruncatedColumnValue(file_offset~, column_index~, expected~, actual~) => {
          assert_eq(file_offset, 0x100000123UL)
          assert_eq(column_index, 7)
          assert_eq(expected, bytes.length())
          assert_eq(actual, available)
        }
        other => fail("unexpected error: \{Repr(other)}")
      }
    }
  }
}

///|
test "BIT64 keeps its high bit and full unsigned maximum without shift-by-width overflow" {
  let column = bit_test_table().columns[63]
  let maximum = column.decode_bit(
    b"\xff\xff\xff\xff\xff\xff\xff\xff",
    file_offset=256,
    column_index=63,
  )
  assert_eq(maximum.value.to_string(), "18446744073709551615")
  let high = column.decode_bit(
    b"\x80\x00\x00\x00\x00\x00\x00\x00",
    file_offset=256,
    column_index=63,
  )
  assert_eq(high.value, 0x8000000000000000UL)
  assert_eq(high.bit_length, 64)
  assert_eq(high.bytes_read, 8)
}

///|
test "known BIT patterns use big endian and retain declared leading-zero width" {
  let table = bit_test_table()
  for
    (index, bytes, expected) in [
      (15, b"\x12\x34", 4660UL),
      (8, b"\x01\x02", 258UL),
      (6, b"\x55", 85UL),
      (63, b"\x01\x02\x03\x04\x05\x06\x07\x08", 0x0102030405060708UL),
    ] {
    let decoded = table.columns[index].decode_bit(
      bytes,
      file_offset=256,
      column_index=index,
    )
    assert_eq(decoded.value, expected)
    assert_eq(decoded.bit_length, index + 1)
  }
}

///|
test "BIT1 exhaustively extracts the declared bit without treating nullable zero as NULL" {
  let column = bit_test_table().columns[0]
  assert_true(column.nullable)
  for byte in 0..<256 {
    let decoded = column.decode_bit(
      Bytes::from_array([byte.to_byte()]),
      file_offset=256,
      column_index=0,
    )
    assert_eq(decoded.value, (byte & 1).reinterpret_as_uint().to_uint64())
    assert_eq(decoded.bit_length, 1)
    assert_eq(decoded.bytes_read, 1)
  }
}

///|
test "non-BIT integer string decimal blob and temporal columns fail explicitly" {
  let table = integer_test_table()
  for column in table.columns {
    match bit_decode_error(column, b"\x00\x00\x00\x00\x00\x00\x00\x00") {
      UnsupportedBitColumn(file_offset~, column_index~, wire_type~) => {
        assert_eq(file_offset, 0x100000123UL)
        assert_eq(column_index, 7)
        assert_eq(wire_type, column.wire_type)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "nested slices and adjacent BIT integer fields do not consume trailing bytes" {
  let storage = b"guard\x01\xaa\xff\xff\xff\xff\xff\xff\xff\xff\xffsuffix"
  let view = storage[5:16]
  let table = bit_test_table()
  let first = table.columns[8].decode_bit(view, file_offset=256, column_index=8)
  let second = table.columns[63].decode_bit(
    view[first.bytes_read:],
    file_offset=258,
    column_index=63,
  )
  let cursor = first.bytes_read + second.bytes_read
  let third = integer_test_table().columns[6].decode_integer(
    view[cursor:],
    unsigned=false,
    file_offset=266,
    column_index=6,
  )
  assert_eq(first.value, 426UL)
  assert_eq(second.value, 0xffffffffffffffffUL)
  assert_true(third.value is Signed(-1))
  assert_eq(cursor + third.bytes_read, view.length())
}
