// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn row_image_table() -> @moonbinlog.TableMap raise {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  @moonbinlog.TableMap::parse(format, tm_row_image, file_offset=126)
}

///|
fn row_image_signs() -> ReadOnlyArray[Bool?] {
  ReadOnlyArray::from_array(
    Array::makei(17, i => {
      if i == 0 {
        Some(true)
      } else if i >= 5 && i <= 8 {
        Some(false)
      } else {
        None
      }
    }),
  )
}

///|
fn row_image_error(
  data : BytesView,
  present : BytesView,
  signs~ : ReadOnlyArray[Bool?] = row_image_signs(),
  max_bytes~ : Int32 = 16_777_216,
  file_offset~ : UInt64 = 0x100000100,
) -> @moonbinlog.DecodeError raise {
  let table = row_image_table()
  try
    table.decode_row_image(
      data,
      columns_present=present,
      integer_unsigned=signs,
      file_offset~,
      max_bytes~,
    )
  catch {
    err => err
  } noraise {
    _ => fail("invalid row image was accepted")
  }
}

///|
test "row image present NULL and value states match independent compact Python bitmaps" {
  let table = row_image_table()
  for (present, data, expected) in row_image_cases {
    let row = table.decode_row_image(
      data,
      columns_present=present,
      integer_unsigned=row_image_signs(),
      file_offset=256,
    )
    let states = StringBuilder()
    for cell in row.columns {
      states.write_char(
        match cell {
          Absent => '-'
          Null => 'N'
          _ => 'V'
        },
      )
    }
    assert_eq(states.to_string(), expected)
    assert_eq(row.bytes_read, data.length())
    assert_eq(row.columns.length(), 17)
  }
}

///|
test "full row composes every supported value family without losing scalar precision" {
  let row = row_image_table().decode_row_image(
    row_full,
    columns_present=row_full_present,
    integer_unsigned=row_image_signs(),
    file_offset=256,
  )
  assert_true(row.columns[0] is Integer(Unsigned(0xffffffffffffffff)))
  assert_true(
    row.columns[1] is StringBytes(bytes) && bytes == b"\xe4\xb8\xad\xe6\x96\x87",
  )
  assert_true(
    row.columns[2] is Decimal(value) &&
    value.value == "12345.67" &&
    value.scale == 2,
  )
  assert_true(
    row.columns[3] is Temporal(value) &&
    value.value
    is DateTime(
      year=2026,
      month=10,
      day=22,
      hour=12,
      minute=34,
      second=56,
      microsecond=123456
    ),
  )
  assert_true(row.columns[4] is BlobBytes(bytes) && bytes == b"A\x00B")
  assert_true(row.columns[5] is Integer(Signed(-2147483648)))
  assert_true(row.columns[6] is Integer(Signed(-1)))
  assert_true(row.columns[7] is Integer(Signed(-32768)))
  assert_true(row.columns[8] is Integer(Signed(8388607)))
  assert_true(
    row.columns[9] is Temporal(value) &&
    value.value is Date(year=2026, month=10, day=22),
  )
  assert_true(
    row.columns[10] is Floating(value) &&
    value.value is Single(number) &&
    number.to_double() == 1.5,
  )
  assert_true(
    row.columns[11] is Floating(value) && value.value is DoublePrecision(-2.5),
  )
  assert_true(
    row.columns[12] is Bit(value) && value.value == 258 && value.bit_length == 9,
  )
  assert_true(row.columns[13] is StringBytes(bytes) && bytes == b"hi")
  assert_true(row.columns[14] is EnumSet(EnumIndex(256)))
  assert_true(row.columns[15] is EnumSet(SetMask(0x8000000000000005)))
  assert_true(row.columns[16] is Absent)
}

///|
test "sparse row NULL bits index included ordinals rather than table column numbers" {
  let row = row_image_table().decode_row_image(
    row_sparse,
    columns_present=row_sparse_present,
    integer_unsigned=row_image_signs(),
    file_offset=256,
  )
  assert_eq(row_sparse[0], (0x19 : Byte))
  assert_true(row.columns[0] is Absent)
  assert_true(row.columns[1] is Null)
  assert_true(row.columns[5] is Integer(Signed(-2147483648)))
  assert_true(row.columns[8] is Integer(Signed(8388607)))
  assert_true(row.columns[14] is Null)
  assert_true(row.columns[16] is Null)
}

///|
test "cross-byte compact NULL bitmaps do not skip the NOT NULL column's ordinal" {
  let row = row_image_table().decode_row_image(
    row_crossing,
    columns_present=row_crossing_present,
    integer_unsigned=row_image_signs(),
    file_offset=256,
  )
  assert_eq(row_crossing[0], (0x83 : Byte))
  assert_eq(row_crossing[1], (0x91 : Byte))
  for index in [0, 1, 7, 8, 12, 15] {
    assert_true(row.columns[index] is Null)
  }
  assert_true(row.columns[5] is Integer(Signed(-2147483648)))
  assert_true(row.columns[6] is Integer(Signed(-1)))
}

///|
test "zero empty string empty blob and SQL NULL stay distinct from absent columns" {
  let row = row_image_table().decode_row_image(
    row_zero,
    columns_present=row_zero_present,
    integer_unsigned=row_image_signs(),
    file_offset=256,
  )
  assert_true(row.columns[0] is Integer(Unsigned(0)))
  assert_true(row.columns[1] is StringBytes(bytes) && bytes.is_empty())
  assert_true(row.columns[2] is Decimal(value) && value.value == "0.00")
  assert_true(row.columns[3] is Absent)
  assert_true(row.columns[4] is BlobBytes(bytes) && bytes.is_empty())
  assert_true(row.columns[6] is Integer(Signed(0)))
  assert_true(row.columns[12] is Bit(value) && value.value == 0)
  assert_true(row.columns[16] is Null)
}

///|
test "all NULL values including unsupported families need no signedness or payload bytes" {
  let row = row_image_table().decode_row_image(
    row_nulls,
    columns_present=row_nulls_present,
    integer_unsigned=ReadOnlyArray::from_array(Array::make(17, None)),
    file_offset=256,
  )
  assert_eq(row.bytes_read, 1)
  for index in [0, 1, 4, 12, 16] {
    assert_true(row.columns[index] is Null)
  }
}

///|
test "empty presence yields zero progress even with a zero byte budget" {
  let row = row_image_table().decode_row_image(
    row_empty,
    columns_present=row_empty_present,
    integer_unsigned=ReadOnlyArray::from_array(Array::make(17, None)),
    file_offset=256,
    max_bytes=0,
  )
  assert_eq(row.bytes_read, 0)
  assert_true(row.columns.all(cell => cell is Absent))
}

///|
test "integer signedness is mandatory only for present non-NULL integer values" {
  match
    row_image_error(
      row_full,
      row_full_present,
      signs=ReadOnlyArray::from_array(Array::make(17, None)),
    ) {
    MissingIntegerSignedness(file_offset~, column_index~) => {
      assert_eq(file_offset, 0x100000102UL)
      assert_eq(column_index, 0)
    }
    other => fail("unexpected error: \{Repr(other)}")
  }
  let signs = Array::makei(17, i => {
    if i == 0 {
      Some(false)
    } else {
      row_image_signs()[i]
    }
  })
  let row = row_image_table().decode_row_image(
    row_full,
    columns_present=row_full_present,
    integer_unsigned=ReadOnlyArray::from_array(signs),
    file_offset=256,
  )
  assert_true(row.columns[0] is Integer(Signed(-1)))
  let missing = ReadOnlyArray::from_array(
    Array::makei(17, i => if i == 8 { None } else { row_image_signs()[i] }),
  )
  match row_image_error(row_sparse, row_sparse_present, signs=missing) {
    MissingIntegerSignedness(file_offset~, column_index~) => {
      assert_eq(file_offset, 0x100000105UL)
      assert_eq(column_index, 8)
    }
    other => fail("unexpected error: \{Repr(other)}")
  }
}

///|
test "NULL on a NOT NULL column reports its table index and bitmap byte location" {
  match row_image_error(b"\x01", b"\x20\x00\x00") {
    UnexpectedRowNull(file_offset~, column_index~) => {
      assert_eq(file_offset, 0x100000100UL)
      assert_eq(column_index, 5)
    }
    other => fail("unexpected error: \{Repr(other)}")
  }
}

///|
test "present non-NULL unsupported JSON fails without guessing a field length" {
  match row_image_error(b"\x00", b"\x00\x00\x01") {
    UnsupportedRowColumn(file_offset~, column_index~, wire_type~) => {
      assert_eq(file_offset, 0x100000101UL)
      assert_eq(column_index, 16)
      assert_eq(wire_type, (245 : Byte))
    }
    other => fail("unexpected error: \{Repr(other)}")
  }
}

///|
test "row image requires the entire compact NULL bitmap before reading values" {
  for length in 0..<2 {
    match row_image_error(row_full[:length], row_full_present) {
      TruncatedInput(file_offset~, expected~, actual~) => {
        assert_eq(file_offset, 0x100000100UL)
        assert_eq(expected, 2)
        assert_eq(actual, length)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "all mixed-row value truncation points remain structured scalar errors" {
  for length in 2..<row_full.length() {
    match row_image_error(row_full[:length], row_full_present) {
      TruncatedColumnValue(file_offset~, column_index~, expected~, actual~) => {
        assert_true(file_offset >= 0x100000102UL)
        assert_true(column_index >= 0 && column_index < 16)
        assert_true(expected > actual)
        assert_true(actual >= 0)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "presence and signedness vectors must match the table width exactly" {
  for present in [b"", b"\xff\xff", b"\xff\xff\x00\x00"] {
    assert_true(row_image_error(row_full, present) is InvalidRowImage(..))
  }
  for length in [0, 16, 18] {
    assert_true(
      row_image_error(
        row_full,
        row_full_present,
        signs=ReadOnlyArray::from_array(Array::make(length, None)),
      )
      is InvalidRowImage(..),
    )
  }
}

///|
test "row byte budgets include NULL bytes and bound scalar inputs before copying" {
  let table = row_image_table()
  let exact = table.decode_row_image(
    row_full,
    columns_present=row_full_present,
    integer_unsigned=row_image_signs(),
    file_offset=256,
    max_bytes=row_full.length(),
  )
  assert_eq(exact.bytes_read, row_full.length())
  for limit in 0..<row_full.length() {
    match row_image_error(row_full, row_full_present, max_bytes=limit) {
      RowImageLimitExceeded(file_offset~, max_bytes~) => {
        assert_eq(file_offset, 0x100000100UL)
        assert_eq(max_bytes, limit)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "invalid row budgets and overflowing physical offset ranges fail explicitly" {
  for limit in [-1, 2147483644, 2147483647] {
    assert_true(
      row_image_error(row_full, row_full_present, max_bytes=limit)
      is InvalidRowImageLimit(..),
    )
  }
  assert_true(
    row_image_error(row_full, row_full_present, file_offset=0xffffffffffffffff)
    is InvalidRowImage(..),
  )
  assert_true(
    row_image_error(b"\x00\x01\x00\x00\x01", b"\x10\x00\x00")
    is BlobTooLarge(..),
  )
}

///|
test "padding in presence and compact NULL bitmaps does not add columns" {
  let table = row_image_table()
  let full = table.decode_row_image(
    row_full,
    columns_present=b"\xff\xff\xfe",
    integer_unsigned=row_image_signs(),
    file_offset=256,
  )
  let regular = table.decode_row_image(
    row_full,
    columns_present=row_full_present,
    integer_unsigned=row_image_signs(),
    file_offset=256,
  )
  assert_eq(full, regular)
  let nulls = table.decode_row_image(
    b"\xff",
    columns_present=row_nulls_present,
    integer_unsigned=row_image_signs(),
    file_offset=256,
  )
  let normal_nulls = table.decode_row_image(
    row_nulls,
    columns_present=row_nulls_present,
    integer_unsigned=row_image_signs(),
    file_offset=256,
  )
  assert_eq(nulls, normal_nulls)
}

///|
test "nested views and adjacent row images leave the next image and sentinel untouched" {
  let storage = b"guard" + row_full + row_sparse + b"sentinel"
  let view = storage[5:]
  let table = row_image_table()
  let first = table.decode_row_image(
    view,
    columns_present=row_full_present,
    integer_unsigned=row_image_signs(),
    file_offset=256,
  )
  let second = table.decode_row_image(
    view[first.bytes_read:],
    columns_present=row_sparse_present,
    integer_unsigned=row_image_signs(),
    file_offset=256 + first.bytes_read.reinterpret_as_uint().to_uint64(),
  )
  assert_eq(first.bytes_read, row_full.length())
  assert_eq(second.bytes_read, row_sparse.length())
  assert_true(second.columns[1] is Null)
  assert_eq(view[first.bytes_read + second.bytes_read:].to_owned(), b"sentinel")
}
