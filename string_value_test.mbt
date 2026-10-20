// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn string_test_table() -> @moonbinlog.TableMap raise {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  @moonbinlog.TableMap::parse(format, tm_strings, file_offset=126)
}

///|
fn string_decode_error(
  column : @moonbinlog.TableColumn,
  data : BytesView,
) -> @moonbinlog.DecodeError raise {
  try
    column.decode_string(data, file_offset=0x100000123, column_index=7)
  catch {
    err => err
  } noraise {
    _ => fail("invalid string was accepted")
  }
}

///|
test "all string maxima choose prefix width from metadata and preserve exact bytes" {
  let table = string_test_table()
  let maxima = [
    0, 1, 255, 256, 600, 65535, 0, 1, 255, 256, 511, 512, 767, 768, 1023,
  ]
  for index, maximum in maxima {
    let prefix_width = if maximum > 255 { 2 } else { 1 }
    for length in [0, 1, 254, 255, 256, maximum] {
      if length > maximum {
        continue
      }
      let prefix = if prefix_width == 1 {
        Bytes::from_array([length.to_byte()])
      } else {
        Bytes::from_array([(length & 255).to_byte(), (length >> 8).to_byte()])
      }
      let expected = Bytes::makei(length, i => (i % 256).to_byte())
      let input = prefix + expected + b"next field"
      let decoded = table.columns[index].decode_string(
        input,
        file_offset=256,
        column_index=index,
      )
      assert_eq(decoded.value, expected)
      assert_eq(decoded.bytes_read, length + prefix_width)
    }
  }
}

///|
test "varchar metadata is little endian while STRING embeds high length bits in its type" {
  let table = string_test_table()
  assert_eq(table.columns[4].metadata, (b"\x58\x02" : Bytes))
  assert_eq(table.columns[9].metadata, (b"\xee\x00" : Bytes))
  assert_eq(table.columns[11].metadata, (b"\xde\x00" : Bytes))
  assert_eq(table.columns[13].metadata, (b"\xce\x00" : Bytes))
  for index in [4, 9, 11, 13] {
    let decoded = table.columns[index].decode_string(
      b"\x01\x00Z",
      file_offset=256,
      column_index=index,
    )
    assert_eq(decoded.value, b"Z")
    assert_eq(decoded.bytes_read, 3)
  }
}

///|
test "empty strings are present values even for nullable and zero-width columns" {
  let table = string_test_table()
  for index in [0, 1, 3, 6, 7, 9] {
    let column = table.columns[index]
    assert_true(column.nullable)
    let decoded = column.decode_string(
      b"\x00\x00",
      file_offset=256,
      column_index=index,
    )
    assert_eq(decoded.value, b"")
    assert_eq(decoded.bytes_read, if index == 3 || index == 9 { 2 } else { 1 })
  }
}

///|
test "UTF8 Chinese binary NUL invalid UTF8 BOM and trailing spaces remain verbatim" {
  let column = string_test_table().columns[2]
  for
    bytes in [
      b"\xe4\xb8\xad\xe6\x96\x87", b"\x00\xff\xc0\x80", b"\xef\xbb\xbfhello", b"x  ",
    ] {
    let input = Bytes::from_array([bytes.length().to_byte()]) + bytes
    let decoded = column.decode_string(input, file_offset=256, column_index=2)
    assert_eq(decoded.value, bytes)
    assert_eq(decoded.bytes_read, bytes.length() + 1)
  }
}

///|
test "STRING does not invent padding removed by the producer" {
  let column = string_test_table().columns[8]
  let decoded = column.decode_string(b"\x01x", file_offset=256, column_index=8)
  assert_eq(decoded.value, b"x")
  assert_eq(decoded.bytes_read, 2)
}

///|
test "every short prefix and payload reports total required field length" {
  let table = string_test_table()
  for
    (index, input, prefix) in [
      (2, b"\x03abc", 1),
      (3, b"\x03\x00abc", 2),
      (9, b"\x03\x00abc", 2),
    ] {
    for available in 0..<input.length() {
      match string_decode_error(table.columns[index], input[:available]) {
        TruncatedColumnValue(file_offset~, column_index~, expected~, actual~) => {
          assert_eq(file_offset, 0x100000123UL)
          assert_eq(column_index, 7)
          assert_eq(actual, available)
          assert_eq(
            expected,
            if available < prefix {
              prefix
            } else {
              input.length()
            },
          )
        }
        other => fail("unexpected error: \{Repr(other)}")
      }
    }
  }
}

///|
test "declared lengths beyond schema maximum fail even with sufficient payload" {
  let table = string_test_table()
  for
    (index, maximum) in [
      (0, 0),
      (1, 1),
      (3, 256),
      (4, 600),
      (6, 0),
      (9, 256),
      (14, 1023),
    ] {
    let length = maximum + 1
    let prefix = if maximum <= 255 {
      Bytes::from_array([length.to_byte()])
    } else {
      Bytes::from_array([(length & 255).to_byte(), (length >> 8).to_byte()])
    }
    for input in [prefix, prefix + Bytes::make(length, 0)] {
      match string_decode_error(table.columns[index], input) {
        StringLengthExceeded(
          file_offset~,
          column_index~,
          length=actual,
          max_length~
        ) => {
          assert_eq(file_offset, 0x100000123UL)
          assert_eq(column_index, 7)
          assert_eq(actual, length)
          assert_eq(max_length, maximum)
        }
        other => fail("unexpected error: \{Repr(other)}")
      }
    }
  }
}

///|
test "STRING embedded ENUM SET and invalid type are not length-prefixed strings" {
  let table = string_test_table()
  for index in [15, 16, 17] {
    match
      string_decode_error(table.columns[index], b"\x00\x00arbitrary bytes") {
      InvalidStringMetadata(file_offset~, column_index~, ..) => {
        assert_eq(file_offset, 0x100000123UL)
        assert_eq(column_index, 7)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "non-string types are explicitly rejected" {
  let table = integer_test_table()
  for index in [0, 2, 3, 4, 5, 6, 7, 8, 9] {
    match string_decode_error(table.columns[index], b"\x00\x00") {
      UnsupportedStringColumn(file_offset~, column_index~, wire_type~) => {
        assert_eq(file_offset, 0x100000123UL)
        assert_eq(column_index, 7)
        assert_eq(wire_type, table.columns[index].wire_type)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "adjacent mixed string and integer fields consume only their own bytes" {
  let table = string_test_table()
  let storage = b"guard\x03abc\x01\x00Z\xffsuffix"
  let view = storage[5:13]
  let first = table.columns[2].decode_string(
    view,
    file_offset=256,
    column_index=2,
  )
  let second = table.columns[3].decode_string(
    view[first.bytes_read:],
    file_offset=260,
    column_index=3,
  )
  let cursor = first.bytes_read + second.bytes_read
  let third = integer_test_table().columns[6].decode_integer(
    view[cursor:],
    unsigned=false,
    file_offset=263,
    column_index=6,
  )
  assert_eq(first.value, b"abc")
  assert_eq(second.value, b"Z")
  assert_true(third.value is Signed(-1))
  assert_eq(cursor + third.bytes_read, view.length())
}
