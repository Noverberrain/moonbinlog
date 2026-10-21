// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn floating_test_table() -> @moonbinlog.TableMap raise {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  @moonbinlog.TableMap::parse(format, tm_floating, file_offset=126)
}

///|
fn floating_decode_error(
  column : @moonbinlog.TableColumn,
  data : BytesView,
) -> @moonbinlog.DecodeError raise {
  try
    column.decode_floating(data, file_offset=0x100000123, column_index=7)
  catch {
    err => err
  } noraise {
    _ => fail("invalid floating value was accepted")
  }
}

///|
test "floating decoder matches independent Python values and exact finite bit patterns" {
  let table = floating_test_table()
  for (index, bytes, bits, expected) in floating_vectors {
    let decoded = table.columns[index].decode_floating(
      bytes,
      file_offset=256,
      column_index=index,
    )
    assert_eq(decoded.bits, bits)
    assert_eq(decoded.bytes_read, bytes.length())
    match decoded.value {
      Single(value) => {
        assert_eq(index, 0)
        assert_eq(value.to_double(), expected)
        assert_eq(value.reinterpret_as_uint().to_uint64(), bits)
      }
      DoublePrecision(value) => {
        assert_eq(index, 1)
        assert_eq(value, expected)
        assert_eq(value.reinterpret_as_uint64(), bits)
      }
    }
  }
}

///|
test "known values decode little-endian IEEE fields instead of numeric integer conversion" {
  let table = floating_test_table()
  let single = table.columns[0].decode_floating(
    b"\x00\x00\x80\x3f",
    file_offset=256,
    column_index=0,
  )
  assert_true(single.value is Single(value) && value.to_double() == 1.0)
  let double = table.columns[1].decode_floating(
    b"\x00\x00\x00\x00\x00\x00\x04\xc0",
    file_offset=256,
    column_index=1,
  )
  assert_true(double.value is DoublePrecision(-2.5))
  let decimal = table.columns[0].decode_floating(
    b"\xcd\xcc\xcc\x3d",
    file_offset=256,
    column_index=0,
  )
  assert_true(
    decimal.value is Single(value) &&
    value.to_double() == 0.10000000149011612 &&
    value.to_double() != 0.1,
  )
}

///|
test "positive and negative nullable zero retain their sign bits and numeric reciprocal" {
  let table = floating_test_table()
  for
    (index, bytes, bits) in [
      (0, b"\x00\x00\x00\x00", 0UL),
      (0, b"\x00\x00\x00\x80", 0x80000000UL),
      (1, b"\x00\x00\x00\x00\x00\x00\x00\x00", 0UL),
      (1, b"\x00\x00\x00\x00\x00\x00\x00\x80", 0x8000000000000000UL),
    ] {
    assert_true(table.columns[index].nullable)
    let decoded = table.columns[index].decode_floating(
      bytes,
      file_offset=256,
      column_index=index,
    )
    assert_eq(decoded.bits, bits)
    let value = match decoded.value {
      Single(value) => value.to_double()
      DoublePrecision(value) => value
    }
    assert_eq(value, 0.0)
    assert_eq((1.0 / value).is_neg_inf(), bits != 0)
  }
}

///|
test "finite subnormals are not flushed to zero and maxima remain finite" {
  let table = floating_test_table()
  for
    (index, bytes) in [
      (0, b"\x01\x00\x00\x00"),
      (1, b"\x01\x00\x00\x00\x00\x00\x00\x00"),
      (0, b"\xff\xff\x7f\x7f"),
      (1, b"\xff\xff\xff\xff\xff\xff\xef\x7f"),
    ] {
    let decoded = table.columns[index].decode_floating(
      bytes,
      file_offset=256,
      column_index=index,
    )
    let value = match decoded.value {
      Single(value) => value.to_double()
      DoublePrecision(value) => value
    }
    assert_true(value > 0.0 && !value.is_inf() && !value.is_nan())
  }
}

///|
test "infinities quiet and signaling NaNs report original bits without conversion" {
  let table = floating_test_table()
  for (index, bytes, expected) in floating_nonfinite {
    match floating_decode_error(table.columns[index], bytes) {
      NonFiniteFloatingValue(file_offset~, column_index~, wire_type~, bits~) => {
        assert_eq(file_offset, 0x100000123UL)
        assert_eq(column_index, 7)
        assert_eq(wire_type, table.columns[index].wire_type)
        assert_eq(bits, expected)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "every short FLOAT and DOUBLE input reports complete field width" {
  let table = floating_test_table()
  for (index, bytes, _, _) in floating_vectors {
    for available in 0..<bytes.length() {
      match floating_decode_error(table.columns[index], bytes[:available]) {
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
test "zero mismatched and high-bit floating metadata fail before reading the field" {
  let table = floating_test_table()
  for index in 2..<8 {
    match floating_decode_error(table.columns[index], b"") {
      InvalidFloatingMetadata(file_offset~, column_index~, expected_width~) => {
        assert_eq(file_offset, 0x100000123UL)
        assert_eq(column_index, 7)
        assert_eq(expected_width, if index < 5 { 4 } else { 8 })
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "floating decoder explicitly rejects integer decimal string blob and temporal columns" {
  let table = integer_test_table()
  for column in table.columns {
    match floating_decode_error(column, b"\x00\x00\x00\x00\x00\x00\x00\x00") {
      UnsupportedFloatingColumn(file_offset~, column_index~, wire_type~) => {
        assert_eq(file_offset, 0x100000123UL)
        assert_eq(column_index, 7)
        assert_eq(wire_type, column.wire_type)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "nested slices and mixed floating integer fields consume only their own bytes" {
  let storage = b"guard\x00\x00\x80\x3f\x00\x00\x00\x00\x00\x00\x04\xc0\xffsuffix"
  let view = storage[5:18]
  let table = floating_test_table()
  let first = table.columns[0].decode_floating(
    view,
    file_offset=256,
    column_index=0,
  )
  let second = table.columns[1].decode_floating(
    view[first.bytes_read:],
    file_offset=260,
    column_index=1,
  )
  let cursor = first.bytes_read + second.bytes_read
  let third = integer_test_table().columns[6].decode_integer(
    view[cursor:],
    unsigned=false,
    file_offset=268,
    column_index=6,
  )
  assert_true(first.value is Single(value) && value.to_double() == 1.0)
  assert_true(second.value is DoublePrecision(-2.5))
  assert_true(third.value is Signed(-1))
  assert_eq(cursor + third.bytes_read, view.length())
}
