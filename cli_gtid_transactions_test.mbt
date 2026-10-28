// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn bound_events(data : Bytes) -> Array[@moonbinlog.BinlogFileEvent] raise {
  mysql_events(b"\xfebin" + gtid_fde_crc32 + data)
}

///|
fn bound_scanner(
  filter~ : @cli.TableFilter = @cli.TableFilter::all(),
  max_events~ : Int32 = 4096,
  max_changes~ : Int32 = 10000,
  max_bytes~ : UInt64 = 67108864,
) -> @cli.TransactionScanner raise {
  @cli.TransactionScanner::new(
    cli_row_schema(row_image_table(), row_image_signs()),
    with_gtid=true,
    filter~,
    max_events~,
    max_changes~,
    max_bytes~,
  )
}

///|
fn bound_failed(
  scanner : @cli.TransactionScanner,
  format : @moonbinlog.BinlogFileEvent,
) -> Unit raise {
  assert_eq(scanner.gtid_outcome(), None)
  assert_false(scanner.outcome_selected())
  try scanner.feed(format) catch {
    @moonbinlog.GtidTransactionFailed => ()
    other => fail("failed binding scanner recovered: \{Repr(other)}")
  } noraise {
    _ => fail("failed binding scanner accepted FDE")
  }
  try scanner.finish() catch {
    @moonbinlog.GtidTransactionFailed => ()
    other => fail("failed binding scanner finished: \{Repr(other)}")
  } noraise {
    _ => fail("failed binding scanner returned success")
  }
}

///|
test "CLI bound transactions six real commits preserve old fields summaries and row snapshots" {
  for (data, prefix_offset, expected) in gtid_real_oracles() {
    let events = mysql_events(data)
    let table = @moonbinlog.TableMap::parse(
      events[4].format,
      events[4].raw,
      file_offset=events[4].header.file_offset,
    )
    let signs : ReadOnlyArray[Bool?] = if table.columns.length() == 2 {
      [Some(false), None]
    } else {
      mysql_signs
    }
    let schema = cli_row_schema(table, signs)
    let original = @cli.TransactionScanner::new(schema)
    let scanner = @cli.TransactionScanner::new(schema, with_gtid=true)
    let mut completed = 0
    for event in events {
      let old = original.feed(event)
      assert_eq(scanner.feed(event), old)
      if old is Some(outcome) {
        guard scanner.gtid_outcome() is Some(value) else {
          fail("missing binding")
        }
        gtid_assert(value.gtid, expected)
        assert_eq(value.start_offset, prefix_offset)
        assert_true(scanner.outcome_selected())
        guard @json.parse(
            @cli.gtid_json_line(value.gtid, event.format.checksum_algorithm),
          )
          is Object(gtid_fields) else {
          fail("missing GTID fields")
        }
        for include_rows in [false, true] {
          let text = @cli.gtid_transaction_line(
            value,
            schema=if include_rows { Some(schema) } else { None },
          )
          guard @json.parse(text) is Object(fields) else {
            fail("missing fields")
          }
          assert_eq(fields.get("gtid"), gtid_fields.get("gtid"))
          fields.remove("gtid") |> ignore
          fields.remove("gtid_span") |> ignore
          let legacy = if include_rows {
            @cli.transaction_rows_line(outcome, schema)
          } else {
            @cli.transaction_line(outcome)
          }
          assert_eq(Json::object(fields), @json.parse(legacy))
        }
        completed += 1
      } else {
        assert_eq(scanner.gtid_outcome(), None)
      }
    }
    assert_eq(completed, 1)
    assert_eq(scanner.gtid_outcome(), None)
    scanner.finish()
    original.finish()
  }
}

///|
test "CLI bound transactions assigned commit and anonymous rollback preserve selection and no rollback rows" {
  let events = bound_events(
    gtx_prefix() +
    tx_stream_commit +
    gtx_prefix(name="anonymous") +
    tx_stream_rollback,
  )
  let scanner = bound_scanner()
  let mut count = 0
  for event in events {
    if scanner.feed(event) is Some(outcome) {
      guard scanner.gtid_outcome() is Some(value) else {
        fail("missing association")
      }
      assert_eq(value.transaction, outcome)
      assert_eq(value.gtid.is_anonymous(), count == 1)
      guard @json.parse(
          @cli.gtid_transaction_line(
            value,
            schema=Some(cli_row_schema(row_image_table(), row_image_signs())),
          ),
        )
        is Object(fields) else {
        fail("missing report")
      }
      if count == 1 {
        assert_eq(fields.get("status"), Some(Json::string("rolled_back")))
        assert_false(fields.contains("row_changes"))
        assert_false(fields.contains("tables"))
      } else {
        assert_true(fields.contains("row_changes"))
        assert_eq(
          fields.get("gtid_span"),
          Some({
            "start_offset": "126",
            "end_offset": Json::string(value.end_offset.to_string()),
            "events": 5,
            "event_bytes": Json::string(value.wire_bytes.to_string()),
          }),
        )
      }
      count += 1
    }
  }
  assert_eq(count, 2)
  scanner.finish()
}

///|
test "CLI bound transactions filter whole spans including rollback and exclude empty spans" {
  for (table, selected) in [("orders", true), ("other", false)] {
    let scanner = bound_scanner(filter={
      database: Some("shop"),
      table: Some(table),
    })
    let bytes = gtx_prefix() +
      tx_stream_commit +
      gtx_prefix() +
      tx_stream_rollback +
      gtx_prefix() +
      tx_begin +
      tx_commit
    let mut count = 0
    for event in bound_events(bytes) {
      if scanner.feed(event) is Some(_) {
        assert_eq(
          scanner.outcome_selected(),
          if count == 2 {
            false
          } else {
            selected
          },
        )
        assert_true(scanner.gtid_outcome() is Some(_))
        count += 1
      }
    }
    assert_eq(count, 3)
    scanner.finish()
  }
}

///|
test "CLI bound transactions EOF schema errors invalid GTID and format reset fail permanently" {
  let (_, invalid_gtid) = gtid_invalid()[0]
  for
    bytes in [
      gtx_prefix(),
      gtx_prefix() + tx_stream_unfinished,
      tx_stream_commit,
      invalid_gtid,
    ] {
    let events = bound_events(bytes)
    let scanner = bound_scanner()
    try {
      for event in events {
        scanner.feed(event) |> ignore
      }
      scanner.finish()
    } catch {
      _ => bound_failed(scanner, events[0])
    } noraise {
      _ => fail("invalid or incomplete bound span accepted")
    }
  }
  let events = bound_events(gtx_prefix() + gtid_fde_crc32)
  let scanner = bound_scanner()
  scanner.feed(events[0]) |> ignore
  scanner.feed(events[1]) |> ignore
  try scanner.feed(events[2]) catch {
    _ => bound_failed(scanner, events[0])
  } noraise {
    _ => fail("unfinished prefix survived FDE")
  }
  let missing = @moonbinlog.SchemaConfig::parse(
    "{\"schema_version\":1,\"tables\":[]}",
  )
  let scanner = @cli.TransactionScanner::new(missing, with_gtid=true)
  let events = bound_events(gtx_prefix() + tx_stream_commit)
  try {
    for event in events {
      scanner.feed(event) |> ignore
    }
  } catch {
    _ => bound_failed(scanner, events[0])
  } noraise {
    _ => fail("missing schema accepted")
  }
}

///|
test "CLI bound transactions enforce prefix budgets and allow idle format transitions" {
  for
    (max_events, max_changes, max_bytes) in [
      (4, 10000, 67108864UL),
      (4096, 10000, 1UL),
      (4096, 1, 67108864UL),
    ] {
    let scanner = bound_scanner(max_events~, max_changes~, max_bytes~)
    let events = bound_events(gtx_prefix() + tx_stream_two_rows)
    try {
      for event in events {
        scanner.feed(event) |> ignore
      }
    } catch {
      _ => bound_failed(scanner, events[0])
    } noraise {
      _ => fail("bound span limit ignored")
    }
  }
  let scanner = bound_scanner()
  let events = bound_events(
    gtx_prefix() +
    tx_begin +
    tx_commit +
    gtid_fde_crc32 +
    gtx_prefix() +
    tx_begin +
    tx_commit,
  )
  let mut count = 0
  for event in events {
    if scanner.feed(event) is Some(_) {
      count += 1
    }
  }
  assert_eq(count, 2)
  scanner.finish()
}
