// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn blob_test_table() -> @moonbinlog.TableMap raise {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  @moonbinlog.TableMap::parse(format, tm_blobs, file_offset=126)
}

///|
fn blob_decode_error(
  column : @moonbinlog.TableColumn,
  data : BytesView,
  max_value_bytes~ : Int32 = 16_777_216,
) -> @moonbinlog.DecodeError raise {
  try
    column.decode_blob(
      data,
      file_offset=0x100000123,
      column_index=7,
      max_value_bytes~,
    )
  catch {
    err => err
  } noraise {
    _ => fail("invalid blob was accepted")
  }
}

///|
test "four BLOB length widths agree with independent Python wire fixtures" {
  let table = blob_test_table()
  let expected : Bytes = b"\x00\xff\xe4\xb8\xad\xe6\x96\x87  "
  for index, bytes in [blob_value_1, blob_value_2, blob_value_3, blob_value_4] {
    let decoded = table.columns[index].decode_blob(
      bytes,
      file_offset=256,
      column_index=index,
    )
    assert_eq(decoded.value, expected)
    assert_eq(decoded.bytes_read, bytes.length())
  }
}

///|
test "empty nullable BLOB values consume the entire prefix and are not NULL" {
  let table = blob_test_table()
  for index in 0..<4 {
    assert_true(table.columns[index].nullable)
    let decoded = table.columns[index].decode_blob(
      Bytes::make(index + 1, 0),
      file_offset=256,
      column_index=index,
      max_value_bytes=0,
    )
    assert_eq(decoded.value, b"")
    assert_eq(decoded.bytes_read, index + 1)
  }
}

///|
test "every truncated prefix and payload preserves field and column diagnostics" {
  let table = blob_test_table()
  for index, bytes in [blob_value_1, blob_value_2, blob_value_3, blob_value_4] {
    for available in 0..<bytes.length() {
      match blob_decode_error(table.columns[index], bytes[:available]) {
        TruncatedColumnValue(file_offset~, column_index~, expected~, actual~) => {
          assert_eq(file_offset, 0x100000123UL)
          assert_eq(column_index, 7)
          assert_eq(actual, available)
          assert_eq(
            expected,
            if available < index + 1 {
              index + 1
            } else {
              bytes.length()
            },
          )
        }
        other => fail("unexpected error: \{Repr(other)}")
      }
    }
  }
}

///|
test "metadata rejects zero oversized and high-bit prefix widths" {
  let table = blob_test_table()
  for index in [4, 5, 6] {
    match blob_decode_error(table.columns[index], b"") {
      InvalidBlobMetadata(file_offset~, column_index~, ..) => {
        assert_eq(file_offset, 0x100000123UL)
        assert_eq(column_index, 7)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "BLOB limit accepts its boundary and rejects larger values before allocation" {
  let column = blob_test_table().columns[3]
  let decoded = column.decode_blob(
    blob_value_4,
    file_offset=256,
    column_index=3,
    max_value_bytes=10,
  )
  assert_eq(decoded.value.length(), 10)
  for bytes in [blob_value_4, b"\x0a\x00\x00\x00"] {
    match blob_decode_error(column, bytes, max_value_bytes=9) {
      BlobTooLarge(file_offset~, column_index~, length~, max_value_bytes~) => {
        assert_eq(file_offset, 0x100000123UL)
        assert_eq(column_index, 7)
        assert_eq(length, 10UL)
        assert_eq(max_value_bytes, 9)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
  assert_true(
    blob_decode_error(column, b"\x01\x00\x00\x00X", max_value_bytes=0)
    is BlobTooLarge(..),
  )
}

///|
test "four-byte high lengths never wrap to negative indices or small values" {
  let column = blob_test_table().columns[3]
  for
    (bytes, expected) in [
      (b"\xff\xff\xff\x7f", 2147483647UL),
      (b"\x00\x00\x00\x80", 2147483648UL),
      (b"\xff\xff\xff\xff", 4294967295UL),
    ] {
    match blob_decode_error(column, bytes, max_value_bytes=2_147_483_643) {
      BlobTooLarge(length~, ..) => assert_eq(length, expected)
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
  match
    blob_decode_error(
      column,
      b"\xfb\xff\xff\x7f",
      max_value_bytes=2_147_483_643,
    ) {
    TruncatedColumnValue(expected~, actual~, ..) => {
      assert_eq(expected, 2_147_483_647)
      assert_eq(actual, 4)
    }
    other => fail("unexpected error: \{Repr(other)}")
  }
}

///|
test "default limit is sixteen MiB and can be explicitly increased" {
  let column = blob_test_table().columns[3]
  assert_true(
    blob_decode_error(column, b"\x00\x00\x00\x01")
    is TruncatedColumnValue(expected=16_777_220, ..),
  )
  assert_true(
    blob_decode_error(column, b"\x01\x00\x00\x01")
    is BlobTooLarge(length=16_777_217, ..),
  )
  assert_true(
    blob_decode_error(column, b"\x01\x00\x00\x01", max_value_bytes=16_777_217)
    is TruncatedColumnValue(expected=16_777_221, ..),
  )
}

///|
test "invalid size limit configuration fails explicitly" {
  let column = blob_test_table().columns[3]
  for limit in [-1, 2_147_483_644, 2_147_483_647] {
    match
      blob_decode_error(column, b"\x00\x00\x00\x00", max_value_bytes=limit) {
      InvalidBlobLimit(max_value_bytes~) => assert_eq(max_value_bytes, limit)
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "BLOB little-endian lengths cross the byte and short boundaries" {
  let table = blob_test_table()
  for
    (index, length) in [(0, 255), (1, 256), (1, 65535), (2, 65536), (3, 65536)] {
    let width = index + 1
    let prefix = Bytes::makei(width, i => ((length >> (8 * i)) & 255).to_byte())
    let expected = Bytes::makei(length, i => (i % 251).to_byte())
    let decoded = table.columns[index].decode_blob(
      prefix + expected + b"tail",
      file_offset=256,
      column_index=index,
    )
    assert_eq(decoded.value, expected)
    assert_eq(decoded.bytes_read, width + length)
  }
}

///|
test "nested views and adjacent BLOB string integer fields keep their own boundaries" {
  let storage = b"guard\x03\x00\x00\x00A\x00B\x01x\xffsuffix"
  let view = storage[5:15]
  let first = blob_test_table().columns[3].decode_blob(
    view,
    file_offset=256,
    column_index=3,
  )
  let second = string_test_table().columns[2].decode_string(
    view[first.bytes_read:],
    file_offset=263,
    column_index=2,
  )
  let cursor = first.bytes_read + second.bytes_read
  let third = integer_test_table().columns[6].decode_integer(
    view[cursor:],
    unsigned=false,
    file_offset=265,
    column_index=6,
  )
  assert_eq(first.value, b"A\x00B")
  assert_eq(second.value, b"x")
  assert_true(third.value is Signed(-1))
  assert_eq(cursor + third.bytes_read, view.length())
}

///|
test "other column types are not coerced to BLOB including JSON and geometry" {
  let table = integer_test_table()
  let blob_table = blob_test_table()
  let columns = [
    table.columns[0],
    table.columns[1],
    table.columns[2],
    table.columns[3],
    table.columns[5],
    table.columns[6],
    table.columns[7],
    table.columns[8],
    table.columns[9],
    blob_table.columns[7],
    blob_table.columns[8],
    blob_table.columns[9],
    blob_table.columns[10],
    blob_table.columns[11],
  ]
  for column in columns {
    match blob_decode_error(column, b"\x00\x00\x00\x00") {
      UnsupportedBlobColumn(file_offset~, column_index~, wire_type~) => {
        assert_eq(file_offset, 0x100000123UL)
        assert_eq(column_index, 7)
        assert_eq(wire_type, column.wire_type)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}
