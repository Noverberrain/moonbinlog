// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
let file_magic : Bytes = [0xfe, 0x62, 0x69, 0x6e]

///|
fn file_next(
  reader : @moonbinlog.BinlogFileReader,
) -> @moonbinlog.BinlogFileEvent raise {
  guard reader.next() is Some(event) else { fail("expected an event") }
  event
}

///|
fn file_error(
  reader : @moonbinlog.BinlogFileReader,
) -> @moonbinlog.DecodeError raise {
  let position = reader.position()
  let error = try reader.next() catch {
    error => error
  } noraise {
    _ => fail("invalid file accepted")
  }
  assert_eq(reader.position(), position)
  assert_eq(reader.format(), None)
  try reader.next() catch {
    FileReaderFailed(file_offset~) => assert_eq(file_offset, position)
    other => fail("unexpected retry error: \{Repr(other)}")
  } noraise {
    _ => fail("reader continued after error")
  }
  error
}

///|
test "file reader validates magic and event limit before traversal" {
  for length in 0..<4 {
    try @moonbinlog.BinlogFileReader::new(file_magic[:length]) catch {
      TruncatedInput(file_offset=0, expected=4, actual~) =>
        assert_eq(actual, length)
      other => fail("unexpected signature error: \{Repr(other)}")
    } noraise {
      _ => fail("truncated signature accepted")
    }
  }
  try @moonbinlog.BinlogFileReader::new([0xfe, 0x62, 0x69, 0]) catch {
    InvalidMagic(_) => ()
    other => fail("unexpected magic error: \{Repr(other)}")
  } noraise {
    _ => fail("invalid signature accepted")
  }
  try @moonbinlog.BinlogFileReader::new(file_magic, max_event_size=18) catch {
    InvalidEventLimit(max_event_size=18) => ()
    other => fail("unexpected limit error: \{Repr(other)}")
  } noraise {
    _ => fail("invalid limit accepted")
  }
}

///|
test "file reader requires a format description even for magic-only files" {
  for data in [file_magic, file_magic + event_crc32] {
    let reader = @moonbinlog.BinlogFileReader::new(data)
    assert_eq(reader.position(), 4UL)
    assert_eq(reader.format(), None)
    assert_eq(file_error(reader), MissingFormatDescription(file_offset=4))
  }
}

///|
test "file reader yields FDE and stable clean EOF" {
  let reader = @moonbinlog.BinlogFileReader::new(file_magic + fde_in_use)
  let event = file_next(reader)
  assert_eq(event.header.file_offset, 4UL)
  assert_eq(event.raw, fde_in_use[:])
  assert_eq(event.body, fde_in_use[19:fde_in_use.length() - 4])
  assert_eq(event.format.checksum_algorithm, Crc32)
  assert_eq(reader.format(), Some(event.format))
  assert_eq(reader.position(), 126UL)
  assert_eq(reader.next(), None)
  assert_eq(reader.next(), None)
  assert_eq(reader.position(), 126UL)
  assert_eq(reader.format(), Some(event.format))
}

///|
test "file reader advances by encoded size and ignores logical next positions" {
  let data = file_magic +
    fde_crc32 +
    event_crc32 +
    tx_unknown +
    empty_event_crc32
  let reader = @moonbinlog.BinlogFileReader::new(data)
  let mut offset = 4UL
  for bytes in [fde_crc32, event_crc32, tx_unknown, empty_event_crc32] {
    let event = file_next(reader)
    assert_eq(event.header.file_offset, offset)
    assert_eq(event.raw, bytes[:])
    offset += bytes.length().reinterpret_as_uint().to_uint64()
    assert_eq(reader.position(), offset)
  }
  assert_eq(reader.next(), None)
  assert_eq(offset, data.length().reinterpret_as_uint().to_uint64())
}

///|
test "file reader preserves unsupported bodies without semantic decoding" {
  let reader = @moonbinlog.BinlogFileReader::new(
    file_magic + fde_crc32 + tx_unknown,
  )
  let _ = file_next(reader)
  let event = file_next(reader)
  assert_eq(event.header.event_type, 29)
  assert_eq(event.body, b"ignored?"[:])
  assert_eq(reader.next(), None)
  // Even code 255, outside the FDE type table, is retained in OFF mode.
  let unknown = Bytes::makei(empty_event_off.length(), i => {
    if i == 4 {
      255
    } else {
      empty_event_off[i]
    }
  })
  let reader = @moonbinlog.BinlogFileReader::new(file_magic + fde_off + unknown)
  let _ = file_next(reader)
  let event = file_next(reader)
  assert_eq(event.header.event_type, 255)
  assert_eq(event.body.length(), 0)
  assert_eq(reader.next(), None)
}

///|
test "file reader OFF preserves all trailing body bytes" {
  let reader = @moonbinlog.BinlogFileReader::new(
    file_magic + fde_off + event_off,
  )
  let _ = file_next(reader)
  let event = file_next(reader)
  assert_eq(event.body, event_off[19:])
  assert_eq(event.body.length(), 8)
  assert_eq(event.format.checksum_algorithm, Off)
  assert_eq(reader.next(), None)
}

///|
test "file reader replaces context on each independently validated FDE" {
  let reader = @moonbinlog.BinlogFileReader::new(
    file_magic +
    fde_crc32 +
    event_crc32 +
    fde_off +
    event_off +
    fde_crc32 +
    event_crc32,
  )
  let first = file_next(reader)
  assert_eq(first.format.checksum_algorithm, Crc32)
  let _ = file_next(reader)
  let off = file_next(reader)
  assert_eq(off.format.checksum_algorithm, Off)
  assert_eq(file_next(reader).body, event_off[19:])
  assert_eq(file_next(reader).format.checksum_algorithm, Crc32)
  let _ = file_next(reader)
  assert_eq(reader.next(), None)
  assert_eq(first.raw, fde_crc32[:])
  assert_eq(first.format.header.file_offset, 4UL)
  assert_eq(off.format.header.file_offset, 157UL)
}

///|
test "file reader rejects every truncated FDE prefix without advancing" {
  for length in 1..<fde_crc32.length() {
    let reader = @moonbinlog.BinlogFileReader::new(
      file_magic + fde_crc32[:length].to_owned(),
    )
    let error = file_error(reader)
    if length < 19 {
      assert_eq(
        error,
        TruncatedInput(file_offset=4, expected=19, actual=length),
      )
    } else {
      assert_eq(
        error,
        TruncatedEvent(
          file_offset=4,
          expected=122,
          actual=length.reinterpret_as_uint(),
        ),
      )
    }
  }
}

///|
test "file reader detects every partial final event prefix" {
  for length in 1..<event_crc32.length() {
    let reader = @moonbinlog.BinlogFileReader::new(
      file_magic + fde_crc32 + event_crc32[:length].to_owned(),
    )
    let _ = file_next(reader)
    let error = file_error(reader)
    if length < 19 {
      assert_eq(
        error,
        TruncatedInput(file_offset=126, expected=19, actual=length),
      )
    } else {
      assert_eq(
        error,
        TruncatedEvent(
          file_offset=126,
          expected=31,
          actual=length.reinterpret_as_uint(),
        ),
      )
    }
  }
}

///|
test "file reader checksum failures clear format and stop retries" {
  for
    bad in [
      tx_bad_crc,
      Bytes::makei(event_crc32.length(), i => {
        if i == 4 {
          255
        } else {
          event_crc32[i]
        }
      }),
    ] {
    let reader = @moonbinlog.BinlogFileReader::new(
      file_magic + fde_crc32 + bad + event_crc32,
    )
    let first = file_next(reader)
    match file_error(reader) {
      ChecksumMismatch(file_offset=126, ..) => ()
      other => fail("unexpected integrity error: \{Repr(other)}")
    }
    assert_eq(first.format.checksum_algorithm, Crc32)
    assert_eq(first.raw, fde_crc32[:])
  }
}

///|
test "file reader rejects invalid replacement FDE and clears old context" {
  for bad in [fde_bad_algorithm, fde_other_server, fde_bad_table] {
    let reader = @moonbinlog.BinlogFileReader::new(
      file_magic + fde_off + bad + event_off,
    )
    let _ = file_next(reader)
    let _ = file_error(reader)
  }
  // OFF never disables the FDE's own CRC.
  let bad = Bytes::makei(fde_off.length(), i => {
    if i == 20 {
      1
    } else {
      fde_off[i]
    }
  })
  let reader = @moonbinlog.BinlogFileReader::new(file_magic + fde_off + bad)
  let _ = file_next(reader)
  match file_error(reader) {
    ChecksumMismatch(file_offset=126, ..) => ()
    other => fail("unexpected FDE integrity error: \{Repr(other)}")
  }
}

///|
test "file reader checks event limits and unsigned lengths before indexing" {
  let reader = @moonbinlog.BinlogFileReader::new(
    file_magic + fde_crc32,
    max_event_size=121,
  )
  assert_eq(
    file_error(reader),
    EventTooLarge(file_offset=4, event_size=122, max_event_size=121),
  )
  let reader = @moonbinlog.BinlogFileReader::new(
    file_magic + fde_crc32,
    max_event_size=122,
  )
  let _ = file_next(reader)
  assert_eq(reader.next(), None)
  for size in [0U, 18U, 0x80000000U, 0xffffffffU] {
    let header = Bytes::makei(19, i => {
      if i >= 9 && i < 13 {
        ((size >> ((i - 9) * 8)) & 255).to_byte()
      } else {
        0
      }
    })
    let reader = @moonbinlog.BinlogFileReader::new(
      file_magic + fde_crc32 + header,
      max_event_size=0xffffffff,
    )
    let _ = file_next(reader)
    let error = file_error(reader)
    if size < 19 {
      assert_eq(error, InvalidEventLength(file_offset=126, event_size=size))
    } else {
      assert_eq(
        error,
        TruncatedEvent(file_offset=126, expected=size, actual=19),
      )
    }
  }
}

///|
test "file reader offsets are relative to input view and event views stay bounded" {
  let data = b"prefix" + file_magic + fde_crc32 + event_crc32 + b"suffix"
  let reader = @moonbinlog.BinlogFileReader::new(data[6:data.length() - 6])
  assert_eq(file_next(reader).header.file_offset, 4UL)
  let event = file_next(reader)
  assert_eq(event.header.file_offset, 126UL)
  assert_eq(event.raw.length(), 31)
  assert_eq(event.body.length(), 8)
  assert_eq(reader.next(), None)
}

///|
test "file reader integrates complete RBR spans with explicit transaction decoder" {
  for
    stream in [tx_stream_commit, tx_stream_rollback, tx_stream_two_transactions] {
    let reader = @moonbinlog.BinlogFileReader::new(
      file_magic + fde_crc32 + stream,
    )
    let fde = file_next(reader)
    let decoder = @moonbinlog.TransactionDecoder::new(fde.format)
    let mut outcomes = 0
    while reader.next() is Some(event) {
      let result = decoder.feed(
        event.raw,
        file_offset=event.header.file_offset,
        integer_unsigned=row_image_signs(),
      )
      if result.outcome is Some(_) {
        outcomes += 1
      }
    }
    decoder.finish()
    assert_eq(
      outcomes,
      if stream == tx_stream_two_transactions {
        2
      } else {
        1
      },
    )
  }
}

///|
test "file EOF does not imply transaction commit or semantic validity" {
  let reader = @moonbinlog.BinlogFileReader::new(
    file_magic + fde_crc32 + tx_stream_unfinished,
  )
  let decoder = @moonbinlog.TransactionDecoder::new(file_next(reader).format)
  while reader.next() is Some(event) {
    assert_eq(
      decoder.feed(
        event.raw,
        file_offset=event.header.file_offset,
        integer_unsigned=row_image_signs(),
      ).outcome,
      None,
    )
  }
  try decoder.finish() catch {
    IncompleteTransaction(start_offset=126) => ()
    other => fail("unexpected EOF error: \{Repr(other)}")
  } noraise {
    _ => fail("file EOF committed unfinished transaction")
  }
}
