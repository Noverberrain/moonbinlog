// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn rotate_decode(
  data : BytesView,
  format_bytes~ : Bytes = fde_crc32,
) -> @moonbinlog.RotateEvent raise @moonbinlog.DecodeError {
  let format = @moonbinlog.FormatDescription::parse(format_bytes, file_offset=4)
  @moonbinlog.RotateEvent::parse(format, data, file_offset=0x100000004)
}

///|
test "rotate event target positions preserve all UInt64 values and physical offsets" {
  for
    (raw, expected) in [
      (rotate_zero, 0UL),
      (rotate_start, 4UL),
      (rotate_wide, 0x100000004UL),
      (rotate_max, 0xffffffffffffffffUL),
    ] {
    let rotation = rotate_decode(raw)
    assert_eq(rotation.position, expected)
    assert_eq(rotation.next_binlog, b"mysql-bin.000002")
    assert_eq(rotation.header.file_offset, 0x100000004UL)
    assert_eq(rotation.header.event_type, (4 : Byte))
    assert_eq(rotation.header.event_size.reinterpret_as_int(), raw.length())
    assert_eq(rotation, rotate_decode(raw))
  }
}

///|
test "rotate event verifies OFF framing and does not read outside event boundaries" {
  let rotation = rotate_decode(
    rotate_off + b"following bytes",
    format_bytes=fde_off,
  )
  assert_eq(rotation.position, 0xfedcba9876543210UL)
  assert_eq(rotation.next_binlog, b"off.000099")
  assert_eq(
    rotate_decode(rotate_start + rotate_bad_crc),
    rotate_decode(rotate_start),
  )
  let wrapped = b"prefix" + rotate_start + b"suffix"
  assert_eq(rotate_decode(wrapped[6:]), rotate_decode(rotate_start))
}

///|
test "rotate event retains filename bytes and synthetic header flags without path interpretation" {
  assert_eq(
    rotate_decode(rotate_raw_name).next_binlog,
    b"../\xff\x00\xef\xbb\xbf\\name",
  )
  assert_eq(rotate_decode(rotate_one_byte_name).next_binlog, b"\x00")
  let rotation = rotate_decode(rotate_zero_timestamp)
  assert_eq(rotation.header.timestamp, 0U)
  assert_eq(rotation.header.next_position, 0U)
  assert_eq(rotation.header.flags, (0x8020 : UInt16))
  assert_eq(rotation.position, 4UL)
}

///|
test "rotate event requires the MySQL eight byte post header and a nonempty identifier" {
  for format_bytes in [fde_rotate_0, fde_rotate_7, fde_rotate_9] {
    try rotate_decode(rotate_start, format_bytes~) catch {
      InvalidRotateEvent(file_offset~, ..) =>
        assert_eq(file_offset, 0x100000004UL)
      other => fail("unexpected rotate format error: \{Repr(other)}")
    } noraise {
      _ => fail("unsupported rotate post-header accepted")
    }
  }
  for
    raw in [
      rotate_short_0, rotate_short_1, rotate_short_2, rotate_short_3, rotate_short_4,
      rotate_short_5, rotate_short_6, rotate_short_7, rotate_short_8,
    ] {
    try rotate_decode(raw) catch {
      InvalidRotateEvent(file_offset~, ..) =>
        assert_eq(file_offset, 0x100000004UL)
      other => fail("unexpected rotate body error: \{Repr(other)}")
    } noraise {
      _ => fail("short rotate body accepted")
    }
  }
}

///|
test "rotate event rejects wrong kinds bad CRC and every incomplete event prefix" {
  try rotate_decode(event_crc32) catch {
    UnexpectedEventType(expected=4, actual=16, ..) => ()
    other => fail("unexpected rotate type error: \{Repr(other)}")
  } noraise {
    _ => fail("XID decoded as rotation")
  }
  try rotate_decode(rotate_bad_crc) catch {
    ChecksumMismatch(file_offset~, ..) => assert_eq(file_offset, 0x100000004UL)
    other => fail("unexpected rotate checksum error: \{Repr(other)}")
  } noraise {
    _ => fail("bad rotate checksum accepted")
  }
  for (raw, format_bytes) in [(rotate_start, fde_crc32), (rotate_off, fde_off)] {
    for length in 0..<raw.length() {
      try rotate_decode(raw[:length], format_bytes~) catch {
        TruncatedInput(..) | TruncatedEvent(..) => ()
        other => fail("unexpected rotate prefix error: \{Repr(other)}")
      } noraise {
        _ => fail("incomplete rotate event accepted")
      }
    }
  }
}

///|
test "rotate event size limits apply before filename allocation and can be configured" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  let size = rotate_start.length().reinterpret_as_uint()
  let rotation = @moonbinlog.RotateEvent::parse(
    format,
    rotate_start,
    file_offset=0xffffffffffffffff,
    max_event_size=size,
  )
  assert_eq(rotation.header.file_offset, 0xffffffffffffffffUL)
  assert_eq(rotation.next_binlog, b"mysql-bin.000002")
  try
    @moonbinlog.RotateEvent::parse(
      format,
      rotate_start,
      file_offset=1,
      max_event_size=size - 1,
    )
  catch {
    EventTooLarge(..) => ()
    other => fail("unexpected rotation size error: \{Repr(other)}")
  } noraise {
    _ => fail("rotation event limit ignored")
  }
  try
    @moonbinlog.RotateEvent::parse(
      format,
      rotate_start,
      file_offset=1,
      max_event_size=18,
    )
  catch {
    InvalidEventLimit(..) => ()
    other => fail("unexpected rotation limit configuration: \{Repr(other)}")
  } noraise {
    _ => fail("invalid rotation limit accepted")
  }
}

///|
test "real rotations match official MySQL position and filename for six captures" {
  for (data, position, next_binlog) in rotate_real_oracles {
    let reader = @moonbinlog.BinlogFileReader::new(data)
    let mut count = 0
    while reader.next() is Some(event) {
      if event.header.event_type == 4 {
        let rotation = @moonbinlog.RotateEvent::parse(
          event.format,
          event.raw,
          file_offset=event.header.file_offset,
        )
        assert_eq(rotation.header, event.header)
        assert_eq(rotation.position, position)
        assert_eq(rotation.next_binlog, next_binlog)
        count += 1
      }
    }
    assert_eq(count, 1)
    assert_eq(
      reader.position(),
      data.length().reinterpret_as_uint().to_uint64(),
    )
  }
}

///|
test "failed rotate parsing leaves the immutable format reusable" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  try
    @moonbinlog.RotateEvent::parse(format, rotate_short_8, file_offset=100)
  catch {
    InvalidRotateEvent(..) => ()
    other => fail("unexpected rotation error: \{Repr(other)}")
  } noraise {
    _ => fail("missing target name accepted")
  }
  let rotation = @moonbinlog.RotateEvent::parse(
    format,
    rotate_max,
    file_offset=200,
  )
  assert_eq(rotation.position, 0xffffffffffffffffUL)
  assert_eq(format.checksum_algorithm, Crc32)
}
