// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn temporal_test_table() -> @moonbinlog.TableMap raise {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  @moonbinlog.TableMap::parse(format, tm_temporal, file_offset=126)
}

///|
fn temporal_summary(value : @moonbinlog.TemporalValue) -> String {
  match value {
    Year(year) => "year:\{year}"
    Date(year~, month~, day~) => "date:\{year},\{month},\{day}"
    DateTime(year~, month~, day~, hour~, minute~, second~, microsecond~) =>
      "datetime:\{year},\{month},\{day},\{hour},\{minute},\{second},\{microsecond}"
    Time(negative~, hour~, minute~, second~, microsecond~) => {
      let sign = if negative { 1 } else { 0 }
      "time:\{sign},\{hour},\{minute},\{second},\{microsecond}"
    }
    Timestamp(seconds~, microsecond~) => "timestamp:\{seconds},\{microsecond}"
  }
}

///|
fn temporal_decode_error(
  column : @moonbinlog.TableColumn,
  data : BytesView,
) -> @moonbinlog.DecodeError raise {
  try
    column.decode_temporal(data, file_offset=0x100000123, column_index=7)
  catch {
    err => err
  } noraise {
    _ => fail("invalid temporal value was accepted")
  }
}

///|
test "temporal fields agree with independently constructed Python component vectors" {
  let table = temporal_test_table()
  for (index, bytes, expected) in temporal_vectors {
    let decoded = table.columns[index].decode_temporal(
      bytes,
      file_offset=256,
      column_index=index,
    )
    assert_eq(temporal_summary(decoded.value), expected)
    assert_eq(decoded.bytes_read, bytes.length())
    assert_eq(
      decoded.fractional_precision,
      if index < 2 {
        0
      } else {
        (index - 2) % 7
      },
    )
  }
}

///|
test "every temporal truncation point reports full size and physical location" {
  let table = temporal_test_table()
  for (index, bytes, _) in temporal_vectors {
    for available in 0..<bytes.length() {
      match temporal_decode_error(table.columns[index], bytes[:available]) {
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
test "damaged date time and fractional components are rejected" {
  let table = temporal_test_table()
  for (index, bytes) in temporal_invalid {
    match temporal_decode_error(table.columns[index], bytes) {
      InvalidTemporalValue(file_offset~, column_index~, ..) => {
        assert_eq(file_offset, 0x100000123UL)
        assert_eq(column_index, 7)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "fractional metadata rejects precision seven and high byte before reading data" {
  let table = temporal_test_table()
  for index in [23, 24, 25] {
    match temporal_decode_error(table.columns[index], b"") {
      InvalidTemporalMetadata(file_offset~, column_index~, ..) => {
        assert_eq(file_offset, 0x100000123UL)
        assert_eq(column_index, 7)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "negative TIME2 fractions use borrow across the seconds boundary" {
  let table = temporal_test_table()
  for
    (bytes, expected) in [
      (b"\x7f\xff\xff\xff", "time:1,0,0,0,10000"),
      (b"\x7f\xff\xff\x9d", "time:1,0,0,0,990000"),
      (b"\x7f\xff\xff\x00", "time:1,0,0,1,0"),
      (b"\x7f\xff\xfe\xff", "time:1,0,0,1,10000"),
    ] {
    let decoded = table.columns[18].decode_temporal(
      bytes,
      file_offset=256,
      column_index=18,
    )
    assert_eq(temporal_summary(decoded.value), expected)
  }
  let micro = table.columns[22].decode_temporal(
    b"\x7f\xff\xff\xff\xff\xff",
    file_offset=256,
    column_index=22,
  )
  assert_eq(temporal_summary(micro.value), "time:1,0,0,0,1")
}

///|
test "temporal zero values are preserved rather than interpreted as NULL" {
  let table = temporal_test_table()
  for
    (index, bytes, expected) in [
      (0, b"\x00\x00\x00", "date:0,0,0"),
      (1, b"\x00", "year:0"),
      (2, b"\x00\x00\x00\x00", "timestamp:0,0"),
      (9, b"\x80\x00\x00\x00\x00", "datetime:0,0,0,0,0,0,0"),
      (16, b"\x80\x00\x00", "time:0,0,0,0,0"),
    ] {
    assert_true(table.columns[index].nullable)
    let decoded = table.columns[index].decode_temporal(
      bytes,
      file_offset=256,
      column_index=index,
    )
    assert_eq(temporal_summary(decoded.value), expected)
    assert_eq(decoded.bytes_read, bytes.length())
  }
}

///|
test "YEAR maps the entire one-byte range without applying two-digit year heuristics" {
  let column = temporal_test_table().columns[1]
  for raw in 0..<256 {
    let decoded = column.decode_temporal(
      Bytes::from_array([raw.to_byte()]),
      file_offset=256,
      column_index=1,
    )
    assert_true(
      decoded.value is Year(year) &&
      year == (if raw == 0 { 0 } else { 1900 + raw }),
    )
    assert_eq(decoded.bytes_read, 1)
  }
}

///|
test "timestamp seconds retain high bits and are not converted to local calendar time" {
  let column = temporal_test_table().columns[2]
  for
    (bytes, expected) in [
      (b"\x00\x00\x00\x01", 1U),
      (b"\x80\x00\x00\x00", 2147483648U),
      (b"\xff\xff\xff\xff", 4294967295U),
    ] {
    let decoded = column.decode_temporal(bytes, file_offset=256, column_index=2)
    assert_true(
      decoded.value is Timestamp(seconds~, microsecond=0) && seconds == expected,
    )
  }
}

///|
test "time duration supports hours beyond twenty-three with exact maximum endpoints" {
  let table = temporal_test_table()
  for
    (bytes, expected) in [
      (b"\xb4\x6e\xfb", "time:0,838,59,59,0"),
      (b"\x4b\x91\x05", "time:1,838,59,59,0"),
      (b"\x81\x80\x00", "time:0,24,0,0,0"),
    ] {
    let decoded = table.columns[16].decode_temporal(
      bytes,
      file_offset=256,
      column_index=16,
    )
    assert_eq(temporal_summary(decoded.value), expected)
  }
}

///|
test "legacy temporal formats and non-temporal columns fail explicitly" {
  let table = temporal_test_table()
  let other = integer_test_table()
  for
    column in [
      table.columns[26],
      table.columns[27],
      table.columns[28],
      other.columns[0],
      other.columns[1],
      other.columns[2],
      other.columns[4],
    ] {
    match temporal_decode_error(column, b"\x00\x00\x00\x00\x00\x00\x00\x00") {
      UnsupportedTemporalColumn(file_offset~, column_index~, wire_type~) => {
        assert_eq(file_offset, 0x100000123UL)
        assert_eq(column_index, 7)
        assert_eq(wire_type, column.wire_type)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "all temporal fields consume only their own nested view before a following integer" {
  let table = temporal_test_table()
  let tiny = integer_test_table().columns[6]
  for (index, bytes, expected) in temporal_vectors {
    let storage = b"guard" + bytes + b"\xffsuffix"
    let view = storage[5:5 + bytes.length() + 1]
    let first = table.columns[index].decode_temporal(
      view,
      file_offset=256,
      column_index=index,
    )
    let second = tiny.decode_integer(
      view[first.bytes_read:],
      unsigned=false,
      file_offset=256 + first.bytes_read.reinterpret_as_uint().to_uint64(),
      column_index=6,
    )
    assert_eq(temporal_summary(first.value), expected)
    assert_true(second.value is Signed(-1))
    assert_eq(first.bytes_read + second.bytes_read, view.length())
  }
}
