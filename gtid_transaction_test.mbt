// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn gtx_prefix(name~ : String = "base") -> Bytes raise {
  for (label, crc, _, _) in gtid_valid() {
    if label == name {
      return crc
    }
  }
  fail("missing GTID fixture")
}

///|
fn gtx_decoder(
  max_events~ : Int32 = 4096,
  max_changes~ : Int32 = 10000,
  max_bytes~ : UInt64 = 67108864,
) -> @moonbinlog.GtidTransactionDecoder raise {
  let format = @moonbinlog.FormatDescription::parse(
    gtid_fde_crc32,
    file_offset=4,
  )
  @moonbinlog.GtidTransactionDecoder::new(
    format,
    max_events~,
    max_changes~,
    max_bytes~,
  )
}

///|
fn gtx_run(
  decoder : @moonbinlog.GtidTransactionDecoder,
  data : BytesView,
  file_offset~ : UInt64 = 4,
) -> Array[@moonbinlog.GtidTransactionOutcome] raise {
  let outcomes = []
  let mut position = 0
  while position < data.length() {
    let step = decoder.feed(
      data[position:],
      file_offset=file_offset + position.reinterpret_as_uint().to_uint64(),
      integer_unsigned=row_image_signs(),
    )
    if step.outcome is Some(value) {
      outcomes.push(value)
    }
    position += step.header.event_size.reinterpret_as_int()
  }
  assert_eq(position, data.length())
  outcomes
}

///|
fn gtx_pending(
  decoder : @moonbinlog.GtidTransactionDecoder,
  raw : BytesView,
  offset : UInt64,
) -> UInt64 raise {
  let step = decoder.feed(
    raw,
    file_offset=offset,
    integer_unsigned=row_image_signs(),
  )
  assert_eq(step.outcome, None)
  assert_true(decoder.is_active())
  offset + step.header.event_size.to_uint64()
}

///|
fn gtx_failed(decoder : @moonbinlog.GtidTransactionDecoder) -> Unit raise {
  assert_false(decoder.is_active())
  try decoder.feed(gtx_prefix(), file_offset=4) catch {
    @moonbinlog.GtidTransactionFailed => ()
    other => fail("failed GTID decoder recovered: \{Repr(other)}")
  } noraise {
    _ => fail("failed GTID decoder accepted input")
  }
  try decoder.finish() catch {
    GtidTransactionFailed => ()
    other => fail("failed GTID decoder finished: \{Repr(other)}")
  } noraise {
    _ => fail("failed GTID decoder reported successful EOF")
  }
}

///|
fn gtx_error(
  decoder : @moonbinlog.GtidTransactionDecoder,
  raw : BytesView,
  offset : UInt64,
) -> @moonbinlog.DecodeError raise {
  try
    decoder.feed(raw, file_offset=offset, integer_unsigned=row_image_signs())
  catch {
    error => {
      gtx_failed(decoder)
      error
    }
  } noraise {
    _ => fail("invalid GTID span accepted")
  }
}

///|
test "GTID transactions bind all assigned anonymous extensions under CRC32 and OFF" {
  for (_, crc, off, expected) in gtid_valid() {
    for
      (prefix, stream, format_bytes) in [
        (crc, tx_stream_commit, gtid_fde_crc32),
        (off, tx_stream_off, gtid_fde_off),
      ] {
      let format = @moonbinlog.FormatDescription::parse(
        format_bytes,
        file_offset=4,
      )
      let decoder = @moonbinlog.GtidTransactionDecoder::new(format)
      let outcomes = gtx_run(decoder, prefix + stream, file_offset=500)
      assert_eq(outcomes.length(), 1)
      let value = outcomes[0]
      gtid_assert(value.gtid, expected)
      assert_eq(value.start_offset, 500UL)
      assert_eq(
        value.end_offset,
        500UL +
        (prefix.length() + stream.length()).reinterpret_as_uint().to_uint64(),
      )
      assert_eq(value.event_count, 5)
      assert_eq(
        value.wire_bytes,
        (prefix.length() + stream.length()).reinterpret_as_uint().to_uint64(),
      )
      guard value.transaction is Committed(transaction) else {
        fail("expected commit")
      }
      assert_eq(
        transaction.start_offset,
        500UL + prefix.length().reinterpret_as_uint().to_uint64(),
      )
      assert_eq(transaction.end_offset, value.end_offset)
      assert_eq(transaction.event_count, 4)
      assert_eq(transaction.change_count, 1)
      assert_eq(transaction.events.length(), 1)
      assert_eq(
        transaction.wire_bytes + value.gtid.header.event_size.to_uint64(),
        value.wire_bytes,
      )
      assert_false(decoder.is_active())
      decoder.finish()
    }
  }
}

///|
test "GTID transactions expose no outcome before terminal boundary including statement end" {
  let decoder = gtx_decoder()
  assert_false(decoder.is_active())
  let next = gtx_pending(decoder, gtx_prefix(), 4)
  let next = gtx_pending(decoder, tx_begin, next)
  let next = gtx_pending(decoder, tm_row_image, next)
  let next = gtx_pending(decoder, rows_write_end, next)
  guard decoder.feed(tx_xid, file_offset=next).outcome is Some(value) else {
    fail("missing completion")
  }
  assert_true(value.transaction is Committed(tx) && tx.change_count == 1)
  assert_eq(value.gtid.gno, 1UL)
  assert_eq(value.event_count, 5)
}

///|
test "GTID transactions clear association after commit rollback and preserve prior snapshots" {
  let decoder = gtx_decoder()
  let first = gtx_run(decoder, gtx_prefix() + tx_stream_commit)[0]
  let second = gtx_run(
      decoder,
      gtx_prefix(name="anonymous") + tx_stream_rollback,
      file_offset=first.end_offset,
    )[0]
  assert_true(second.gtid.is_anonymous())
  assert_eq(second.gtid.gno, 0UL)
  assert_eq(second.start_offset, first.end_offset)
  assert_true(second.transaction is RolledBack(discarded_changes=1, ..))
  assert_eq(second.event_count, 5)
  assert_eq(
    second.wire_bytes,
    (gtx_prefix(name="anonymous").length() + tx_stream_rollback.length())
    .reinterpret_as_uint()
    .to_uint64(),
  )
  let third = gtx_run(
      decoder,
      gtx_prefix() + tx_stream_two_statements,
      file_offset=second.end_offset,
    )[0]
  assert_false(third.gtid.is_anonymous())
  assert_eq(third.gtid.gno, first.gtid.gno) // Association does not deduplicate GTIDs.
  assert_true(
    third.transaction is Committed(tx) && tx.xid is None && tx.change_count == 3,
  )
  assert_true(
    first.transaction is Committed(tx) &&
    tx.events.length() == 1 &&
    tx.change_count == 1,
  )
  assert_eq(first, gtx_run(gtx_decoder(), gtx_prefix() + tx_stream_commit)[0])
  decoder.finish()
}

///|
test "GTID transactions support empty explicit commit XID rollback and idle EOF reuse" {
  let decoder = gtx_decoder()
  decoder.finish()
  let mut offset = 4UL
  for ending in [tx_commit, tx_xid, tx_rollback] {
    let bytes = gtx_prefix() + tx_begin + ending
    let value = gtx_run(decoder, bytes, file_offset=offset)[0]
    assert_eq(value.event_count, 3)
    assert_eq(value.start_offset, offset)
    assert_eq(
      value.end_offset,
      offset + bytes.length().reinterpret_as_uint().to_uint64(),
    )
    match value.transaction {
      Committed(tx) => {
        assert_eq(tx.change_count, 0)
        assert_eq(tx.events.length(), 0)
        assert_eq(tx.event_count, 2)
      }
      RolledBack(discarded_changes=0, ..) => ()
      _ => fail("unexpected empty span outcome")
    }
    decoder.finish()
    offset = value.end_offset
  }
}

///|
test "GTID transactions reject missing BEGIN duplicate prefixes nested BEGIN and envelopes" {
  assert_true(
    gtx_error(gtx_decoder(), tx_begin, 4) is InvalidGtidTransactionState(..),
  )
  for
    raw in [
      gtx_prefix(),
      tx_commit,
      tx_xid,
      tm_row_image,
      tx_unknown,
      gtid_fde_crc32,
    ] {
    let decoder = gtx_decoder()
    let next = gtx_pending(decoder, gtx_prefix(), 4)
    ignore(gtx_error(decoder, raw, next))
  }
  for raw in [gtx_prefix(), tx_begin, tx_unknown, rotate_start, gtid_fde_crc32] {
    let decoder = gtx_decoder()
    let next = gtx_pending(decoder, gtx_prefix(), 4)
    let next = gtx_pending(decoder, tx_begin, next)
    ignore(gtx_error(decoder, raw, next))
  }
}

///|
test "GTID transactions reject offset gaps overlaps duplicates and UInt64 range overflow" {
  for delta in [-1, 0, 1] {
    let decoder = gtx_decoder()
    let next = gtx_pending(decoder, gtx_prefix(), 500)
    let invalid = if delta == 0 {
      500UL
    } else if delta < 0 {
      next - 1
    } else {
      next + 1
    }
    assert_true(
      gtx_error(decoder, tx_begin, invalid) is InvalidGtidTransactionState(..),
    )
  }
  let decoder = gtx_decoder()
  let next = gtx_pending(decoder, gtx_prefix(), 4)
  let next = gtx_pending(decoder, tx_begin, next)
  assert_true(
    gtx_error(decoder, tm_row_image, next + 1)
    is InvalidGtidTransactionState(..),
  )
  assert_true(
    gtx_error(gtx_decoder(), gtx_prefix(), 0xffffffffffffffff)
    is InvalidGtidTransactionState(..),
  )
  let decoder = gtx_decoder()
  let prefix = gtx_prefix()
  let next = gtx_pending(
    decoder,
    prefix,
    0xffffffffffffffffUL - prefix.length().reinterpret_as_uint().to_uint64(),
  )
  assert_eq(next, 0xffffffffffffffffUL)
  assert_true(
    gtx_error(decoder, tx_begin, next) is InvalidGtidTransactionState(..),
  )
}

///|
test "GTID transactions EOF discards both lone prefix and buffered rows and permanently fails" {
  for buffered in [false, true] {
    let decoder = gtx_decoder()
    let next = gtx_pending(decoder, gtx_prefix(), 500)
    if buffered {
      let next = gtx_pending(decoder, tx_begin, next)
      let next = gtx_pending(decoder, tm_row_image, next)
      ignore(gtx_pending(decoder, rows_write_end, next))
    }
    try decoder.finish() catch {
      IncompleteGtidTransaction(start_offset=500) => ()
      other => fail("unexpected GTID EOF error: \{Repr(other)}")
    } noraise {
      _ => fail("unfinished GTID span accepted")
    }
    gtx_failed(decoder)
  }
}

///|
test "GTID transactions invalid prefix CRC malformed rows and truncated input fail closed" {
  for (_, raw) in gtid_invalid() {
    ignore(gtx_error(gtx_decoder(), raw, 4))
  }
  assert_true(gtx_error(gtx_decoder(), gtid_bad_crc, 4) is ChecksumMismatch(..))
  for
    raw in [tx_bad_crc, tx_xid_short, tx_begin[:5].to_owned(), tx_false_commit] {
    let decoder = gtx_decoder()
    let next = gtx_pending(decoder, gtx_prefix(), 4)
    let next = gtx_pending(decoder, tx_begin, next)
    let next = gtx_pending(decoder, tm_row_image, next)
    let next = gtx_pending(decoder, rows_write_end, next)
    ignore(gtx_error(decoder, raw, next))
  }
  let decoder = gtx_decoder()
  let next = gtx_pending(decoder, gtx_prefix(), 4)
  let next = gtx_pending(decoder, tx_begin, next)
  assert_true(gtx_error(decoder, rows_write_end, next) is MissingTableMap(..))
  for raw in [rows_wrong_count, rows_short_body, rows_extra_too_long] {
    let decoder = gtx_decoder()
    let next = gtx_pending(decoder, gtx_prefix(), 4)
    let next = gtx_pending(decoder, tx_begin, next)
    let next = gtx_pending(decoder, tm_row_image, next)
    ignore(gtx_error(decoder, raw, next))
  }
  let decoder = gtx_decoder()
  let next = gtx_pending(decoder, gtx_prefix(), 4)
  let next = gtx_pending(decoder, tx_begin, next)
  let next = gtx_pending(decoder, tm_row_image, next)
  try decoder.feed(rows_write_end, file_offset=next) catch {
    _ => gtx_failed(decoder)
  } noraise {
    _ => fail("missing integer signedness accepted")
  }
}

///|
test "GTID transactions quotas include prefix and terminal with exact event byte limits" {
  let bytes = gtx_prefix() + tx_begin + tx_commit
  let size = bytes.length().reinterpret_as_uint().to_uint64()
  assert_eq(
    gtx_run(gtx_decoder(max_events=3, max_bytes=size), bytes)[0].wire_bytes,
    size,
  )
  for (max_events, max_bytes) in [(2, size), (3, size - 1)] {
    let decoder = gtx_decoder(max_events~, max_bytes~)
    let next = gtx_pending(decoder, gtx_prefix(), 4)
    let next = gtx_pending(decoder, tx_begin, next)
    assert_true(
      gtx_error(decoder, tx_commit, next) is TransactionLimitExceeded(..),
    )
  }
  assert_true(
    gtx_error(gtx_decoder(max_bytes=1), gtx_prefix(), 4)
    is TransactionLimitExceeded(..),
  )
  let decoder = gtx_decoder(max_changes=1)
  let next = gtx_pending(decoder, gtx_prefix(), 4)
  let next = gtx_pending(decoder, tx_begin, next)
  let next = gtx_pending(decoder, tm_row_image, next)
  assert_true(
    gtx_error(decoder, rows_write_two, next) is TransactionLimitExceeded(..),
  )
  let value = gtx_run(
      gtx_decoder(max_changes=2),
      gtx_prefix() + tx_stream_two_rows,
    )[0]
  assert_true(value.transaction is Committed(tx) && tx.change_count == 2)
  for
    (max_events, max_changes, max_bytes) in [
      (0, 1, 1UL),
      (1, 0, 1UL),
      (1, 1, 0UL),
    ] {
    try gtx_decoder(max_events~, max_changes~, max_bytes~) catch {
      @moonbinlog.InvalidTransactionLimits(..) => ()
      other => fail("unexpected GTID limit config: \{Repr(other)}")
    } noraise {
      _ => fail("invalid GTID limits accepted")
    }
  }
}

///|
test "GTID transactions six real anonymous spans match standalone rows and official prefix metadata" {
  for (data, prefix_offset, expected) in gtid_real_oracles() {
    let events = mysql_events(data)
    let decoder = @moonbinlog.GtidTransactionDecoder::new(events[0].format)
    let plain = @moonbinlog.TransactionDecoder::new(events[0].format)
    let mut signs = mysql_signs
    let mut count = 0
    for event in events {
      if event.header.event_type == 19 {
        let table = @moonbinlog.TableMap::parse(
          event.format,
          event.raw,
          file_offset=event.header.file_offset,
        )
        if table.columns.length() == 2 {
          signs = [Some(false), None]
        }
      }
      if event.header.event_type == 33 || event.header.event_type == 34 {
        assert_eq(
          decoder.feed(event.raw, file_offset=event.header.file_offset).outcome,
          None,
        )
      } else if decoder.is_active() {
        let original = plain.feed(
          event.raw,
          file_offset=event.header.file_offset,
          integer_unsigned=signs,
        )
        let step = decoder.feed(
          event.raw,
          file_offset=event.header.file_offset,
          integer_unsigned=signs,
        )
        if step.outcome is Some(value) {
          assert_eq(Some(value.transaction), original.outcome)
          gtid_assert(value.gtid, expected)
          assert_eq(value.start_offset, prefix_offset)
          assert_eq(value.end_offset - value.start_offset, value.wire_bytes)
          guard value.transaction is Committed(transaction) else {
            fail("real span is not a commit")
          }
          assert_eq(value.event_count, transaction.event_count + 1)
          assert_eq(
            value.wire_bytes,
            transaction.wire_bytes + value.gtid.header.event_size.to_uint64(),
          )
          count += 1
        } else {
          assert_eq(original.outcome, None)
        }
      }
    }
    assert_eq(count, 1)
    decoder.finish()
    plain.finish()
  }
}
