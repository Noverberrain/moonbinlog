// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn json_rows_table() -> @moonbinlog.TableMap raise {
  @moonbinlog.TableMap::parse(tx_format(), tm_json_rows, file_offset=126)
}

///|
test "real MySQL JSON FULL MINIMAL OFF rows match official exact oracle values" {
  for
    (data, expected) in [
      (mysql_json_crc32_full, mysql_json_crc32_full_oracle),
      (mysql_json_crc32_minimal, mysql_json_crc32_minimal_oracle),
      (mysql_json_off_full, mysql_json_off_full_oracle),
    ] {
    let events = mysql_events(data)
    let table = @moonbinlog.TableMap::parse(
      events[4].format,
      events[4].raw,
      file_offset=events[4].header.file_offset,
    )
    let schema = cli_row_schema(table, [Some(false), None])
    let outcomes = cli_tx_run(@cli.TransactionScanner::new(schema), events)
    guard outcomes[0] is Committed(transaction) else {
      fail("missing real JSON commit")
    }
    assert_eq(transaction.change_count, 6)
    let images = []
    for event in transaction.events {
      for change in event.changes {
        match change {
          Insert(row) | Delete(row) => images.push(row)
          Update(before~, after~) => {
            images.push(before)
            images.push(after)
          }
        }
      }
    }
    assert_eq(images.length(), expected.length())
    for i, row in images {
      for j, cell in row.columns {
        assert_eq(mysql_cell_text(cell), expected[i][j])
      }
    }
  }
}

///|
test "JSON row image distinguishes SQL NULL absent and JSON literal null" {
  let table = json_rows_table()
  let id = b"\x01\x00\x00\x00"
  let signs : ReadOnlyArray[Bool?] = [Some(false), None]
  let sql_null = table.decode_row_image(
    b"\x02" + id,
    columns_present=b"\x03",
    integer_unsigned=signs,
    file_offset=50,
  )
  assert_eq(sql_null.columns[1], Null)
  let absent = table.decode_row_image(
    b"\x00" + id,
    columns_present=b"\x01",
    integer_unsigned=signs,
    file_offset=50,
  )
  assert_eq(absent.columns[1], Absent)
  let field = b"\x00" + id + json_field(b"\x04\x00")
  let literal = table.decode_row_image(
    field,
    columns_present=b"\x03",
    integer_unsigned=signs,
    file_offset=50,
  )
  guard literal.columns[1] is JsonDocument(decoded) else {
    fail("JSON null confused with SQL NULL")
  }
  assert_eq(decoded.value.to_json_text(), "null")
  assert_eq(@cli.row_cell_json(literal.columns[1], 1, "document"), {
    "index": 1,
    "name": "document",
    "state": "value",
    "type": "json",
    "encoding": "json_text",
    "value": "null",
  })
  try
    table.decode_row_image(
      field,
      columns_present=b"\x03",
      integer_unsigned=signs,
      file_offset=50,
      max_bytes=field.length() - 1,
    )
  catch {
    RowImageLimitExceeded(..) => ()
    other => fail("unexpected JSON row budget error: \{Repr(other)}")
  } noraise {
    _ => fail("JSON bypassed row budget")
  }
}

///|
test "JSON rows integrate inserts minimal updates deletes and committed CLI values" {
  for
    (raw, count) in [
      (rows_json_insert, 3),
      (rows_json_update, 1),
      (rows_json_delete, 1),
    ] {
    let context = @moonbinlog.TableMapContext::new(tx_format())
    context.apply(tm_json_rows, file_offset=126) |> ignore
    let rows = context.decode_rows(raw, file_offset=500, integer_unsigned=[
      Some(false),
      None,
    ])
    assert_eq(rows.changes.length(), count)
    assert_eq(context.length(), 0)
  }
  let schema = cli_row_schema(json_rows_table(), [Some(false), None])
  let outcomes = cli_tx_run(
    @cli.TransactionScanner::new(schema),
    cli_synthetic_events(json_transaction),
  )
  guard outcomes[0] is Committed(transaction) else {
    fail("expected JSON transaction")
  }
  assert_eq(transaction.change_count, 5)
  guard transaction.events[1].changes[0] is Update(after~, ..) else {
    fail("expected update")
  }
  assert_eq(after.columns[0], Absent)
  guard after.columns[1] is JsonDocument(value) else {
    fail("missing updated JSON")
  }
  assert_eq(value.value.to_json_text(), "\"更新\"")
  guard @json.parse(@cli.transaction_rows_line(outcomes[0], schema))
    is { "row_changes": Array(changes), .. } else {
    fail("missing committed JSON changes")
  }
  guard changes[0] is { "after": Array(cells), .. } else {
    fail("missing first image")
  }
  guard cells[1]
    is { "type": "json", "encoding": "json_text", "value": String(text), .. } else {
    fail("missing JSON text")
  }
  assert_true(text.contains("18446744073709551615"))
  guard changes[1] is { "after": Array(cells), .. } else {
    fail("missing SQL NULL row")
  }
  guard cells[1] is { "state": "null", .. } else { fail("SQL NULL changed") }
  guard changes[2] is { "after": Array(cells), .. } else {
    fail("missing JSON null row")
  }
  guard cells[1] is { "state": "value", "value": "null", .. } else {
    fail("JSON null changed")
  }
}

///|
test "invalid JSON aborts pending transactions and clears row mapping state" {
  let schema = cli_row_schema(json_rows_table(), [Some(false), None])
  let scanner = @cli.TransactionScanner::new(schema)
  let events = cli_synthetic_events(
    tx_begin + tm_json_rows + rows_json_bad + tx_xid,
  )
  for event in events[:3] {
    scanner.feed(event) |> ignore
  }
  try scanner.feed(events[3]) catch {
    @moonbinlog.DecodeError::InvalidJsonValue(..) => ()
    other => fail("unexpected JSON row error: \{Repr(other)}")
  } noraise {
    _ => fail("bad JSON transaction returned")
  }
  try scanner.feed(events[4]) catch {
    @moonbinlog.DecodeError::InvalidTransactionState(..) => ()
    other => fail("failed JSON left pending transaction: \{Repr(other)}")
  } noraise {
    _ => fail("invalid JSON committed")
  }
  let context = @moonbinlog.TableMapContext::new(tx_format())
  context.apply(tm_json_rows, file_offset=126) |> ignore
  try
    context.decode_rows(rows_json_bad, file_offset=500, integer_unsigned=[
      Some(false),
      None,
    ])
  catch {
    InvalidJsonValue(..) => assert_eq(context.length(), 0)
    other => fail("unexpected context JSON error: \{Repr(other)}")
  } noraise {
    _ => fail("bad JSON row returned")
  }
}
