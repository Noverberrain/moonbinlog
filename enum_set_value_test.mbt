// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn enum_set_test_table() -> @moonbinlog.TableMap raise {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  @moonbinlog.TableMap::parse(format, tm_enum_set, file_offset=126)
}

///|
fn enum_set_decode_error(
  column : @moonbinlog.TableColumn,
  data : BytesView,
) -> @moonbinlog.DecodeError raise {
  try
    column.decode_enum_set(data, file_offset=0x100000123, column_index=7)
  catch {
    err => err
  } noraise {
    _ => fail("invalid ENUM/SET was accepted")
  }
}

///|
test "ENUM and SET agree with independent Python vectors across every supported width" {
  let table = enum_set_test_table()
  for (index, bytes, tag, expected) in enum_set_vectors {
    let decoded = table.columns[index].decode_enum_set(
      bytes,
      file_offset=256,
      column_index=index,
    )
    match decoded.value {
      EnumIndex(value) => {
        assert_eq(tag, 247)
        assert_eq(value.to_uint().to_uint64(), expected)
      }
      SetMask(value) => {
        assert_eq(tag, 248)
        assert_eq(value, expected)
      }
    }
    assert_eq(decoded.bytes_read, bytes.length())
  }
}

///|
test "one-byte ENUM exhaustively preserves all ordinals including zero" {
  let column = enum_set_test_table().columns[0]
  assert_true(column.nullable)
  for raw in 0..<256 {
    let decoded = column.decode_enum_set(
      Bytes::from_array([raw.to_byte()]),
      file_offset=256,
      column_index=0,
    )
    assert_true(
      decoded.value is EnumIndex(value) &&
      value.to_uint() == raw.reinterpret_as_uint(),
    )
    assert_eq(decoded.bytes_read, 1)
  }
}

///|
test "two-byte ENUM is little endian and retains the maximum ordinal" {
  let column = enum_set_test_table().columns[1]
  for
    (bytes, expected) in [
      (b"\x00\x01", 256U),
      (b"\x34\x12", 4660U),
      (b"\xff\xff", 65535U),
    ] {
    let decoded = column.decode_enum_set(bytes, file_offset=256, column_index=1)
    assert_true(
      decoded.value is EnumIndex(value) && value.to_uint() == expected,
    )
    assert_eq(decoded.bytes_read, 2)
  }
}

///|
test "SET masks preserve the member bit order and complete UInt64 range" {
  let table = enum_set_test_table()
  let mixed = table.columns[3].decode_enum_set(
    b"\x05\x01",
    file_offset=256,
    column_index=3,
  )
  assert_true(mixed.value is SetMask(261))
  let high = table.columns[6].decode_enum_set(
    b"\x00\x00\x00\x00\x00\x00\x00\x80",
    file_offset=256,
    column_index=6,
  )
  assert_true(high.value is SetMask(0x8000000000000000))
  let maximum = table.columns[6].decode_enum_set(
    b"\xff\xff\xff\xff\xff\xff\xff\xff",
    file_offset=256,
    column_index=6,
  )
  match maximum.value {
    SetMask(value) => assert_eq(value.to_string(), "18446744073709551615")
    _ => fail("SET lost its type")
  }
}

///|
test "empty nullable SET and ENUM error ordinal are values rather than NULL" {
  let table = enum_set_test_table()
  for index in 0..<7 {
    let column = table.columns[index]
    assert_true(column.nullable)
    let bytes = Bytes::make(column.metadata[1].to_int(), 0)
    let decoded = column.decode_enum_set(
      bytes,
      file_offset=256,
      column_index=index,
    )
    assert_true(decoded.value is EnumIndex(0) || decoded.value is SetMask(0))
    assert_eq(decoded.bytes_read, bytes.length())
  }
}

///|
test "every ENUM SET truncated prefix preserves total length and field diagnostics" {
  let table = enum_set_test_table()
  for (index, bytes, _, _) in enum_set_vectors {
    for available in 0..<bytes.length() {
      match enum_set_decode_error(table.columns[index], bytes[:available]) {
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
test "invalid embedded types ENUM widths and noncanonical SET widths are rejected" {
  let table = enum_set_test_table()
  for index in 7..<20 {
    match enum_set_decode_error(table.columns[index], b"") {
      InvalidEnumSetMetadata(file_offset~, column_index~, ..) => {
        assert_eq(file_offset, 0x100000123UL)
        assert_eq(column_index, 7)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "standalone ENUM SET type codes and other field families are not guessed" {
  let table = enum_set_test_table()
  let other = integer_test_table()
  for
    column in [
      table.columns[20],
      table.columns[21],
      other.columns[0],
      other.columns[1],
      other.columns[2],
      other.columns[3],
      other.columns[4],
    ] {
    match enum_set_decode_error(column, b"\x00\x00\x00\x00\x00\x00\x00\x00") {
      UnsupportedEnumSetColumn(file_offset~, column_index~, wire_type~) => {
        assert_eq(file_offset, 0x100000123UL)
        assert_eq(column_index, 7)
        assert_eq(wire_type, column.wire_type)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "ENUM SET stay distinct from length-prefixed STRING decoding" {
  let table = enum_set_test_table()
  for index in 0..<7 {
    try
      table.columns[index].decode_string(
        b"\x00\x00\x00\x00\x00\x00\x00\x00",
        file_offset=256,
        column_index=index,
      )
    catch {
      InvalidStringMetadata(..) => ()
      other => fail("unexpected error: \{Repr(other)}")
    } noraise {
      _ => fail("ENUM/SET was treated as a string")
    }
  }
  assert_true(
    enum_set_decode_error(string_test_table().columns[8], b"\x01x")
    is InvalidEnumSetMetadata(..),
  )
}

///|
test "nested slices with consecutive ENUM SET integer fields consume exact widths" {
  let table = enum_set_test_table()
  let storage = b"guard\x34\x12\x05\x01\xffsuffix"
  let view = storage[5:10]
  let first = table.columns[1].decode_enum_set(
    view,
    file_offset=256,
    column_index=1,
  )
  let second = table.columns[3].decode_enum_set(
    view[first.bytes_read:],
    file_offset=258,
    column_index=3,
  )
  let cursor = first.bytes_read + second.bytes_read
  let third = integer_test_table().columns[6].decode_integer(
    view[cursor:],
    unsigned=false,
    file_offset=260,
    column_index=6,
  )
  assert_true(first.value is EnumIndex(4660))
  assert_true(second.value is SetMask(261))
  assert_true(third.value is Signed(-1))
  assert_eq(cursor + third.bytes_read, view.length())
}
