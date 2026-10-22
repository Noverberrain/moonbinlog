// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn rows_context(
  off~ : Bool = false,
  old_header~ : Bool = false,
) -> @moonbinlog.TableMapContext raise {
  let format = @moonbinlog.FormatDescription::parse(
    if off {
      fde_off
    } else if old_header {
      fde_rows_old_header
    } else {
      fde_crc32
    },
    file_offset=4,
  )
  let context = @moonbinlog.TableMapContext::new(format)
  ignore(
    context.apply(
      if off {
        tm_row_image_off
      } else {
        tm_row_image
      },
      file_offset=126,
    ),
  )
  context
}

///|
fn rows_error(
  data : BytesView,
  max_rows~ : Int32 = 1024,
  max_row_bytes~ : Int32 = 16_777_216,
  max_event_size~ : UInt32 = 16_777_216,
  signs~ : ReadOnlyArray[Bool?] = row_image_signs(),
  file_offset~ : UInt64 = 0x100000100,
) -> @moonbinlog.DecodeError raise {
  let context = rows_context()
  try
    context.decode_rows(
      data,
      integer_unsigned=signs,
      file_offset~,
      max_rows~,
      max_row_bytes~,
      max_event_size~,
    )
  catch {
    err => {
      assert_eq(context.length(), 0)
      err
    }
  } noraise {
    _ => fail("invalid ROWS event was accepted")
  }
}

///|
test "WRITE_ROWS v2 resolves the table and decodes multiple complete inserted rows" {
  let context = rows_context()
  let event = context.decode_rows(
    rows_write_two,
    integer_unsigned=row_image_signs(),
    file_offset=500,
  )
  assert_eq(event.header.event_type, (30 : Byte))
  assert_eq(event.header.file_offset, 500UL)
  assert_eq(event.table.table_id, 0x010203040506UL)
  assert_eq(event.table.table, "orders")
  assert_eq(event.columns_before, None)
  assert_eq(event.columns_after, Some(row_full_present))
  assert_eq(event.changes.length(), 2)
  for change in event.changes {
    match change {
      Insert(row) => {
        assert_eq(row.bytes_read, row_full.length())
        assert_true(row.columns[0] is Integer(Unsigned(0xffffffffffffffff)))
        assert_true(
          row.columns[2] is Decimal(value) && value.value == "12345.67",
        )
        assert_true(row.columns[16] is Absent)
      }
      _ => fail("WRITE did not produce INSERT")
    }
  }
  assert_eq(context.length(), 1)
}

///|
test "DELETE_ROWS v2 decodes sparse deleted images with compact NULL state" {
  let event = rows_context().decode_rows(
    rows_delete_two,
    integer_unsigned=row_image_signs(),
    file_offset=500,
  )
  assert_eq(event.columns_before, Some(row_sparse_present))
  assert_eq(event.columns_after, None)
  assert_eq(event.changes.length(), 2)
  for change in event.changes {
    match change {
      Delete(row) => {
        assert_true(row.columns[1] is Null)
        assert_true(row.columns[5] is Integer(Signed(-2147483648)))
        assert_true(row.columns[16] is Null)
      }
      _ => fail("DELETE did not produce DELETE")
    }
  }
}

///|
test "UPDATE_ROWS v2 pairs two changes with distinct before and after bitmaps" {
  let event = rows_context().decode_rows(
    rows_update_two,
    integer_unsigned=row_image_signs(),
    file_offset=500,
  )
  assert_eq(event.columns_before, Some(row_full_present))
  assert_eq(event.columns_after, Some(row_sparse_present))
  assert_eq(event.changes.length(), 2)
  for change in event.changes {
    match change {
      Update(before~, after~) => {
        assert_true(before.columns[1] is StringBytes(_))
        assert_true(after.columns[1] is Null)
        assert_true(before.columns[0] is Integer(_))
        assert_true(after.columns[0] is Absent)
        assert_eq(before.bytes_read, row_full.length())
        assert_eq(after.bytes_read, row_sparse.length())
      }
      _ => fail("UPDATE did not produce a pair")
    }
  }
}

///|
test "statement end clears every cached map but returned table snapshots remain usable" {
  let context = rows_context()
  ignore(context.apply(tm_second_id, file_offset=300))
  assert_eq(context.length(), 2)
  let event = context.decode_rows(
    rows_write_end,
    integer_unsigned=row_image_signs(),
    file_offset=500,
  )
  assert_eq(event.flags, (1 : UInt16))
  assert_eq(context.length(), 0)
  let snapshot = event.table.decode_row_image(
    row_full,
    columns_present=row_full_present,
    integer_unsigned=row_image_signs(),
    file_offset=900,
  )
  assert_true(snapshot.columns[14] is EnumSet(EnumIndex(256)))
}

///|
test "common event flags are independent of ROWS statement-end flags" {
  let context = rows_context()
  let event = context.decode_rows(
    rows_header_end_only,
    integer_unsigned=row_image_signs(),
    file_offset=500,
  )
  assert_eq(event.header.flags, (1 : UInt16))
  assert_eq(event.flags, (0 : UInt16))
  assert_eq(context.length(), 1)
}

///|
test "bounded extra-header bytes are preserved without shifting the row payload" {
  let event = rows_context().decode_rows(
    rows_extra,
    integer_unsigned=row_image_signs(),
    file_offset=500,
  )
  assert_eq(event.extra_data, b"\x7fabc")
  assert_eq(event.changes.length(), 1)
  assert_true(
    event.changes[0] is Insert(row) && row.columns[6] is Integer(Signed(-1)),
  )
}

///|
test "OFF policy keeps row bytes and checksum framing is not assumed" {
  let context = rows_context(off=true)
  let event = context.decode_rows(
    rows_off,
    integer_unsigned=row_image_signs(),
    file_offset=500,
  )
  assert_eq(event.changes.length(), 1)
  assert_eq(event.header.event_size, rows_off.length().reinterpret_as_uint())
  assert_true(
    event.changes[0] is Insert(row) &&
    row.columns[15] is EnumSet(SetMask(0x8000000000000005)),
  )
}

///|
test "empty row payload can close a statement without inventing a row" {
  let context = rows_context()
  let event = context.decode_rows(
    rows_empty,
    integer_unsigned=row_image_signs(),
    file_offset=500,
  )
  assert_eq(event.changes.length(), 0)
  assert_eq(context.length(), 0)
}

///|
test "padding bits do not change the number of table columns or row values" {
  let event = rows_context().decode_rows(
    rows_padding,
    integer_unsigned=row_image_signs(),
    file_offset=500,
  )
  assert_eq(event.columns_after, Some((b"\xff\xff\xfe" : Bytes)))
  assert_true(event.changes[0] is Insert(row) && row.columns[16] is Absent)
}

///|
test "an UPDATE with an empty before image still progresses through its after image" {
  let event = rows_context().decode_rows(
    rows_empty_before,
    integer_unsigned=row_image_signs(),
    file_offset=500,
  )
  assert_eq(event.changes.length(), 1)
  match event.changes[0] {
    Update(before~, after~) => {
      assert_eq(before.bytes_read, 0)
      assert_true(before.columns.all(cell => cell is Absent))
      assert_eq(after.bytes_read, row_sparse.length())
    }
    _ => fail("expected UPDATE")
  }
}

///|
test "packed column counts support two three and eight byte encodings" {
  for input in [rows_count_2, rows_count_3, rows_count_8] {
    let event = rows_context().decode_rows(
      input,
      integer_unsigned=row_image_signs(),
      file_offset=500,
    )
    assert_eq(event.changes.length(), 1)
  }
}

///|
test "malformed ROWS fields counts extra lengths and no-progress pairs fail atomically" {
  for
    input in [
      rows_no_progress, rows_pair_no_progress, rows_wrong_count, rows_zero_count,
      rows_huge_count, rows_null_count, rows_reserved_count, rows_short_count, rows_short_first,
      rows_short_second, rows_short_body, rows_extra_too_short, rows_extra_too_long,
    ] {
    match rows_error(input) {
      InvalidRowsEvent(file_offset~, body_offset~, ..) => {
        assert_eq(file_offset, 0x100000100UL)
        assert_true(body_offset >= 0)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "a missing after image or truncated later row returns no partial event" {
  for input in [rows_half_update, rows_second_short, rows_trailing_byte] {
    let err = rows_error(input)
    assert_true(err is TruncatedInput(..) || err is TruncatedColumnValue(..))
  }
}

///|
test "unknown table ids are explicit and a failed scope can be rebuilt" {
  match rows_error(rows_unknown_table) {
    MissingTableMap(file_offset~, table_id~) => {
      assert_eq(file_offset, 0x100000100UL)
      assert_eq(table_id, 0x010203040507UL)
    }
    other => fail("unexpected error: \{Repr(other)}")
  }
  let context = rows_context()
  try
    context.decode_rows(
      rows_unknown_table,
      integer_unsigned=row_image_signs(),
      file_offset=500,
    )
  catch {
    MissingTableMap(..) => ()
    other => fail("unexpected error: \{Repr(other)}")
  } noraise {
    _ => fail("unknown table accepted")
  }
  assert_eq(context.length(), 0)
  ignore(context.apply(tm_row_image, file_offset=600))
  assert_eq(
    context.decode_rows(
      rows_write_two,
      integer_unsigned=row_image_signs(),
      file_offset=800,
    ).changes.length(),
    2,
  )
}

///|
test "CRC is verified before table lookup even when no table is cached" {
  assert_true(rows_error(rows_bad_crc) is ChecksumMismatch(..))
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  let context = @moonbinlog.TableMapContext::new(format)
  try
    context.decode_rows(
      rows_bad_crc,
      integer_unsigned=row_image_signs(),
      file_offset=500,
    )
  catch {
    ChecksumMismatch(..) => ()
    other => fail("unexpected error: \{Repr(other)}")
  } noraise {
    _ => fail("bad checksum accepted")
  }
  let scope = rows_context()
  ignore(scope.apply(tm_second_id, file_offset=300))
  try
    scope.decode_rows(
      rows_bad_crc,
      integer_unsigned=row_image_signs(),
      file_offset=500,
    )
  catch {
    ChecksumMismatch(..) => assert_eq(scope.length(), 0)
    other => fail("unexpected error: \{Repr(other)}")
  } noraise {
    _ => fail("bad checksum accepted with multiple maps")
  }
}

///|
test "legacy partial-update and format events are not interpreted as ordinary ROWS" {
  for input in [rows_legacy, rows_partial, fde_crc32] {
    assert_true(rows_error(input) is UnsupportedRowsEvent(..))
  }
  let context = rows_context(old_header=true)
  try
    context.decode_rows(
      rows_write_two,
      integer_unsigned=row_image_signs(),
      file_offset=500,
    )
  catch {
    InvalidRowsEvent(..) => assert_eq(context.length(), 0)
    other => fail("unexpected error: \{Repr(other)}")
  } noraise {
    _ => fail("old post-header accepted")
  }
}

///|
test "every incomplete event prefix fails framing and clears cached definitions" {
  for length in 0..<rows_write_two.length() {
    let err = rows_error(rows_write_two[:length])
    assert_true(err is TruncatedInput(..) || err is TruncatedEvent(..))
  }
}

///|
test "scalar diagnostics retain physical offsets and actual table column indexes" {
  match
    rows_error(
      rows_write_two,
      signs=ReadOnlyArray::from_array(Array::make(17, None)),
    ) {
    MissingIntegerSignedness(file_offset~, column_index~) => {
      assert_eq(file_offset, 0x100000123UL)
      assert_eq(column_index, 0)
    }
    other => fail("unexpected error: \{Repr(other)}")
  }
  match rows_error(rows_not_nullable) {
    UnexpectedRowNull(file_offset~, column_index~) => {
      assert_eq(file_offset, 0x100000121UL)
      assert_eq(column_index, 5)
    }
    other => fail("unexpected error: \{Repr(other)}")
  }
  assert_true(rows_error(rows_empty, signs=[]) is InvalidRowImage(..))
}

///|
test "change limits count UPDATE pairs once and per-image byte budgets remain enforced" {
  for input in [rows_write_two, rows_update_two, rows_delete_two] {
    assert_true(
      rows_error(input, max_rows=1) is RowsLimitExceeded(max_rows=1, ..),
    )
    let event = rows_context().decode_rows(
      input,
      integer_unsigned=row_image_signs(),
      file_offset=500,
      max_rows=2,
    )
    assert_eq(event.changes.length(), 2)
  }
  assert_true(
    rows_error(rows_write_two, max_row_bytes=row_full.length() - 1)
    is RowImageLimitExceeded(..),
  )
  assert_true(
    rows_error(rows_write_two, max_row_bytes=0) is RowImageLimitExceeded(..),
  )
  for limit in [0, -1] {
    assert_true(rows_error(rows_empty, max_rows=limit) is InvalidRowsLimit(..))
  }
  assert_true(
    rows_error(rows_empty, max_row_bytes=-1) is InvalidRowImageLimit(..),
  )
  assert_true(
    rows_error(rows_write_two, max_event_size=100) is EventTooLarge(..),
  )
  assert_true(
    rows_error(rows_write_two, max_event_size=0) is InvalidEventLimit(..),
  )
  assert_true(
    rows_error(rows_write_two, file_offset=0xffffffffffffffff)
    is InvalidRowsEvent(..),
  )
}

///|
test "event boundaries exclude following bytes and preserve the current scope on success" {
  let storage = b"guard" + rows_write_two + rows_bad_crc
  let context = rows_context()
  let event = context.decode_rows(
    storage[5:],
    integer_unsigned=row_image_signs(),
    file_offset=500,
  )
  assert_eq(
    event.header.event_size,
    rows_write_two.length().reinterpret_as_uint(),
  )
  assert_eq(event.changes.length(), 2)
  assert_eq(context.length(), 1)
}
