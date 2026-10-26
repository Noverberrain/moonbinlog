// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
// Schema is fixtures/mysql-8.0/schema.sql; signedness is deliberately external.
let mysql_signs : ReadOnlyArray[Bool?] = [
  Some(false),
  Some(false),
  Some(false),
  Some(false),
  Some(true),
  None,
  None,
  None,
  None,
  None,
  None,
  None,
  None,
  None,
  None,
  None,
  None,
  None,
  None,
  None,
]

///|
// Canonicalize only for the fixture oracle; this is not a library export format.
fn mysql_cell_text(cell : @moonbinlog.RowCell) -> String {
  match cell {
    Absent => "ABSENT"
    Null => "NULL"
    Integer(Signed(value)) => value.to_string()
    Integer(Unsigned(value)) => value.to_string()
    StringBytes(value) | BlobBytes(value) => "hex:" + @hex.encode(value)
    JsonDocument(value) => "json:" + value.value.to_json_text()
    Decimal(value) => value.value
    Floating({ value: Single(value), .. }) => value.to_string()
    Floating({ value: DoublePrecision(value), .. }) => value.to_string()
    Bit(value) => value.value.to_string()
    EnumSet(EnumIndex(value)) => value.to_string()
    EnumSet(SetMask(value)) => value.to_string()
    Temporal({ value, .. }) =>
      match value {
        Year(year) => year.to_string()
        Date(year~, month~, day~) => "date:\{year},\{month},\{day}"
        DateTime(year~, month~, day~, hour~, minute~, second~, microsecond~) =>
          "datetime:\{year},\{month},\{day},\{hour},\{minute},\{second},\{microsecond}"
        Time(negative~, hour~, minute~, second~, microsecond~) => {
          let sign = if negative { "-" } else { "+" }
          "time:\{sign}\{hour},\{minute},\{second},\{microsecond}"
        }
        Timestamp(seconds~, microsecond~) =>
          "timestamp:\{seconds},\{microsecond}"
      }
  }
}

///|
fn mysql_events(data : BytesView) -> Array[@moonbinlog.BinlogFileEvent] raise {
  let reader = @moonbinlog.BinlogFileReader::new(data)
  let events = []
  while reader.next() is Some(event) {
    events.push(event)
  }
  assert_eq(reader.position(), data.length().reinterpret_as_uint().to_uint64())
  events
}

///|
fn mysql_verify(
  data : BytesView,
  offsets : ReadOnlyArray[UInt64],
  oracle : ReadOnlyArray[ReadOnlyArray[String]],
) -> @moonbinlog.CommittedTransaction raise {
  let events = mysql_events(data)
  assert_eq(events.length(), offsets.length())
  assert_eq(events[0].format.server_version, "8.0.43")
  let decoder = @moonbinlog.TransactionDecoder::new(events[0].format)
  let mut result = None
  for i, event in events {
    assert_eq(event.header.file_offset, offsets[i])
    // These fixture envelopes occur outside BEGIN..XID. No transaction event
    // is filtered; production GTID/rotation handling remains unimplemented.
    match event.header.event_type {
      15 | 35 | 34 | 4 => assert_false(decoder.is_active())
      _ => {
        let step = decoder.feed(
          event.raw,
          file_offset=event.header.file_offset,
          integer_unsigned=mysql_signs,
        )
        match step.outcome {
          Some(Committed(transaction)) => {
            assert_eq(result, None)
            result = Some(transaction)
          }
          Some(RolledBack(..)) =>
            fail("InnoDB rollback should not be logged here")
          None => assert_eq(result, None)
        }
      }
    }
  }
  decoder.finish()
  guard result is Some(transaction) else {
    fail("missing committed transaction")
  }
  assert_eq(transaction.event_count, 10)
  assert_eq(transaction.change_count, 4)
  assert_eq(transaction.events.length(), 4)
  assert_eq(transaction.start_offset, events[3].header.file_offset)
  assert_eq(transaction.end_offset, events[13].header.file_offset)
  assert_eq(
    transaction.wire_bytes,
    transaction.end_offset - transaction.start_offset,
  )
  assert_true(transaction.xid is Some(_))
  let images = []
  for event in transaction.events {
    assert_eq(event.table.database, "moonbinlog_fixture")
    assert_eq(event.table.table, "sample")
    assert_eq(event.table.columns.length(), 20)
    assert_true(event.table.optional_metadata.length() > 0)
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
  assert_eq(images.length(), oracle.length())
  for i, row in images {
    assert_eq(row.columns.length(), oracle[i].length())
    for j, cell in row.columns {
      assert_eq(mysql_cell_text(cell), oracle[i][j])
    }
  }
  transaction
}

///|
test "real MySQL CRC32 FULL matches official mysqlbinlog for every row cell" {
  let _ = mysql_verify(
    mysql_crc32_full, mysql_crc32_full_offsets, mysql_crc32_full_oracle,
  )
}

///|
test "real MySQL CRC32 MINIMAL matches official mysqlbinlog for every row cell" {
  let _ = mysql_verify(
    mysql_crc32_minimal, mysql_crc32_minimal_offsets, mysql_crc32_minimal_oracle,
  )
}

///|
test "real MySQL OFF FULL matches official mysqlbinlog for every row cell" {
  let _ = mysql_verify(
    mysql_off_full, mysql_off_full_offsets, mysql_off_full_oracle,
  )
}

///|
test "real MySQL MINIMAL distinguishes omitted insert columns and sparse updates from NULL" {
  let full = mysql_verify(
    mysql_crc32_full, mysql_crc32_full_offsets, mysql_crc32_full_oracle,
  )
  let minimal = mysql_verify(
    mysql_crc32_minimal, mysql_crc32_minimal_offsets, mysql_crc32_minimal_oracle,
  )
  guard full.events[1].changes[0] is Insert(full_nulls) else {
    fail("expected insert")
  }
  guard minimal.events[1].changes[0] is Insert(omitted) else {
    fail("expected insert")
  }
  for i in 1..<20 {
    assert_eq(full_nulls.columns[i], Null)
    assert_eq(omitted.columns[i], Absent)
  }
  guard minimal.events[2].changes[0] is Update(before~, after~) else {
    fail("expected update")
  }
  assert_eq(before.columns[0], Integer(Signed(1)))
  for i in 1..<20 {
    assert_eq(before.columns[i], Absent)
  }
  assert_eq(after.columns[0], Absent)
  assert_eq(after.columns[1], Absent)
  assert_eq(after.columns[5], StringBytes(b"\xe6\x9b\xb4\xe6\x96\xb0"))
}

///|
test "real MySQL file envelopes remain unsupported by transaction decoder" {
  let events = mysql_events(mysql_crc32_full)
  let decoder = @moonbinlog.TransactionDecoder::new(events[0].format)
  assert_eq(events[2].header.event_type, 34)
  try
    decoder.feed(events[2].raw, file_offset=events[2].header.file_offset)
  catch {
    UnsupportedTransactionEvent(event_type=34, ..) => ()
    other => fail("unexpected envelope error: \{Repr(other)}")
  } noraise {
    _ => fail("anonymous GTID was silently consumed")
  }
  assert_false(decoder.is_active())
}

///|
test "real MySQL corruption and truncated rotation fail file traversal" {
  let events = mysql_events(mysql_crc32_full)
  let corrupt_at = events[5].header.file_offset.to_int() + 19
  let bad = Bytes::makei(mysql_crc32_full.length(), i => {
    if i == corrupt_at {
      mysql_crc32_full[i] ^ 1
    } else {
      mysql_crc32_full[i]
    }
  })
  let reader = @moonbinlog.BinlogFileReader::new(bad)
  for _ in 0..<5 {
    let _ = reader.next()
  }
  try reader.next() catch {
    ChecksumMismatch(file_offset~, ..) =>
      assert_eq(file_offset, events[5].header.file_offset)
    other => fail("unexpected corruption error: \{Repr(other)}")
  } noraise {
    _ => fail("corrupt real event accepted")
  }
  let reader = @moonbinlog.BinlogFileReader::new(
    mysql_crc32_full[:mysql_crc32_full.length() - 1],
  )
  for _ in 0..<13 {
    let _ = reader.next()
  }
  try reader.next() catch {
    TruncatedEvent(file_offset~, ..) =>
      assert_eq(file_offset, events[13].header.file_offset)
    other => fail("unexpected truncation error: \{Repr(other)}")
  } noraise {
    _ => fail("truncated real rotation accepted")
  }
}
