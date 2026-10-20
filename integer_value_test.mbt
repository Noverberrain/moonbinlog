// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn integer_test_table() -> @moonbinlog.TableMap raise {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  @moonbinlog.TableMap::parse(format, tm_basic, file_offset=126)
}

///|
test "integer decoder agrees with independent Python vectors for all five widths" {
  let table = integer_test_table()
  for (index, bytes, signed, unsigned) in integer_vectors {
    let column = table.columns[index]
    let signed_value = column.decode_integer(
      bytes,
      unsigned=false,
      file_offset=256,
      column_index=index,
    )
    let unsigned_value = column.decode_integer(
      bytes,
      unsigned=true,
      file_offset=256,
      column_index=index,
    )
    match signed_value.value {
      Signed(value) => assert_eq(value.to_string(), signed)
      _ => fail("signedness tag lost")
    }
    match unsigned_value.value {
      Unsigned(value) => assert_eq(value.to_string(), unsigned)
      _ => fail("signedness tag lost")
    }
    assert_eq(signed_value.bytes_read, bytes.length())
    assert_eq(unsigned_value.bytes_read, bytes.length())
  }
}

///|
test "TINYINT exhaustively decodes all 256 patterns in both signedness modes" {
  let column = integer_test_table().columns[6]
  for raw in 0..<256 {
    let bytes = Bytes::makei(1, _ => raw.to_byte())
    let signed = column.decode_integer(
      bytes,
      unsigned=false,
      file_offset=256,
      column_index=6,
    )
    let unsigned = column.decode_integer(
      bytes,
      unsigned=true,
      file_offset=256,
      column_index=6,
    )
    let expected = if raw < 128 { raw } else { raw - 256 }
    match signed.value {
      Signed(value) => assert_eq(value.to_string(), "\{expected}")
      _ => fail("expected a signed integer")
    }
    match unsigned.value {
      Unsigned(value) => assert_eq(value.to_string(), "\{raw}")
      _ => fail("expected an unsigned integer")
    }
  }
}

///|
test "MEDIUMINT sign extension uses exactly 24 bits" {
  let column = integer_test_table().columns[8]
  for
    (bytes, expected) in [
      (([0, 0, 0x80] : Bytes), "-8388608"),
      (([0xff, 0xff, 0x7f] : Bytes), "8388607"),
      (([0xff, 0xff, 0xff] : Bytes), "-1"),
    ] {
    let decoded = column.decode_integer(
      bytes,
      unsigned=false,
      file_offset=256,
      column_index=8,
    )
    assert_eq(decoded.bytes_read, 3)
    match decoded.value {
      Signed(value) => assert_eq(value.to_string(), expected)
      _ => fail("expected signed MEDIUMINT")
    }
  }
}

///|
test "BIGINT preserves signed minimum and unsigned maximum without floating point" {
  let column = integer_test_table().columns[0]
  let minimum : Bytes = [0, 0, 0, 0, 0, 0, 0, 0x80]
  let maximum = Bytes::makei(8, _ => 0xff)
  let signed = column.decode_integer(
    minimum,
    unsigned=false,
    file_offset=256,
    column_index=0,
  )
  let unsigned = column.decode_integer(
    maximum,
    unsigned=true,
    file_offset=256,
    column_index=0,
  )
  match signed.value {
    Signed(value) => assert_eq(value.to_string(), "-9223372036854775808")
    _ => fail("expected signed BIGINT")
  }
  match unsigned.value {
    Unsigned(value) => assert_eq(value.to_string(), "18446744073709551615")
    _ => fail("expected unsigned BIGINT")
  }
}

///|
test "integer fields reject every truncated prefix and preserve diagnostic location" {
  let table = integer_test_table()
  for (index, width) in [(6, 1), (7, 2), (8, 3), (5, 4), (0, 8)] {
    for length in 0..<width {
      let bytes = Bytes::makei(length, _ => 0xff)
      try
        table.columns[index].decode_integer(
          bytes,
          unsigned=false,
          file_offset=0x100000100,
          column_index=index,
        )
      catch {
        TruncatedColumnValue(file_offset~, column_index~, expected~, actual~) => {
          assert_eq(file_offset, 0x100000100UL)
          assert_eq(column_index, index)
          assert_eq(expected, width)
          assert_eq(actual, length)
        }
        other => fail("unexpected error: \{Repr(other)}")
      } noraise {
        _ => fail("truncated integer was accepted")
      }
    }
  }
}

///|
test "integer decoder consumes only its width inside a nested view" {
  let column = integer_test_table().columns[7]
  let bytes : Bytes = [0x99, 0x88, 0x34, 0x92, 0xff, 0xff]
  let decoded = column.decode_integer(
    bytes[2:],
    unsigned=true,
    file_offset=256,
    column_index=7,
  )
  assert_eq(decoded.bytes_read, 2)
  assert_true(decoded.value is Unsigned(0x9234))
}

///|
test "consumed lengths allow adjacent integer fields without overlapping reads" {
  let table = integer_test_table()
  let bytes : Bytes = [
    0xff, 0x00, 0x80, 0xff, 0xff, 0x7f, 0, 0, 0, 0x80, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff,
  ]
  let expected = ["-1", "-32768", "8388607", "-2147483648", "-1"]
  let mut cursor = 0
  for i, index in [6, 7, 8, 5, 0] {
    let decoded = table.columns[index].decode_integer(
      bytes[cursor:],
      unsigned=false,
      file_offset=256,
      column_index=index,
    )
    match decoded.value {
      Signed(value) => assert_eq(value.to_string(), expected[i])
      _ => fail("expected signed field")
    }
    cursor += decoded.bytes_read
  }
  assert_eq(cursor, bytes.length())
}

///|
test "non-integer types fail explicitly instead of being coerced" {
  let table = integer_test_table()
  for index in [1, 2, 3, 4, 9] {
    let column = table.columns[index]
    try
      column.decode_integer(
        b"arbitrary long bytes",
        unsigned=true,
        file_offset=256,
        column_index=index,
      )
    catch {
      UnsupportedIntegerColumn(file_offset~, column_index~, wire_type~) => {
        assert_eq(file_offset, 256UL)
        assert_eq(column_index, index)
        assert_eq(wire_type, column.wire_type)
      }
      other => fail("unexpected error: \{Repr(other)}")
    } noraise {
      _ => fail("non-integer was coerced")
    }
  }
}

///|
test "nullable column capability is not mistaken for a NULL row value" {
  let column = integer_test_table().columns[0]
  assert_true(column.nullable)
  let decoded = column.decode_integer(
    Bytes::makei(8, _ => 0),
    unsigned=false,
    file_offset=256,
    column_index=0,
  )
  assert_true(decoded.value is Signed(0))
  assert_eq(decoded.bytes_read, 8)
}
