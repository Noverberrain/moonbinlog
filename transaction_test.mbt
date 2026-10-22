// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn tx_format() -> @moonbinlog.FormatDescription raise {
  @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
}

///|
fn tx_decoder() -> @moonbinlog.TransactionDecoder raise {
  @moonbinlog.TransactionDecoder::new(tx_format())
}

///|
fn tx_run(
  decoder : @moonbinlog.TransactionDecoder,
  stream : BytesView,
) -> Array[@moonbinlog.TransactionOutcome] raise {
  let outcomes = []
  let mut position = 0
  while position < stream.length() {
    let step = decoder.feed(
      stream[position:],
      file_offset=4 + position.reinterpret_as_uint().to_uint64(),
      integer_unsigned=row_image_signs(),
    )
    if step.outcome is Some(outcome) {
      outcomes.push(outcome)
    }
    position += step.header.event_size.reinterpret_as_int()
  }
  assert_eq(position, stream.length())
  outcomes
}

///|
fn tx_pending(
  decoder : @moonbinlog.TransactionDecoder,
  input : BytesView,
  offset : UInt64,
) -> UInt64 raise {
  let step = decoder.feed(
    input,
    file_offset=offset,
    integer_unsigned=row_image_signs(),
  )
  assert_eq(step.outcome, None)
  offset + step.header.event_size.to_uint64()
}

///|
fn tx_buffer_one(decoder : @moonbinlog.TransactionDecoder) -> UInt64 raise {
  let offset = tx_pending(decoder, tx_begin, 4)
  let offset = tx_pending(decoder, tm_row_image, offset)
  tx_pending(decoder, rows_write_end, offset)
}

///|
fn tx_error(
  decoder : @moonbinlog.TransactionDecoder,
  input : BytesView,
  offset : UInt64,
) -> @moonbinlog.DecodeError raise {
  try
    decoder.feed(input, file_offset=offset, integer_unsigned=row_image_signs())
  catch {
    err => {
      assert_false(decoder.is_active())
      err
    }
  } noraise {
    _ => fail("invalid transaction event was accepted")
  }
}

///|
test "transaction boundaries parse exact keywords whitespace case and UInt64 XIDs" {
  let format = tx_format()
  let cases : ReadOnlyArray[(Bytes, @moonbinlog.TransactionAction)] = [
    (tx_begin, Begin),
    (tx_begin_decorated, Begin),
    (tx_commit, Commit),
    (tx_commit_decorated, Commit),
    (tx_rollback, Rollback),
    (tx_rollback_decorated, Rollback),
    (tx_xid, Xid(0xfedcba9876543210)),
    (tx_xid_zero, Xid(0)),
  ]
  for (bytes, expected) in cases {
    let boundary = @moonbinlog.TransactionBoundary::parse(
      format,
      bytes,
      file_offset=500,
    )
    assert_eq(boundary.action, expected)
    assert_eq(boundary.header.file_offset, 500UL)
  }
}

///|
test "malformed QUERY XID status database and failed statements cannot form boundaries" {
  let format = tx_format()
  for
    bytes in [
      tx_xid_short, tx_xid_long, tx_query_short, tx_status_overrun, tx_database_terminator,
      tx_database_nul, tx_query_failed,
    ] {
    try
      @moonbinlog.TransactionBoundary::parse(format, bytes, file_offset=500)
    catch {
      InvalidTransactionEvent(file_offset~, ..) => assert_eq(file_offset, 500UL)
      other => fail("unexpected error: \{Repr(other)}")
    } noraise {
      _ => fail("malformed boundary accepted")
    }
  }
  for
    (format_bytes, input) in [
      (fde_tx_bad_query, tx_begin),
      (fde_tx_bad_xid, tx_xid),
    ] {
    let invalid_format = @moonbinlog.FormatDescription::parse(
      format_bytes,
      file_offset=4,
    )
    try
      @moonbinlog.TransactionBoundary::parse(
        invalid_format,
        input,
        file_offset=500,
      )
    catch {
      InvalidTransactionEvent(..) => ()
      other => fail("unexpected error: \{Repr(other)}")
    } noraise {
      _ => fail("inconsistent post-header accepted")
    }
  }
}

///|
test "embedded commit text multi-statements savepoints comments and chaining are never guessed" {
  let format = tx_format()
  for
    bytes in [
      tx_false_commit, tx_multi_query, tx_savepoint, tx_chain, tx_double_semicolon,
      tx_comment, tx_empty_sql, tx_nonascii,
    ] {
    try
      @moonbinlog.TransactionBoundary::parse(format, bytes, file_offset=500)
    catch {
      UnsupportedTransactionStatement(file_offset~) =>
        assert_eq(file_offset, 500UL)
      other => fail("unexpected error: \{Repr(other)}")
    } noraise {
      _ => fail("unsupported SQL interpreted as a boundary")
    }
  }
}

///|
test "transaction control checks every truncated prefix CRC and unsupported event types" {
  let format = tx_format()
  for bytes in [tx_begin, tx_xid] {
    for length in 0..<bytes.length() {
      try
        @moonbinlog.TransactionBoundary::parse(
          format,
          bytes[:length],
          file_offset=500,
        )
      catch {
        TruncatedInput(..) | TruncatedEvent(..) => ()
        other => fail("unexpected error: \{Repr(other)}")
      } noraise {
        _ => fail("truncated control accepted")
      }
    }
  }
  try
    @moonbinlog.TransactionBoundary::parse(format, tx_bad_crc, file_offset=500)
  catch {
    ChecksumMismatch(..) => ()
    other => fail("unexpected error: \{Repr(other)}")
  } noraise {
    _ => fail("bad control CRC accepted")
  }
  try
    @moonbinlog.TransactionBoundary::parse(
      format,
      rows_write_two,
      file_offset=500,
    )
  catch {
    UnsupportedTransactionEvent(..) => ()
    other => fail("unexpected error: \{Repr(other)}")
  } noraise {
    _ => fail("ROWS misread as control")
  }
}

///|
test "XID commit emits a complete immutable transaction with precise span and counters" {
  let decoder = tx_decoder()
  let outcomes = tx_run(decoder, tx_stream_commit)
  assert_eq(outcomes.length(), 1)
  match outcomes[0] {
    Committed(tx) => {
      assert_eq(tx.start_offset, 4UL)
      assert_eq(
        tx.end_offset,
        4UL + tx_stream_commit.length().reinterpret_as_uint().to_uint64(),
      )
      assert_eq(tx.xid, Some(0xfedcba9876543210UL))
      assert_eq(tx.event_count, 4)
      assert_eq(tx.change_count, 1)
      assert_eq(
        tx.wire_bytes,
        tx_stream_commit.length().reinterpret_as_uint().to_uint64(),
      )
      assert_eq(tx.events.length(), 1)
      assert_true(
        tx.events[0].changes[0] is Insert(row) &&
        row.columns[0] is Integer(Unsigned(0xffffffffffffffff)),
      )
    }
    _ => fail("expected commit")
  }
  assert_false(decoder.is_active())
  decoder.finish()
}

///|
test "ROWS statement end clears maps but does not expose or commit pending changes" {
  let decoder = tx_decoder()
  let next = tx_buffer_one(decoder)
  assert_true(decoder.is_active())
  let step = decoder.feed(tx_xid, file_offset=next)
  assert_true(step.outcome is Some(Committed(tx)) && tx.change_count == 1)
  assert_false(decoder.is_active())
}

///|
test "ROLLBACK discards buffered rows and returns only the discarded-change count" {
  let decoder = tx_decoder()
  let outcomes = tx_run(decoder, tx_stream_rollback)
  assert_eq(outcomes.length(), 1)
  assert_true(
    outcomes[0] is RolledBack(start_offset=4, end_offset~, discarded_changes=1) &&
    end_offset ==
    4UL + tx_stream_rollback.length().reinterpret_as_uint().to_uint64(),
  )
  assert_false(decoder.is_active())
  decoder.finish()
}

///|
test "multiple statements share one transaction while each statement rebuilds its table maps" {
  let decoder = tx_decoder()
  let outcomes = tx_run(decoder, tx_stream_two_statements)
  match outcomes[0] {
    Committed(tx) => {
      assert_eq(tx.xid, None)
      assert_eq(tx.event_count, 6)
      assert_eq(tx.change_count, 3)
      assert_eq(tx.events.length(), 2)
      assert_true(tx.events[0].changes[0] is Insert(_))
      assert_true(tx.events[1].changes[0] is Delete(_))
    }
    _ => fail("expected commit")
  }
}

///|
test "committed snapshots survive subsequent transactions and pending-array reuse" {
  let decoder = tx_decoder()
  let outcomes = tx_run(decoder, tx_stream_two_transactions)
  assert_eq(outcomes.length(), 2)
  for outcome in outcomes {
    match outcome {
      Committed(tx) => {
        assert_eq(tx.events.length(), 1)
        assert_eq(tx.change_count, 1)
        assert_eq(tx.events[0].table.table, "orders")
        assert_true(
          tx.events[0].changes[0] is Insert(row) &&
          row.columns[14] is EnumSet(EnumIndex(256)),
        )
      }
      _ => fail("expected commit")
    }
  }
}

///|
test "EOF discards an unfinished transaction and prevents a later commit from reviving it" {
  let decoder = tx_decoder()
  assert_eq(tx_run(decoder, tx_stream_unfinished).length(), 0)
  assert_true(decoder.is_active())
  try decoder.finish() catch {
    IncompleteTransaction(start_offset~) => assert_eq(start_offset, 4UL)
    other => fail("unexpected error: \{Repr(other)}")
  } noraise {
    _ => fail("unfinished transaction silently accepted")
  }
  assert_false(decoder.is_active())
  assert_true(tx_error(decoder, tx_commit, 1000) is InvalidTransactionState(..))
  assert_eq(tx_run(decoder, tx_stream_commit).length(), 1)
}

///|
test "rows maps commit and rollback outside BEGIN and nested BEGIN fail without partial output" {
  for packet in [tm_row_image, rows_write_two, tx_commit, tx_rollback, tx_xid] {
    assert_true(
      tx_error(tx_decoder(), packet, 4) is InvalidTransactionState(..),
    )
  }
  let decoder = tx_decoder()
  let next = tx_pending(decoder, tx_begin, 4)
  assert_true(tx_error(decoder, tx_begin, next) is InvalidTransactionState(..))
  assert_true(tx_error(decoder, tx_xid, next) is InvalidTransactionState(..))
}

///|
test "physical gaps overlaps and duplicate offsets discard the active span" {
  for delta in [-1, 0, 1] {
    let decoder = tx_decoder()
    let next = tx_pending(decoder, tx_begin, 4)
    let bad = if delta == -1 {
      next - 1
    } else if delta == 0 {
      4
    } else {
      next + 1
    }
    assert_true(
      tx_error(decoder, tm_row_image, bad) is InvalidTransactionState(..),
    )
  }
}

///|
test "unknown events and unsupported SQL abort buffered transactions instead of being skipped" {
  let decoder = tx_decoder()
  try tx_run(decoder, tx_stream_unknown) catch {
    @moonbinlog.DecodeError::UnsupportedTransactionEvent(..) =>
      assert_false(decoder.is_active())
    other => fail("unexpected error: \{Repr(other)}")
  } noraise {
    _ => fail("unknown event was skipped")
  }
  for packet in [tx_savepoint, tx_multi_query, rows_partial] {
    let scope = tx_decoder()
    let next = tx_buffer_one(scope)
    let err = tx_error(scope, packet, next)
    assert_true(
      err is UnsupportedTransactionStatement(..) ||
      err is UnsupportedTransactionEvent(..),
    )
    assert_true(tx_error(scope, tx_commit, next) is InvalidTransactionState(..))
  }
}

///|
test "CRC failures and missing statement maps discard previously buffered rows" {
  let decoder = tx_decoder()
  let next = tx_buffer_one(decoder)
  assert_true(tx_error(decoder, rows_bad_crc, next) is ChecksumMismatch(..))
  assert_true(tx_error(decoder, tx_commit, next) is InvalidTransactionState(..))
  let scope = tx_decoder()
  let next = tx_buffer_one(scope)
  assert_true(tx_error(scope, rows_write_two, next) is MissingTableMap(..))
}

///|
test "transaction event byte and cumulative change limits fail before any commit is returned" {
  let format = tx_format()
  for
    (events, changes, bytes, input) in [
      (3, 100, 100000UL, tx_stream_commit),
      (
        100,
        100,
        tx_stream_commit.length().reinterpret_as_uint().to_uint64() - 1,
        tx_stream_commit,
      ),
      (100, 1, 100000UL, tx_stream_two_rows),
      (100, 2, 100000UL, tx_stream_two_statements),
    ] {
    let decoder = @moonbinlog.TransactionDecoder::new(
      format,
      max_events=events,
      max_changes=changes,
      max_bytes=bytes,
    )
    try tx_run(decoder, input) catch {
      @moonbinlog.DecodeError::TransactionLimitExceeded(..) =>
        assert_false(decoder.is_active())
      other => fail("unexpected error: \{Repr(other)}")
    } noraise {
      _ => fail("transaction quota ignored")
    }
  }
  let exact = @moonbinlog.TransactionDecoder::new(
    format,
    max_events=4,
    max_changes=1,
    max_bytes=tx_stream_commit.length().reinterpret_as_uint().to_uint64(),
  )
  assert_eq(tx_run(exact, tx_stream_commit).length(), 1)
}

///|
test "invalid transaction limit configurations fail and UInt64 byte caps do not wrap" {
  let format = tx_format()
  for
    (events, changes, bytes) in [
      (0, 1, 1UL),
      (-1, 1, 1UL),
      (1, 0, 1UL),
      (1, -1, 1UL),
      (1, 1, 0UL),
    ] {
    try
      @moonbinlog.TransactionDecoder::new(
        format,
        max_events=events,
        max_changes=changes,
        max_bytes=bytes,
      )
    catch {
      InvalidTransactionLimits(..) => ()
      other => fail("unexpected error: \{Repr(other)}")
    } noraise {
      _ => fail("invalid quotas accepted")
    }
  }
  let decoder = @moonbinlog.TransactionDecoder::new(
    format,
    max_bytes=0xffffffffffffffff,
  )
  assert_eq(tx_run(decoder, tx_stream_commit).length(), 1)
}

///|
test "empty committed or rolled-back transactions do not invent row events" {
  for ending in [tx_commit, tx_xid_zero, tx_rollback] {
    let decoder = tx_decoder()
    let next = tx_pending(decoder, tx_begin, 4)
    let step = decoder.feed(ending, file_offset=next)
    match step.outcome {
      Some(Committed(tx)) => {
        assert_eq(tx.events.length(), 0)
        assert_eq(tx.change_count, 0)
        assert_eq(tx.event_count, 2)
      }
      Some(RolledBack(discarded_changes=0, ..)) => ()
      _ => fail("missing empty transaction outcome")
    }
    decoder.finish()
  }
}

///|
test "OFF checksum policy works across the entire transaction stream" {
  let format = @moonbinlog.FormatDescription::parse(fde_off, file_offset=4)
  let decoder = @moonbinlog.TransactionDecoder::new(format)
  let outcomes = tx_run(decoder, tx_stream_off)
  assert_true(
    outcomes[0] is Committed(tx) && tx.xid == Some(0) && tx.change_count == 1,
  )
}

///|
test "physical offsets rather than header next_position drive continuity and trailing boundaries" {
  let decoder = tx_decoder()
  let first = decoder.feed(tx_begin + tm_row_image, file_offset=500)
  assert_eq(first.header.event_size, tx_begin.length().reinterpret_as_uint())
  let next = 500UL + first.header.event_size.to_uint64()
  let next = tx_pending(decoder, tm_row_image, next)
  let next = tx_pending(decoder, rows_write_end, next)
  let committed = decoder.feed(tx_commit + tx_unknown, file_offset=next)
  assert_true(
    committed.outcome is Some(Committed(tx)) &&
    tx.start_offset == 500 &&
    tx.events.length() == 1,
  )
  assert_false(decoder.is_active())
  assert_true(
    tx_error(decoder, tx_begin, 0xffffffffffffffff)
    is InvalidTransactionEvent(..),
  )
}

///|
test "transaction change counts treat each UPDATE pair as a single change" {
  let decoder = @moonbinlog.TransactionDecoder::new(tx_format(), max_changes=2)
  let outcomes = tx_run(decoder, tx_stream_updates)
  assert_true(
    outcomes[0] is Committed(tx) &&
    tx.change_count == 2 &&
    tx.events[0].changes.length() == 2,
  )
}
