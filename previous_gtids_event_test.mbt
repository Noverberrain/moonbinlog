// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn pg_decode(
  raw : BytesView,
  format_bytes~ : Bytes = fde_crc32,
  max_sids~ : Int32 = 1024,
  max_intervals~ : Int32 = 65536,
) -> @moonbinlog.PreviousGtidsEvent raise @moonbinlog.DecodeError {
  let format = @moonbinlog.FormatDescription::parse(format_bytes, file_offset=4)
  @moonbinlog.PreviousGtidsEvent::parse(
    format,
    raw,
    file_offset=0x100000004,
    max_sids~,
    max_intervals~,
  )
}

///|
test "previous GTIDs empty and multiple SID interval values match independent vectors" {
  assert_eq(pg_decode(pg_empty_crc32).sids.length(), 0)
  let value = pg_decode(pg_multiple_crc32)
  assert_eq(value.header.file_offset, 0x100000004UL)
  assert_eq(value.header.event_type, (35 : Byte))
  assert_eq(value.sids.length(), 2)
  assert_eq(
    value.sids[0].sid,
    b"\x00\x11\x22\x33\x44\x55\x66\x77\x88\x99\xaa\xbb\xcc\xdd\xee\xff",
  )
  assert_eq(
    value.sids[1].sid,
    b"\xff\xee\xdd\xcc\xbb\xaa\x99\x88\x77\x66\x55\x44\x33\x22\x11\x00",
  )
  assert_eq(value.sids[0].intervals.length(), 2)
  assert_eq(value.sids[0].intervals[0].start, 1UL)
  assert_eq(value.sids[0].intervals[0].end_exclusive, 5UL)
  assert_eq(value.sids[0].intervals[1].start, 8UL)
  assert_eq(value.sids[0].intervals[1].end_exclusive, 10UL)
  assert_eq(value.sids[1].intervals[0].start, 0x100000000UL)
  assert_eq(value.sids[1].intervals[0].end_exclusive, 0x100000002UL)
  let single = pg_decode(pg_single_crc32)
  assert_eq(single.sids[0].intervals[0].start, 1UL)
  assert_eq(single.sids[0].intervals[0].end_exclusive, 2UL)
  assert_eq(single, pg_decode(pg_single_crc32))
}

///|
test "previous GTIDs preserve maximum GNO exclusive end and arbitrary SID bytes" {
  let value = pg_decode(pg_boundary_crc32)
  assert_eq(
    value.sids[0].sid,
    b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
  )
  assert_eq(value.sids[0].intervals[0].start, 0x7ffffffffffffffeUL)
  assert_eq(value.sids[0].intervals[0].end_exclusive, 0x7fffffffffffffffUL)
}

///|
test "previous GTIDs retain SID wire order repeated SIDs and zero interval entries" {
  let value = pg_decode(pg_wire_order_crc32)
  assert_eq(value.sids.length(), 3)
  assert_eq(value.sids[0].intervals.length(), 0)
  assert_true(value.sids[0].sid > value.sids[1].sid)
  assert_eq(value.sids[1].sid, value.sids[2].sid)
  assert_eq(value.sids[1].intervals[0].start, 1UL)
  assert_eq(value.sids[2].intervals[0].start, 9UL)
}

///|
test "previous GTIDs OFF layout and sliced inputs obey declared event boundary" {
  for
    (crc, off) in [
      (pg_empty_crc32, pg_empty_off),
      (pg_single_crc32, pg_single_off),
      (pg_multiple_crc32, pg_multiple_off),
      (pg_boundary_crc32, pg_boundary_off),
      (pg_wire_order_crc32, pg_wire_order_off),
    ] {
    assert_eq(pg_decode(crc).sids, pg_decode(off, format_bytes=fde_off).sids)
    assert_eq(pg_decode(crc + pg_bad_crc), pg_decode(crc))
    let wrapped = b"prefix" + off + b"suffix"
    assert_eq(
      pg_decode(wrapped[6:], format_bytes=fde_off),
      pg_decode(off, format_bytes=fde_off),
    )
  }
}

///|
test "previous GTIDs reject invalid body counts intervals and trailing bytes" {
  for (name, raw) in pg_invalid {
    try pg_decode(raw) catch {
      InvalidPreviousGtidsEvent(file_offset~, body_offset~, ..) => {
        assert_eq(file_offset, 0x100000004UL)
        assert_true(body_offset >= 0 && body_offset <= raw.length() - 23)
      }
      GtidSetLimitExceeded(file_offset~, ..) => {
        assert_true(name == "huge_sids" || name == "huge_intervals")
        assert_eq(file_offset, 0x100000004UL)
      }
      other => fail("unexpected error for \{name}: \{Repr(other)}")
    } noraise {
      _ => fail("invalid previous GTIDs accepted: \{name}")
    }
  }
}

///|
test "previous GTIDs require supported FDE type complete event and CRC" {
  for format_bytes in [pg_bad_post_header, pg_missing_post_header] {
    try pg_decode(pg_single_crc32, format_bytes~) catch {
      InvalidPreviousGtidsEvent(body_offset=0, ..) => ()
      other => fail("unexpected post-header error: \{Repr(other)}")
    } noraise {
      _ => fail("unsupported previous GTIDs post-header accepted")
    }
  }
  try pg_decode(event_crc32) catch {
    UnexpectedEventType(expected=35, actual=16, ..) => ()
    other => fail("unexpected event type error: \{Repr(other)}")
  } noraise {
    _ => fail("XID accepted as previous GTIDs")
  }
  try pg_decode(pg_bad_crc) catch {
    ChecksumMismatch(..) => ()
    other => fail("unexpected CRC error: \{Repr(other)}")
  } noraise {
    _ => fail("corrupt previous GTIDs accepted")
  }
  for
    (raw, format_bytes) in [
      (pg_multiple_crc32, fde_crc32),
      (pg_multiple_off, fde_off),
    ] {
    for length in 0..<raw.length() {
      try pg_decode(raw[:length], format_bytes~) catch {
        TruncatedInput(..) | TruncatedEvent(..) => ()
        other => fail("unexpected prefix error: \{Repr(other)}")
      } noraise {
        _ => fail("incomplete previous GTIDs accepted")
      }
    }
  }
}

///|
test "previous GTIDs reject each truncated body even with consistent OFF event framing" {
  for raw in [pg_single_off, pg_multiple_off, pg_wire_order_off] {
    for length in 0..<(raw.length() - 19) {
      let size = 19 + length
      let header = raw[:19].to_array()
      for i in 0..<4 {
        header[9 + i] = ((size >> (8 * i)) & 255).to_byte()
      }
      let candidate = Bytes::from_array(header) + raw[19:size].to_owned()
      try pg_decode(candidate, format_bytes=fde_off) catch {
        InvalidPreviousGtidsEvent(..) => ()
        other => fail("unexpected body-prefix error: \{Repr(other)}")
      } noraise {
        _ => fail("truncated declared GTID body accepted")
      }
    }
  }
}

///|
test "previous GTIDs quotas count all SID entries and intervals without integer overflow" {
  ignore(pg_decode(pg_empty_crc32, max_sids=0, max_intervals=0))
  ignore(pg_decode(pg_multiple_crc32, max_sids=2, max_intervals=3))
  ignore(
    pg_decode(pg_single_crc32, max_sids=2147483647, max_intervals=2147483647),
  )
  for (max_sids, max_intervals) in [(1, 3), (2, 2), (0, 3), (2, 0)] {
    try pg_decode(pg_multiple_crc32, max_sids~, max_intervals~) catch {
      GtidSetLimitExceeded(..) => ()
      other => fail("unexpected quota error: \{Repr(other)}")
    } noraise {
      _ => fail("GTID quota ignored")
    }
  }
  try pg_decode(pg_wire_order_crc32, max_sids=2) catch {
    GtidSetLimitExceeded(..) => ()
    other => fail("unexpected repeated SID quota error: \{Repr(other)}")
  } noraise {
    _ => fail("empty/repeated entries not counted")
  }
  for (max_sids, max_intervals) in [(-1, 0), (0, -1)] {
    try pg_decode(pg_empty_crc32, max_sids~, max_intervals~) catch {
      InvalidGtidSetLimits(..) => ()
      other => fail("unexpected invalid limit error: \{Repr(other)}")
    } noraise {
      _ => fail("negative GTID quota accepted")
    }
  }
}

///|
test "previous GTIDs event budget is enforced and format remains reusable after failure" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  let size = pg_single_crc32.length().reinterpret_as_uint()
  let parsed = @moonbinlog.PreviousGtidsEvent::parse(
    format,
    pg_single_crc32,
    file_offset=0xffffffffffffffff,
    max_event_size=size,
  )
  assert_eq(parsed.header.file_offset, 0xffffffffffffffffUL)
  for max_event_size in [18U, size - 1] {
    try
      @moonbinlog.PreviousGtidsEvent::parse(
        format,
        pg_single_crc32,
        file_offset=4,
        max_event_size~,
      )
    catch {
      InvalidEventLimit(..) | EventTooLarge(..) => ()
      other => fail("unexpected event budget error: \{Repr(other)}")
    } noraise {
      _ => fail("event budget ignored")
    }
  }
  assert_eq(pg_decode(pg_single_crc32).sids, parsed.sids)
  assert_eq(format.checksum_algorithm, Crc32)
}

///|
test "six real captures have empty previous GTIDs matching official mysqlbinlog" {
  for data in pg_real_empty() {
    let reader = @moonbinlog.BinlogFileReader::new(data)
    let mut count = 0
    while reader.next() is Some(event) {
      if event.header.event_type == 35 {
        let parsed = @moonbinlog.PreviousGtidsEvent::parse(
          event.format,
          event.raw,
          file_offset=event.header.file_offset,
        )
        assert_eq(parsed.header, event.header)
        assert_eq(parsed.sids.length(), 0)
        count += 1
      }
    }
    assert_eq(count, 1)
  }
}
