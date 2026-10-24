// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
test "CLI committed rows preserve real image fields and label each change committed" {
  for bytes in [mysql_crc32_full, mysql_crc32_minimal, mysql_off_full] {
    let events = mysql_events(bytes)
    let table = @moonbinlog.TableMap::parse(
      events[4].format,
      events[4].raw,
      file_offset=events[4].header.file_offset,
    )
    let schema = cli_row_schema(table, mysql_signs)
    let outcomes = cli_tx_run(@cli.TransactionScanner::new(schema), events)
    guard outcomes[0] is Committed(transaction) else { fail("expected commit") }
    guard @json.parse(@cli.transaction_rows_line(outcomes[0], schema))
      is Object(fields) else {
      fail("expected transaction object")
    }
    guard fields.get("row_changes") is Some(Array(changes)) else {
      fail("missing row changes")
    }
    assert_eq(changes.length(), transaction.change_count)
    for i, event in transaction.events {
      let expected = @json.parse(
        @cli.row_change_line(event, schema.bind(event.table), 0),
      )
      guard expected is Object(expected) else { fail("expected row object") }
      expected["transaction_status"] = "committed"
      assert_eq(changes[i], Json::object(expected))
    }
    fields.remove("row_changes") |> ignore
    assert_eq(
      Json::object(fields),
      @json.parse(@cli.transaction_line(outcomes[0])),
    )
  }
}

///|
test "CLI committed rows omit rollback values and explicitly represent empty commits" {
  let schema = cli_row_schema(row_image_table(), row_image_signs())
  let rolled = cli_tx_run(
    cli_tx_scanner(),
    cli_synthetic_events(tx_stream_rollback),
  )
  assert_eq(
    @cli.transaction_rows_line(rolled[0], schema),
    @cli.transaction_line(rolled[0]),
  )
  let empty = cli_tx_run(
    cli_tx_scanner(),
    cli_synthetic_events(tx_begin + tx_commit),
  )
  guard @json.parse(@cli.transaction_rows_line(empty[0], schema))
    is {
      "status": "committed",
      "xid": Null,
      "changes": 0,
      "row_changes": Array(changes),
      ..
    } else {
    fail("empty commit lost shape")
  }
  assert_eq(changes.length(), 0)
}

///|
test "CLI committed rows retain multirow order update pairs and per event indices" {
  let schema = cli_row_schema(row_image_table(), row_image_signs())
  let outcomes = cli_tx_run(
    cli_tx_scanner(),
    cli_synthetic_events(
      tx_begin +
      tm_row_image +
      rows_write_two +
      tm_row_image +
      rows_update_two +
      tx_xid,
    ),
  )
  guard @json.parse(@cli.transaction_rows_line(outcomes[0], schema))
    is { "row_changes": Array(changes), .. } else {
    fail("missing changes")
  }
  assert_eq(changes.length(), 4)
  for i, change in changes {
    guard change
      is {
        "change_index": Number(index, ..),
        "operation": String(operation),
        "transaction_status": "committed",
        "before": before,
        "after": Array(_),
        ..
      } else {
      fail("invalid row shape")
    }
    assert_eq(index, (i % 2).to_double())
    assert_eq(operation, if i < 2 { "insert" } else { "update" })
    assert_eq(before == Json::null(), i < 2)
  }
}

///|
test "CLI committed rows reject missing output schema instead of returning partial JSON" {
  let outcomes = cli_tx_run(
    cli_tx_scanner(),
    cli_synthetic_events(tx_stream_commit),
  )
  let empty = @moonbinlog.SchemaConfig::parse(
    "{\"schema_version\":1,\"tables\":[]}",
  )
  try @cli.transaction_rows_line(outcomes[0], empty) catch {
    @moonbinlog.SchemaError::MissingTableSchema(..) => ()
    other => fail("unexpected output error: \{Repr(other)}")
  } noraise {
    _ => fail("missing output schema accepted")
  }
}
