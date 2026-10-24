// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn cli_row_schema(
  table : @moonbinlog.TableMap,
  signs : ReadOnlyArray[Bool?],
) -> @moonbinlog.SchemaConfig raise {
  let value = schema_for_map(table)
  guard schema_table_object(value).get("columns") is Some(Array(columns)) else {
    fail("expected columns")
  }
  for i, column in columns {
    if signs[i] is Some(flag) {
      guard column is Object(fields) else { fail("expected column") }
      fields["unsigned"] = @json.to_json(flag)
    }
  }
  @moonbinlog.SchemaConfig::parse(value.stringify())
}

///|
fn cli_synthetic_events(
  stream : Bytes,
) -> Array[@moonbinlog.BinlogFileEvent] raise {
  mysql_events(file_magic + fde_crc32 + stream)
}

///|
test "CLI row scanner renders unconfirmed real FULL MINIMAL and OFF events" {
  for bytes in [mysql_crc32_full, mysql_crc32_minimal, mysql_off_full] {
    let events = mysql_events(bytes)
    let table = @moonbinlog.TableMap::parse(
      events[4].format,
      events[4].raw,
      file_offset=events[4].header.file_offset,
    )
    let scanner = @cli.RowScanner::new(cli_row_schema(table, mysql_signs))
    let records = []
    for event in events {
      if scanner.feed(event) is Some((rows, bound)) {
        for i in 0..<rows.changes.length() {
          records.push(@json.parse(@cli.row_change_line(rows, bound, i)))
        }
      }
    }
    assert_eq(records.length(), 4)
    for record in records {
      guard record
        is { "kind": "row_change", "transaction_status": "unconfirmed", .. } else {
        fail("missing row status")
      }
    }
    guard records[0]
      is { "operation": "insert", "before": Null, "after": Array(columns), .. } else {
      fail("expected insert")
    }
    guard columns[4]
      is {
        "name": "c4",
        "type": "integer",
        "unsigned": true,
        "value": "18446744073709551615",
        ..
      } else {
      fail("lost UInt64 or label")
    }
    guard records[2]
      is { "operation": "update", "before": Array(_), "after": Array(_), .. } else {
      fail("expected update pair")
    }
    guard records[3] is { "operation": "delete", "after": Null, .. } else {
      fail("expected delete")
    }
  }
}

///|
test "CLI row cells distinguish absent NULL exact integers and escaped labels" {
  assert_eq(@cli.row_cell_json(Absent, 0, "x"), {
    "index": 0,
    "name": "x",
    "state": "absent",
  })
  assert_eq(@cli.row_cell_json(Null, 0, "x"), {
    "index": 0,
    "name": "x",
    "state": "null",
  })
  let name = "列\"\\\n"
  let value = @cli.row_cell_json(
    Integer(Signed(-9223372036854775808L)),
    3,
    name,
  )
  assert_eq(value, {
    "index": 3,
    "name": Json::string(name),
    "state": "value",
    "type": "integer",
    "unsigned": false,
    "value": "-9223372036854775808",
  })
  assert_eq(@json.parse(value.stringify()), value)
  assert_false(value.stringify().contains("\n"))
  guard @cli.row_cell_json(EnumSet(SetMask(0xffffffffffffffff)), 0, "set")
    is { "value": "18446744073709551615", "type": "set", .. } else {
    fail("lost SET precision")
  }
}

///|
test "CLI row encoding preserves binary bytes and negative floating zero bits" {
  assert_eq(@cli.row_cell_json(StringBytes(b"\x00\xff"), 1, "binary"), {
    "index": 1,
    "name": "binary",
    "state": "value",
    "type": "string_bytes",
    "encoding": "hex",
    "value": "00ff",
  })
  guard @cli.row_cell_json(BlobBytes(b"\x00\xff"), 1, "blob")
    is { "type": "blob_bytes", "value": "00ff", .. } else {
    fail("lost BLOB bytes")
  }
  let table = floating_test_table()
  let decoded = table.columns[1].decode_floating(
    b"\x00\x00\x00\x00\x00\x00\x00\x80",
    file_offset=0,
    column_index=1,
  )
  guard @cli.row_cell_json(Floating(decoded), 0, "zero")
    is { "type": "float64", "bits": "9223372036854775808", .. } else {
    fail("lost negative zero bits")
  }
}

///|
test "CLI row scanner requires FDE and rechecks schemas on each map" {
  let events = cli_synthetic_events(tm_row_image + rows_write_end)
  let table = row_image_table()
  let scanner = @cli.RowScanner::new(cli_row_schema(table, row_image_signs()))
  try scanner.feed(events[1]) catch {
    @cli.RowScanError::MissingFormat(..) => ()
    other => fail("unexpected format error: \{Repr(other)}")
  } noraise {
    _ => fail("missing format accepted")
  }
  let empty = @moonbinlog.SchemaConfig::parse(
    "{\"schema_version\":1,\"tables\":[]}",
  )
  let scanner = @cli.RowScanner::new(empty)
  scanner.feed(events[0]) |> ignore
  try scanner.feed(events[1]) catch {
    @moonbinlog.SchemaError::MissingTableSchema(..) => ()
    other => fail("unexpected schema error: \{Repr(other)}")
  } noraise {
    _ => fail("missing schema accepted")
  }
  try scanner.feed(events[2]) catch {
    @moonbinlog.DecodeError::MissingTableMap(..) => ()
    other => fail("schema failure retained map: \{Repr(other)}")
  } noraise {
    _ => fail("map survived failed binding")
  }
}

///|
test "CLI row scanner clears mappings at statement end FDE control and unknown events" {
  let schema = cli_row_schema(row_image_table(), row_image_signs())
  for middle in [rows_write_end, fde_crc32, tx_commit, tx_unknown] {
    let events = cli_synthetic_events(tm_row_image + middle + rows_write_end)
    let scanner = @cli.RowScanner::new(schema)
    scanner.feed(events[0]) |> ignore
    scanner.feed(events[1]) |> ignore
    if middle == tx_unknown {
      try scanner.feed(events[2]) catch {
        @cli.RowScanError::UnsupportedEvent(event_type=29, ..) => ()
        other => fail("unexpected unknown event: \{Repr(other)}")
      } noraise {
        _ => fail("unknown event skipped")
      }
    } else {
      scanner.feed(events[2]) |> ignore
    }
    try scanner.feed(events[3]) catch {
      @moonbinlog.DecodeError::MissingTableMap(..) => ()
      other => fail("stale map survived: \{Repr(other)}")
    } noraise {
      _ => fail("stale table mapping accepted")
    }
  }
}

///|
test "CLI row scanner rejects a complete malformed ROWS event before returning partial changes" {
  let events = cli_synthetic_events(
    tm_row_image + rows_half_update + rows_write_end,
  )
  let scanner = @cli.RowScanner::new(
    cli_row_schema(row_image_table(), row_image_signs()),
  )
  scanner.feed(events[0]) |> ignore
  scanner.feed(events[1]) |> ignore
  try scanner.feed(events[2]) catch {
    @moonbinlog.DecodeError::TruncatedInput(..)
    | @moonbinlog.DecodeError::TruncatedColumnValue(..) => ()
    other => fail("unexpected partial UPDATE error: \{Repr(other)}")
  } noraise {
    _ => fail("partial UPDATE returned")
  }
  try scanner.feed(events[3]) catch {
    @moonbinlog.DecodeError::MissingTableMap(..) => ()
    other => fail("failed ROWS left stale maps: \{Repr(other)}")
  } noraise {
    _ => fail("failed ROWS did not clear maps")
  }
}

///|
test "CLI multirow indices are stable and mismatched output snapshots are rejected" {
  let events = cli_synthetic_events(tm_row_image + rows_write_two)
  let schema = cli_row_schema(row_image_table(), row_image_signs())
  let scanner = @cli.RowScanner::new(schema)
  scanner.feed(events[0]) |> ignore
  scanner.feed(events[1]) |> ignore
  guard scanner.feed(events[2]) is Some((rows, bound)) else {
    fail("expected rows")
  }
  assert_eq(rows.changes.length(), 2)
  for i in 0..<2 {
    guard @json.parse(@cli.row_change_line(rows, bound, i))
      is { "change_index": Number(index, ..), .. } else {
      fail("missing index")
    }
    assert_eq(index, i.to_double())
  }
  for i in [-1, 2] {
    try @cli.row_change_line(rows, bound, i) catch {
      InvalidOutput(_) => ()
      other => fail("unexpected output error: \{Repr(other)}")
    } noraise {
      _ => fail("invalid row index accepted")
    }
  }
  let other_table = @moonbinlog.TableMap::parse(
    events[1].format,
    tm_row_image,
    file_offset=999,
  )
  let other = schema.bind(other_table)
  try @cli.row_change_line(rows, other, 0) catch {
    InvalidOutput(_) => ()
    other => fail("unexpected output error: \{Repr(other)}")
  } noraise {
    _ => fail("mismatched map snapshot accepted")
  }
}
