// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn filter_scanner(filter : @cli.TableFilter) -> @cli.TransactionScanner raise {
  @cli.TransactionScanner::new(
    cli_row_schema(row_image_table(), row_image_signs()),
    filter~,
  )
}

///|
fn filter_outcomes(
  stream : Bytes,
  filter : @cli.TableFilter,
) -> Array[Bool] raise {
  let scanner = filter_scanner(filter)
  let selected = []
  assert_false(scanner.outcome_selected())
  for event in cli_synthetic_events(stream) {
    if scanner.feed(event) is Some(_) {
      selected.push(scanner.outcome_selected())
    } else {
      assert_false(scanner.outcome_selected())
    }
  }
  scanner.finish()
  selected
}

///|
test "CLI filter selects complete commit rollback spans only when ROWS match" {
  let orders = @cli.TableFilter::{
    database: Some("shop"),
    table: Some("orders"),
  }
  let absent = @cli.TableFilter::{ database: None, table: Some("other"), }
  for stream in [tx_stream_commit, tx_stream_rollback, tx_stream_two_statements] {
    assert_eq(filter_outcomes(stream, orders), [true])
    assert_eq(filter_outcomes(stream, absent), [false])
  }
  for stream in [tx_begin + tx_commit, tx_begin + tm_row_image + tx_rollback] {
    assert_eq(filter_outcomes(stream, orders), [false])
    assert_eq(filter_outcomes(stream, @cli.TableFilter::all()), [true])
  }
}

///|
test "CLI filter selection resets after commit rollback and idle format changes" {
  let filter = @cli.TableFilter::{ database: None, table: Some("orders"), }
  assert_eq(
    filter_outcomes(
      tx_stream_commit +
      tx_begin +
      tx_commit +
      tx_stream_rollback +
      tx_begin +
      tx_rollback,
      filter,
    ),
    [true, false, true, false],
  )
  assert_eq(
    filter_outcomes(tx_stream_commit + fde_crc32 + tx_begin + tx_commit, filter),
    [true, false],
  )
}

///|
test "CLI filter never suppresses invalid unselected transactions or EOF errors" {
  let filter = @cli.TableFilter::{ database: None, table: Some("absent"), }
  let scanner = filter_scanner(filter)
  try cli_tx_run(scanner, cli_synthetic_events(tx_stream_unknown)) catch {
    @moonbinlog.DecodeError::UnsupportedTransactionEvent(..) => ()
    other => fail("unexpected rejection: \{Repr(other)}")
  } noraise {
    _ => fail("unselected unknown event skipped")
  }
  assert_false(scanner.outcome_selected())
  let scanner = filter_scanner(filter)
  try cli_tx_run(scanner, cli_synthetic_events(tx_stream_unfinished)) catch {
    @moonbinlog.DecodeError::IncompleteTransaction(..) => ()
    other => fail("unexpected EOF rejection: \{Repr(other)}")
  } noraise {
    _ => fail("unselected unfinished transaction skipped")
  }
  assert_false(scanner.outcome_selected())
  let scanner = @cli.TransactionScanner::new(
    cli_row_schema(row_image_table(), row_image_signs()),
    filter~,
    max_events=3,
  )
  try cli_tx_run(scanner, cli_synthetic_events(tx_stream_commit)) catch {
    @moonbinlog.DecodeError::TransactionLimitExceeded(..) => ()
    other => fail("unexpected budget rejection: \{Repr(other)}")
  } noraise {
    _ => fail("unselected over-budget transaction skipped")
  }
  assert_false(scanner.outcome_selected())
}

///|
test "CLI filter keeps every real transaction decoded with original row snapshots" {
  for data in [mysql_crc32_full, mysql_crc32_minimal, mysql_off_full] {
    let events = mysql_events(data)
    let table = @moonbinlog.TableMap::parse(
      events[4].format,
      events[4].raw,
      file_offset=events[4].header.file_offset,
    )
    let schema = cli_row_schema(table, mysql_signs)
    for (name, selected) in [("sample", true), ("Sample", false)] {
      let scanner = @cli.TransactionScanner::new(schema, filter={
        database: None,
        table: Some(name),
      })
      let mut completed = 0
      for event in events {
        if scanner.feed(event) is Some(Committed(transaction)) {
          assert_eq(scanner.outcome_selected(), selected)
          assert_eq(transaction.change_count, 4)
          assert_eq(transaction.events.length(), 4)
          completed += 1
        }
      }
      assert_eq(completed, 1)
      scanner.finish()
    }
  }
}
