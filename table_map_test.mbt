// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn table_map_error(
  data : BytesView,
  max_columns~ : Int32 = 1024,
) -> @moonbinlog.DecodeError raise {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  try
    @moonbinlog.TableMap::parse(format, data, file_offset=126, max_columns~)
  catch {
    err => err
  } noraise {
    _ => fail("invalid table map was accepted")
  }
}

///|
test "table map decodes the 48-bit id names flags and column metadata" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  let table = @moonbinlog.TableMap::parse(format, tm_basic, file_offset=126)
  assert_eq(table.header.file_offset, 126UL)
  assert_eq(table.header.event_type, (19 : Byte))
  assert_eq(table.table_id, 0x010203040506UL)
  assert_eq(table.flags, (0x1234 : UInt16))
  assert_eq(table.database, "shop")
  assert_eq(table.table, "orders")
  assert_eq(table.columns.length(), 10)
  assert_eq(table.columns[0].wire_type, (8 : Byte))
  assert_eq(table.columns[0].metadata.length(), 0)
  assert_eq(table.columns[1].metadata, ([0x58, 0x02] : Bytes))
  assert_eq(table.columns[2].metadata, ([10, 2] : Bytes))
  assert_eq(table.columns[3].metadata, ([6] : Bytes))
  assert_eq(table.columns[4].metadata, ([4] : Bytes))
  assert_eq(table.optional_metadata.length(), 0)
}

///|
test "nullable bitmap uses LSB-first ordering across byte boundaries and ignores padding" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  let expected = [
    true, false, true, false, true, false, false, true, true, false,
  ]
  for input in [tm_basic, tm_padding_bits] {
    let table = @moonbinlog.TableMap::parse(format, input, file_offset=126)
    for i in 0..<10 {
      assert_eq(table.columns[i].nullable, expected[i])
    }
  }
}

///|
test "optional metadata preserves known and unknown TLV values without schema guesses" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  let table = @moonbinlog.TableMap::parse(format, tm_optional, file_offset=126)
  assert_eq(table.optional_metadata.length(), 3)
  assert_eq(table.optional_metadata[0].field_type, (1 : Byte))
  assert_eq(table.optional_metadata[0].value, ([0xa0] : Bytes))
  assert_eq(table.optional_metadata[1].field_type, (4 : Byte))
  assert_eq(
    table.optional_metadata[1].value[:3].to_owned(),
    ([2, 0x69, 0x64] : Bytes),
  )
  assert_eq(table.optional_metadata[2].field_type, (255 : Byte))
  assert_eq(table.optional_metadata[2].value, ([0xde, 0xad] : Bytes))
}

///|
test "database and table names preserve Unicode and a leading BOM codepoint" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  let table = @moonbinlog.TableMap::parse(format, tm_unicode, file_offset=126)
  assert_eq(table.database, "商店")
  assert_eq(table.table, "订单")
  let bom = @moonbinlog.TableMap::parse(format, tm_bom_name, file_offset=126)
  assert_eq(bom.database.length(), 5)
  assert_eq(bom.database[0], (0xfeff : UInt16))
}

///|
test "packed column counts accept all non-NULL integer encodings" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  let baseline = @moonbinlog.TableMap::parse(format, tm_basic, file_offset=126)
  for input in [tm_count_fc, tm_count_fd, tm_count_fe] {
    let table = @moonbinlog.TableMap::parse(format, input, file_offset=126)
    assert_eq(table.columns, baseline.columns)
  }
}

///|
test "table map supports the full unsigned six-byte id range" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  let table = @moonbinlog.TableMap::parse(
    format,
    tm_max_id,
    file_offset=0x100000004,
  )
  assert_eq(table.table_id, 0xffffffffffffUL)
  assert_eq(table.header.file_offset, 0x100000004UL)
}

///|
test "metadata splitting preserves byte order for every supported width group" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  let table = @moonbinlog.TableMap::parse(
    format,
    tm_metadata_widths,
    file_offset=126,
  )
  assert_eq(table.columns.length(), 29)
  assert_eq(table.columns[4].metadata, ([4] : Bytes))
  assert_eq(table.columns[5].metadata, ([8] : Bytes))
  assert_eq(table.columns[14].metadata, ([255, 0] : Bytes))
  assert_eq(table.columns[15].metadata, ([1, 1] : Bytes))
  assert_eq(table.columns[20].metadata, ([10, 2] : Bytes))
  assert_eq(table.columns[21].metadata, ([247, 1] : Bytes))
  assert_eq(table.columns[27].metadata, ([254, 20] : Bytes))
  assert_eq(table.columns[28].metadata, ([4] : Bytes))
  for column in table.columns {
    assert_true(column.nullable)
  }
}

///|
test "table map accepts OFF framing and ignores following bytes outside its declared event" {
  let off = @moonbinlog.FormatDescription::parse(fde_off, file_offset=4)
  let table = @moonbinlog.TableMap::parse(off, tm_off, file_offset=126)
  assert_eq(table.table, "orders")
  assert_eq(table.columns.length(), 10)
  let crc = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  let wrapped = joined_bytes(b"xx", joined_bytes(tm_basic, event_crc32))
  let nested = @moonbinlog.TableMap::parse(crc, wrapped[2:], file_offset=126)
  assert_eq(nested.columns, table.columns)
}

///|
test "table map verifies checksum and rejects other event types" {
  let corrupt = changed_byte(tm_basic, 30, tm_basic[30] ^ 1)
  assert_true(table_map_error(corrupt) is ChecksumMismatch(..))
  assert_true(
    table_map_error(event_crc32)
    is UnexpectedEventType(expected=19, actual=16, ..),
  )
}

///|
test "table map rejects every incomplete full-event prefix" {
  for length in 0..<tm_basic.length() {
    let err = table_map_error(tm_basic[:length])
    if length < 19 {
      assert_true(err is TruncatedInput(..))
    } else {
      assert_true(err is TruncatedEvent(..))
    }
  }
}

///|
test "table map requires the supported post-header descriptor in its format" {
  for input in [tm_old_header_format, tm_missing_header_format] {
    let format = @moonbinlog.FormatDescription::parse(input, file_offset=4)
    try @moonbinlog.TableMap::parse(format, tm_basic, file_offset=126) catch {
      InvalidTableMap(..) => ()
      other => fail("unexpected error: \{Repr(other)}")
    } noraise {
      _ => fail("unsupported table-map descriptor was accepted")
    }
  }
}

///|
test "unknown and unsupported wire types fail instead of assuming zero metadata" {
  for (input, wire_type) in [(tm_unknown_type, 20), (tm_var_string, 253)] {
    match table_map_error(input) {
      UnsupportedColumnType(column_index=0, wire_type=actual, ..) =>
        assert_eq(actual.to_int(), wire_type)
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "table map checks field bounds identifiers and exact metadata consumption" {
  for
    input in [
      tm_short_metadata, tm_long_metadata, tm_short_nullable, tm_short_postheader,
      tm_short_name, tm_short_types, tm_bad_terminator, tm_empty_name, tm_nul_name,
      tm_invalid_utf8, tm_zero_columns, tm_huge_metadata,
    ] {
    match table_map_error(input) {
      InvalidTableMap(file_offset~, body_offset~, ..) => {
        assert_eq(file_offset, 126UL)
        assert_true(body_offset >= 0)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "packed lengths reject NULL reserved and incomplete encodings" {
  for input in [tm_null_length, tm_reserved_length, tm_short_length] {
    assert_true(table_map_error(input) is InvalidTableMap(..))
  }
}

///|
test "column count limits are checked before integer narrowing or allocation" {
  assert_true(
    table_map_error(tm_huge_columns)
    is ColumnLimitExceeded(count=0xffffffffffffffff, ..),
  )
  assert_true(
    table_map_error(tm_excess_columns)
    is ColumnLimitExceeded(count=1025, max_columns=1024, ..),
  )
  assert_true(
    table_map_error(tm_basic, max_columns=9)
    is ColumnLimitExceeded(count=10, max_columns=9, ..),
  )
  assert_true(
    table_map_error(tm_basic, max_columns=0) is InvalidColumnLimit(..),
  )
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  let table = @moonbinlog.TableMap::parse(
    format,
    tm_basic,
    file_offset=126,
    max_columns=10,
  )
  assert_eq(table.columns.length(), 10)
}

///|
test "optional metadata validates TLV lengths and has a fixed field-count ceiling" {
  for input in [tm_short_tlv, tm_long_tlv, tm_excess_tlv] {
    assert_true(table_map_error(input) is InvalidTableMap(..))
  }
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  let table = @moonbinlog.TableMap::parse(format, tm_max_tlv, file_offset=126)
  assert_eq(table.optional_metadata.length(), 256)
  assert_eq(table.optional_metadata[255].value.length(), 0)
}
