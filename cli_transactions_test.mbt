// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn cli_tx_scanner(
  max_events~ : Int32 = 4096,
  max_changes~ : Int32 = 10000,
  max_bytes~ : UInt64 = 67_108_864,
) -> @cli.TransactionScanner raise {
  @cli.TransactionScanner::new(
    cli_row_schema(row_image_table(), row_image_signs()),
    max_events~,
    max_changes~,
    max_bytes~,
  )
}

///|
fn cli_tx_run(
  scanner : @cli.TransactionScanner,
  events : Array[@moonbinlog.BinlogFileEvent],
) -> Array[@moonbinlog.TransactionOutcome] raise {
  let outcomes = []
  for event in events {
    if scanner.feed(event) is Some(outcome) {
      outcomes.push(outcome)
    }
  }
  scanner.finish()
  outcomes
}

///|
test "CLI transactions match real FULL MINIMAL OFF explicit commit spans" {
  for data in [mysql_crc32_full, mysql_crc32_minimal, mysql_off_full] {
    let events = mysql_events(data)
    let table = @moonbinlog.TableMap::parse(
      events[4].format,
      events[4].raw,
      file_offset=events[4].header.file_offset,
    )
    let scanner = @cli.TransactionScanner::new(
      cli_row_schema(table, mysql_signs),
    )
    let outcomes = cli_tx_run(scanner, events)
    assert_eq(outcomes.length(), 1)
    guard outcomes[0] is Committed(transaction) else { fail("expected commit") }
    assert_eq(transaction.change_count, 4)
    assert_eq(transaction.events.length(), 4)
    assert_eq(transaction.start_offset, events[3].header.file_offset)
    assert_eq(transaction.end_offset, events[13].header.file_offset)
    assert_eq(transaction.event_count, 10)
  }
}

///|
test "CLI transactions buffer until commit and summarize rollback without row values" {
  let events = cli_synthetic_events(tx_stream_commit)
  let scanner = cli_tx_scanner()
  for event in events[:events.length() - 1] {
    assert_eq(scanner.feed(event), None)
  }
  guard scanner.feed(events[events.length() - 1]) is Some(outcome) else {
    fail("commit not returned")
  }
  guard @json.parse(@cli.transaction_line(outcome))
    is {
      "kind": "transaction",
      "status": "committed",
      "xid": "18364758544493064720",
      "changes": 1,
      "row_events": 1,
      "events": 4,
      "tables": Array(tables),
      ..
    } else {
    fail("commit JSON lost counts or UInt64 precision")
  }
  assert_eq(tables, [
    { "database": "shop", "table": "orders", "row_events": 1, "changes": 1 },
  ])
  scanner.finish()
  let outcomes = cli_tx_run(
    cli_tx_scanner(),
    cli_synthetic_events(tx_stream_rollback),
  )
  guard @json.parse(@cli.transaction_line(outcomes[0]))
    is { "status": "rolled_back", "discarded_changes": 1, .. } else {
    fail("missing rollback counts")
  }
  guard @json.parse(@cli.transaction_line(outcomes[0])) is Object(fields) else {
    fail("expected object")
  }
  assert_false(fields.contains("tables"))
  assert_false(fields.contains("changes"))
  let stats = @cli.TransactionStats::new()
  stats.record(outcome)
  stats.record(outcomes[0])
  guard @json.parse(stats.json_line(@cli.Stats::new(), 4))
    is {
      "kind": "transaction_summary",
      "committed_transactions": 1,
      "rolled_back_transactions": 1,
      "committed_changes": 1,
      "discarded_changes": 1,
      ..
    } else {
    fail("invalid summary")
  }
}

///|
test "CLI transactions handle empty commits multiple transactions and statement map cleanup" {
  for
    (stream, changes) in [
      (tx_begin + tx_commit, 0),
      (tx_stream_two_statements, 3),
      (tx_stream_updates, 2),
    ] {
    let outcomes = cli_tx_run(cli_tx_scanner(), cli_synthetic_events(stream))
    guard outcomes[0] is Committed(transaction) else { fail("expected commit") }
    assert_eq(transaction.change_count, changes)
    assert_eq(
      transaction.xid,
      if stream == tx_stream_updates {
        Some(0xfedcba9876543210)
      } else {
        None
      },
    )
  }
  let outcomes = cli_tx_run(
    cli_tx_scanner(),
    cli_synthetic_events(tx_stream_two_transactions),
  )
  assert_eq(outcomes.length(), 2)
  let events = cli_synthetic_events(
    tx_begin + tm_row_image + rows_write_end + rows_write_end,
  )
  let scanner = cli_tx_scanner()
  for event in events[:4] {
    scanner.feed(event) |> ignore
  }
  try scanner.feed(events[4]) catch {
    @moonbinlog.DecodeError::MissingTableMap(..) => ()
    other => fail("stale mapping survived: \{Repr(other)}")
  } noraise {
    _ => fail("statement map was retained")
  }
}

///|
test "CLI transactions reject incomplete EOF format changes and envelopes inside active spans" {
  for tail in [b"", fde_crc32] {
    let scanner = cli_tx_scanner()
    try
      cli_tx_run(scanner, cli_synthetic_events(tx_stream_unfinished + tail))
    catch {
      @moonbinlog.DecodeError::IncompleteTransaction(..) => ()
      other => fail("unexpected incomplete error: \{Repr(other)}")
    } noraise {
      _ => fail("unfinished transaction committed")
    }
    // A failed scanner is invalidated rather than recovering pending changes.
    scanner.finish()
  }
  for data in [mysql_crc32_full, mysql_off_full] {
    let source = mysql_events(data)
    let scanner = cli_tx_scanner()
    let events = cli_synthetic_events(tx_begin)
    for event in events {
      scanner.feed(event) |> ignore
    }
    try scanner.feed(source[2]) catch {
      @moonbinlog.DecodeError::UnsupportedTransactionEvent(..) => ()
      other => fail("active envelope skipped: \{Repr(other)}")
    } noraise {
      _ => fail("active envelope accepted")
    }
  }
}

///|
test "CLI transactions reject missing BEGIN unsupported SQL and unknown idle events" {
  for
    stream in [
      tm_row_image, rows_write_end, tx_commit, tx_false_commit, tx_unknown,
    ] {
    let scanner = cli_tx_scanner()
    try cli_tx_run(scanner, cli_synthetic_events(stream)) catch {
      @moonbinlog.DecodeError::InvalidTransactionState(..)
      | @moonbinlog.DecodeError::UnsupportedTransactionStatement(..)
      | @moonbinlog.DecodeError::UnsupportedTransactionEvent(..) => ()
      other => fail("unexpected rejection: \{Repr(other)}")
    } noraise {
      _ => fail("invalid transaction accepted")
    }
  }
}

///|
test "CLI transactions fail schema binding before accepting pending changes" {
  let empty = @moonbinlog.SchemaConfig::parse(
    "{\"schema_version\":1,\"tables\":[]}",
  )
  let scanner = @cli.TransactionScanner::new(empty)
  let events = cli_synthetic_events(tx_stream_commit)
  scanner.feed(events[0]) |> ignore
  scanner.feed(events[1]) |> ignore
  try scanner.feed(events[2]) catch {
    @moonbinlog.SchemaError::MissingTableSchema(..) => ()
    other => fail("unexpected schema error: \{Repr(other)}")
  } noraise {
    _ => fail("missing schema accepted")
  }
  try scanner.feed(events[4]) catch {
    @moonbinlog.DecodeError::InvalidTransactionState(..) => ()
    other => fail("failed schema retained transaction: \{Repr(other)}")
  } noraise {
    _ => fail("failed schema transaction committed")
  }
}

///|
test "CLI transactions enforce event change and wire byte budgets" {
  for
    scanner in [
      cli_tx_scanner(max_events=3),
      cli_tx_scanner(max_changes=1),
      cli_tx_scanner(max_bytes=50),
    ] {
    try cli_tx_run(scanner, cli_synthetic_events(tx_stream_two_rows)) catch {
      @moonbinlog.DecodeError::TransactionLimitExceeded(..) => ()
      other => fail("unexpected quota error: \{Repr(other)}")
    } noraise {
      _ => fail("transaction budget exceeded")
    }
    scanner.finish()
  }
}
