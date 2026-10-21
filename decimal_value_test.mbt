// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn decimal_test_table() -> @moonbinlog.TableMap raise {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  @moonbinlog.TableMap::parse(format, tm_decimals, file_offset=126)
}

///|
fn decimal_decode_error(
  column : @moonbinlog.TableColumn,
  data : BytesView,
) -> @moonbinlog.DecodeError raise {
  try
    column.decode_decimal(data, file_offset=0x100000123, column_index=7)
  catch {
    err => err
  } noraise {
    _ => fail("invalid decimal was accepted")
  }
}

///|
test "DECIMAL agrees with Python Decimal expectations for every generated vector" {
  let table = decimal_test_table()
  for (index, bytes, expected) in decimal_vectors {
    let decoded = table.columns[index].decode_decimal(
      bytes,
      file_offset=256,
      column_index=index,
    )
    let (precision, scale) = decimal_shapes[index]
    assert_eq(decoded.value, expected)
    assert_eq(decoded.precision, precision)
    assert_eq(decoded.scale, scale)
    assert_eq(decoded.bytes_read, bytes.length())
  }
}

///|
test "known money literals decode big-endian groups and opposite sign masks" {
  let column = integer_test_table().columns[2] // DECIMAL(10,2)
  for
    (bytes, expected) in [
      (b"\x80\x00\x30\x39\x43", "12345.67"),
      (b"\x7f\xff\xcf\xc6\xbc", "-12345.67"),
      (b"\x80\x00\x00\x7b\x2d", "123.45"),
    ] {
    let decoded = column.decode_decimal(bytes, file_offset=256, column_index=2)
    assert_eq(decoded.value, expected)
    assert_eq(decoded.bytes_read, 5)
  }
}

///|
test "65-digit decimals retain every digit beyond floating and UInt64 precision" {
  let table = decimal_test_table()
  let maximum = b"\xe3" + b"\x3b\x9a\xc9\xff".repeat(7)
  assert_eq(
    table.columns[21].decode_decimal(maximum, file_offset=256, column_index=21).value,
    "9".repeat(65),
  )
  let fractional = b"\x85\xf5\xe0\xff" +
    b"\x3b\x9a\xc9\xff".repeat(6) +
    b"\x03\xe7"
  assert_eq(
    table.columns[22].decode_decimal(
      fractional,
      file_offset=256,
      column_index=22,
    ).value,
    "9".repeat(35) + "." + "9".repeat(30),
  )
  assert_eq(decimal_shapes[21], (65, 0))
  assert_eq(decimal_shapes[22], (65, 30))
}

///|
test "scale and grouped fractional leading zeros survive while integer padding is removed" {
  let table = decimal_test_table()
  let tiny = table.columns[19].decode_decimal(
    b"\x80\x00\x00\x00\x00\x00\x00\x01",
    file_offset=256,
    column_index=19,
  )
  assert_eq(tiny.value, "0.000000001")
  let trailing = table.columns[4].decode_decimal(
    b"\x80\x00\x7b",
    file_offset=256,
    column_index=4,
  )
  assert_eq(trailing.value, "123")
  let money = table.columns[18].decode_decimal(
    b"\x80\x00\x00\x7b\x28",
    file_offset=256,
    column_index=18,
  )
  assert_eq(money.value, "123.40")
  let padded = b"\x80" + b"\x00".repeat(20) + b"\x00\x00\x00\x01".repeat(2)
  assert_eq(
    table.columns[21].decode_decimal(padded, file_offset=256, column_index=21).value,
    "1000000001",
  )
  let zero = table.columns[23].decode_decimal(
    Bytes::makei(14, i => if i == 0 { 0x80 } else { 0 }),
    file_offset=256,
    column_index=23,
  )
  assert_eq(zero.value, "0.000000000000000000000000000000")
}

///|
test "negative zero is normalized with the declared scale for every shape" {
  let table = decimal_test_table()
  for (index, bytes, expected) in decimal_vectors {
    if bytes[0] == 0x80 && bytes[1:].iter().all(byte => byte == 0) {
      let negative_zero = Bytes::makei(bytes.length(), i => {
        (bytes[i].to_int() ^ 255).to_byte()
      })
      let column = table.columns[index]
      assert_true(column.nullable)
      assert_eq(
        column.decode_decimal(
          negative_zero,
          file_offset=256,
          column_index=index,
        ).value,
        expected,
      )
    }
  }
}

///|
test "every truncated decimal prefix reports field location and total width" {
  let table = decimal_test_table()
  for (index, bytes, _) in decimal_vectors {
    for available in 0..<bytes.length() {
      match decimal_decode_error(table.columns[index], bytes[:available]) {
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
test "invalid precision scale and MySQL maxima are rejected before reading values" {
  let table = decimal_test_table()
  for index in decimal_shapes.length()..<table.columns.length() {
    match decimal_decode_error(table.columns[index], b"") {
      InvalidDecimalMetadata(file_offset~, column_index~, ..) => {
        assert_eq(file_offset, 0x100000123UL)
        assert_eq(column_index, 7)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "out of range full and partial groups are rejected at the damaged group offset" {
  let table = decimal_test_table()
  for
    (index, bytes, offset) in [
      (0, b"\x8a", 0),
      (0, b"\x75", 0),
      (8, b"\xbb\x9a\xca\x00", 0),
      (18, b"\x80\x00\x00\x00\x64", 4),
      (18, b"\x7f\xff\xff\xff\x9b", 4),
      (19, b"\x80\x00\x00\x00\x3b\x9a\xca\x00", 4),
    ] {
    match decimal_decode_error(table.columns[index], bytes) {
      InvalidDecimalValue(file_offset~, column_index~, value_offset~) => {
        assert_eq(file_offset, 0x100000123UL)
        assert_eq(column_index, 7)
        assert_eq(value_offset, offset)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "decimal decoder rejects integer string temporal and BLOB columns" {
  let table = integer_test_table()
  for index in [0, 1, 3, 4, 5, 6, 7, 8, 9] {
    match decimal_decode_error(table.columns[index], b"\x80\x00\x00\x00\x00") {
      UnsupportedDecimalColumn(file_offset~, column_index~, wire_type~) => {
        assert_eq(file_offset, 0x100000123UL)
        assert_eq(column_index, 7)
        assert_eq(wire_type, table.columns[index].wire_type)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "nested view decimal and integer fields consume exactly their own bytes" {
  let storage = b"guard\x80\x00\x30\x39\x43\xffsuffix"
  let view = storage[5:11]
  let table = integer_test_table()
  let first = table.columns[2].decode_decimal(
    view,
    file_offset=256,
    column_index=2,
  )
  let second = table.columns[6].decode_integer(
    view[first.bytes_read:],
    unsigned=false,
    file_offset=261,
    column_index=6,
  )
  assert_eq(first.value, "12345.67")
  assert_true(second.value is Signed(-1))
  assert_eq(first.bytes_read + second.bytes_read, view.length())
}
