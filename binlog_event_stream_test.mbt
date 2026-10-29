// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
test "event stream matches in-memory traversal of nine real files and preserves snapshots" {
  let files = [
    mysql_crc32_full, mysql_crc32_minimal, mysql_off_full, mysql_json_crc32_full,
    mysql_json_crc32_minimal, mysql_json_off_full, mysql_gtid_crc32_full, mysql_gtid_crc32_minimal,
    mysql_gtid_off_full,
  ]
  for data in files {
    let memory = @moonbinlog.BinlogFileReader::new(data)
    let stream = @moonbinlog.BinlogEventStream::new(data[:4])
    let saved = []
    while memory.next() is Some(expected) {
      let pos = stream.position()
      let actual = stream.feed(data[pos.to_int():])
      assert_eq(actual, expected)
      assert_eq(actual.header.file_offset, pos)
      saved.push(actual)
    }
    assert_eq(
      stream.position(),
      data.length().reinterpret_as_uint().to_uint64(),
    )
    stream.finish()
    stream.finish()
    assert_eq(saved[0].header.event_type, (15 : Byte))
    assert_eq(
      saved[0].raw,
      data[4:4 + saved[0].header.event_size.reinterpret_as_int()],
    )
    try stream.feed(fde_crc32) catch {
      StreamAlreadyFinished(file_offset~) =>
        assert_eq(file_offset, stream.position())
      other => fail("unexpected finished stream error: \{Repr(other)}")
    } noraise {
      _ => fail("stream accepted data after finish")
    }
    assert_eq(stream.format(), Some(saved[saved.length() - 1].format))
    stream.finish()
  }
}

///|
test "event stream validates signature first FDE limits and error state" {
  for size in 0..<4 {
    try @moonbinlog.BinlogEventStream::new(file_magic[:size]) catch {
      TruncatedInput(file_offset=0, expected=4, actual~) =>
        assert_eq(actual, size)
      other => fail("unexpected signature error: \{Repr(other)}")
    } noraise {
      _ => fail("short signature accepted")
    }
  }
  try @moonbinlog.BinlogEventStream::new(b"fail") catch {
    InvalidMagic(..) => ()
    other => fail("unexpected magic error: \{Repr(other)}")
  } noraise {
    _ => fail("invalid magic accepted")
  }
  try @moonbinlog.BinlogEventStream::new(file_magic, max_event_size=18) catch {
    InvalidEventLimit(..) => ()
    other => fail("unexpected limit: \{Repr(other)}")
  } noraise {
    _ => fail("invalid limit accepted")
  }
  let empty = @moonbinlog.BinlogEventStream::new(file_magic)
  try empty.finish() catch {
    MissingFormatDescription(file_offset=4) => ()
    other => fail("unexpected EOF error: \{Repr(other)}")
  } noraise {
    _ => fail("missing FDE accepted")
  }
  try empty.finish() catch {
    FileReaderFailed(file_offset=4) => ()
    other => fail("unexpected failed state: \{Repr(other)}")
  } noraise {
    _ => fail("failed stream recovered")
  }
  let first = @moonbinlog.BinlogEventStream::new(file_magic)
  try first.feed(event_crc32) catch {
    MissingFormatDescription(file_offset=4) => ()
    other => fail("unexpected first event: \{Repr(other)}")
  } noraise {
    _ => fail("missing FDE accepted")
  }
  assert_eq(first.position(), 4UL)
  assert_eq(first.format(), None)
}

///|
test "event stream reports every truncation CRC failure and replacement FDE without advancing" {
  for size in 0..<event_crc32.length() {
    let stream = @moonbinlog.BinlogEventStream::new(file_magic)
    let first = stream.feed(fde_crc32)
    let position = stream.position()
    try stream.feed(event_crc32[:size]) catch {
      TruncatedInput(..) | TruncatedEvent(..) => ()
      other => fail("unexpected truncated event: \{Repr(other)}")
    } noraise {
      _ => fail("truncated event accepted")
    }
    assert_eq(stream.position(), position)
    assert_eq(stream.format(), None)
    assert_eq(first.raw, fde_crc32[:])
    try stream.feed(event_crc32) catch {
      FileReaderFailed(file_offset~) => assert_eq(file_offset, position)
      other => fail("unexpected retry error: \{Repr(other)}")
    } noraise {
      _ => fail("failed stream reused")
    }
  }
  for bad in [tx_bad_crc, fde_bad_algorithm, fde_other_server, fde_bad_table] {
    let stream = @moonbinlog.BinlogEventStream::new(file_magic)
    stream.feed(fde_crc32) |> ignore
    try stream.feed(bad) catch {
      _ => ()
    } noraise {
      _ => fail("bad event accepted")
    }
    assert_eq(stream.format(), None)
    assert_eq(stream.position(), 126UL)
  }
}

///|
test "event stream context switches and ignores bytes after each declared event" {
  let stream = @moonbinlog.BinlogEventStream::new(file_magic)
  let first = stream.feed(fde_crc32 + fde_off)
  assert_eq(
    stream.position(),
    4UL + fde_crc32.length().reinterpret_as_uint().to_uint64(),
  )
  assert_eq(first.format.checksum_algorithm, Crc32)
  let second = stream.feed(fde_off + event_off)
  assert_eq(second.format.checksum_algorithm, Off)
  let third = stream.feed(event_off + b"tail")
  assert_eq(third.body, event_off[19:])
  assert_eq(first.raw, fde_crc32[:])
  assert_eq(stream.format(), Some(second.format))
  stream.finish()
}
