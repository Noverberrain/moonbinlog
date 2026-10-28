// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
priv struct GtidExpected {
  kind : Byte
  sid : Bytes
  flags : Byte
  gno : UInt64
  last : UInt64
  sequence : UInt64
  times : (UInt64, UInt64)?
  length : UInt64?
  versions : (UInt32, UInt32)?
  ticket : UInt64?
}

///|
fn gtid_decode(
  data : BytesView,
  format_bytes~ : Bytes = gtid_fde_crc32,
) -> @moonbinlog.GtidEvent raise @moonbinlog.DecodeError {
  let format = @moonbinlog.FormatDescription::parse(format_bytes, file_offset=4)
  @moonbinlog.GtidEvent::parse(format, data, file_offset=0x100000004)
}

///|
fn gtid_assert(
  value : @moonbinlog.GtidEvent,
  expected : GtidExpected,
) -> Unit raise {
  assert_eq(value.header.event_type, expected.kind)
  assert_eq(value.sid, expected.sid)
  assert_eq(value.flags, expected.flags)
  assert_eq(value.gno, expected.gno)
  assert_eq(value.last_committed, expected.last)
  assert_eq(value.sequence_number, expected.sequence)
  assert_eq(
    value.commit_timestamps.map(pair => (pair.immediate, pair.original)),
    expected.times,
  )
  assert_eq(value.transaction_length, expected.length)
  assert_eq(
    value.server_versions.map(pair => (pair.immediate, pair.original)),
    expected.versions,
  )
  assert_eq(value.commit_group_ticket, expected.ticket)
  assert_eq(value.is_anonymous(), expected.kind == 34)
  assert_eq(value.may_have_sbr_statements(), (expected.flags.to_int() & 1) != 0)
}

///|
test "GTID events match independent CRC32 OFF identities and all extension stages" {
  let vectors = gtid_valid()
  assert_eq(vectors.length(), 22)
  for (_, crc, off, expected) in vectors {
    let decoded = gtid_decode(crc)
    gtid_assert(decoded, expected)
    gtid_assert(gtid_decode(off, format_bytes=gtid_fde_off), expected)
    assert_eq(decoded.header.file_offset, 0x100000004UL)
    assert_eq(decoded, gtid_decode(crc))
  }
}

///|
test "GTID events distinguish assigned and anonymous identity without losing raw flags or clocks" {
  let mut checked = 0
  for (name, raw, _, _) in gtid_valid() {
    let value = gtid_decode(raw)
    if name == "max_gno" {
      assert_false(value.is_anonymous())
      assert_true(value.may_have_sbr_statements())
      assert_eq(value.gno, 0x7ffffffffffffffeUL)
      assert_eq(value.flags, (0x81 : Byte))
      assert_eq(value.last_committed, 0xffffffffffffffffUL)
      assert_eq(value.sequence_number, 0xffffffffffffffffUL)
      checked += 1
    } else if name == "anonymous_raw_sid" {
      assert_true(value.is_anonymous())
      assert_eq(value.gno, 0UL)
      assert_eq(
        value.sid,
        b"\x00\x11\x22\x33\x44\x55\x66\x77\x88\x99\xaa\xbb\xcc\xdd\xee\xff",
      )
      assert_eq(value.flags, (0xff : Byte))
      checked += 1
    }
  }
  assert_eq(checked, 2)
}

///|
test "GTID events distinguish missing extensions from encoded zero and retain full original widths" {
  let mut checked = 0
  for (name, raw, _, _) in gtid_valid() {
    let value = gtid_decode(raw)
    if name == "base" {
      assert_eq(value.commit_timestamps, None)
      assert_eq(value.transaction_length, None)
      assert_eq(value.server_versions, None)
      assert_eq(value.commit_group_ticket, None)
      checked += 1
    } else if name == "ticket_zero" {
      assert_eq(
        value.commit_timestamps.map(pair => (pair.immediate, pair.original)),
        Some((0UL, 0UL)),
      )
      assert_eq(value.transaction_length, Some(0UL))
      assert_eq(
        value.server_versions.map(pair => (pair.immediate, pair.original)),
        Some((0U, 0U)),
      )
      assert_eq(value.commit_group_ticket, Some(0UL))
      checked += 1
    } else if name == "timestamp_distinct" {
      assert_eq(
        value.commit_timestamps.map(pair => (pair.immediate, pair.original)),
        Some((0x7fffffffffffffUL, 0xffffffffffffffUL)),
      )
      checked += 1
    } else if name == "versions_distinct" {
      assert_eq(
        value.server_versions.map(pair => (pair.immediate, pair.original)),
        Some((0x7fffffffU, 0xffffffffU)),
      )
      checked += 1
    }
  }
  assert_eq(checked, 4)
}

///|
test "GTID event invalid GNO typecodes packed markers partial extensions and trailing bytes fail" {
  let vectors = gtid_invalid()
  assert_eq(vectors.length(), 94)
  for (name, raw) in vectors {
    try gtid_decode(raw) catch {
      InvalidGtidEvent(file_offset~, body_offset~, ..) => {
        assert_eq(file_offset, 0x100000004UL)
        assert_true(body_offset >= 0 && body_offset <= raw.length() - 23)
      }
      other => fail("unexpected GTID error for \{name}: \{Repr(other)}")
    } noraise {
      _ => fail("invalid GTID accepted: \{name}")
    }
  }
}

///|
test "GTID event every incomplete framing prefix fails for CRC32 and OFF" {
  for (_, crc, off, _) in gtid_valid() {
    for (raw, format_bytes) in [(crc, gtid_fde_crc32), (off, gtid_fde_off)] {
      for size in 0..<raw.length() {
        try gtid_decode(raw[:size], format_bytes~) catch {
          TruncatedInput(..) | TruncatedEvent(..) => ()
          other => fail("unexpected GTID prefix error: \{Repr(other)}")
        } noraise {
          _ => fail("incomplete GTID frame accepted")
        }
      }
    }
  }
}

///|
test "GTID event declared body prefixes accept only complete optional stages" {
  let mut checked = false
  for (name, _, off, _) in gtid_valid() {
    if name == "full" {
      for length in 0..<(off.length() - 19) {
        let size = 19 + length
        let header = off[:19].to_array()
        for i in 0..<4 {
          header[9 + i] = ((size >> (8 * i)) & 255).to_byte()
        }
        let data = Bytes::from_array(header) + off[19:size].to_owned()
        let complete_stage = [42, 56, 60, 68].contains(length)
        try gtid_decode(data, format_bytes=gtid_fde_off) catch {
          InvalidGtidEvent(..) => assert_false(complete_stage)
          other => fail("unexpected body-prefix error: \{Repr(other)}")
        } noraise {
          _ => assert_true(complete_stage)
        }
      }
      checked = true
    }
  }
  assert_true(checked)
}

///|
test "GTID events require supported event kinds FDE post header and checksum" {
  let (_, raw, _, _) = gtid_valid()[0]
  ignore(gtid_decode(raw, format_bytes=gtid_fde_anonymous_short))
  for (_, anonymous, _, expected) in gtid_valid() {
    if expected.kind == 34 {
      try gtid_decode(anonymous, format_bytes=gtid_fde_anonymous_short) catch {
        InvalidGtidEvent(body_offset=0, ..) => ()
        other => fail("unexpected anonymous FDE error: \{Repr(other)}")
      } noraise {
        _ => fail("wrong event type's post-header used for anonymous GTID")
      }
    }
  }
  for format_bytes in [gtid_fde_missing, gtid_fde_short, gtid_fde_wrong] {
    try gtid_decode(raw, format_bytes~) catch {
      InvalidGtidEvent(body_offset=0, ..) => ()
      other => fail("unexpected GTID FDE error: \{Repr(other)}")
    } noraise {
      _ => fail("unsupported GTID post-header accepted")
    }
  }
  try gtid_decode(event_crc32) catch {
    UnsupportedGtidEvent(event_type=16, ..) => ()
    other => fail("unexpected GTID kind error: \{Repr(other)}")
  } noraise {
    _ => fail("XID accepted as GTID")
  }
  try gtid_decode(gtid_bad_crc) catch {
    ChecksumMismatch(..) => ()
    other => fail("unexpected GTID checksum error: \{Repr(other)}")
  } noraise {
    _ => fail("bad GTID checksum accepted")
  }
}

///|
test "GTID event byte budgets sliced inputs and failure leave format reusable" {
  let format = @moonbinlog.FormatDescription::parse(
    gtid_fde_crc32,
    file_offset=4,
  )
  for (_, raw, _, expected) in gtid_valid() {
    let value = @moonbinlog.GtidEvent::parse(
      format,
      raw,
      file_offset=0xffffffffffffffff,
      max_event_size=raw.length().reinterpret_as_uint(),
    )
    gtid_assert(value, expected)
    assert_eq(value.header.file_offset, 0xffffffffffffffffUL)
    let wrapped = b"prefix" + raw + b"tail"
    assert_eq(gtid_decode(wrapped[6:]), gtid_decode(raw))
    for max_event_size in [18U, raw.length().reinterpret_as_uint() - 1] {
      try
        @moonbinlog.GtidEvent::parse(
          format,
          raw,
          file_offset=4,
          max_event_size~,
        )
      catch {
        InvalidEventLimit(..) | EventTooLarge(..) => ()
        other => fail("unexpected GTID budget error: \{Repr(other)}")
      } noraise {
        _ => fail("GTID event budget ignored")
      }
    }
  }
  assert_eq(format.checksum_algorithm, Crc32)
}

///|
test "six real anonymous GTID events match official clocks timestamps versions and transaction lengths" {
  for (data, offset, expected) in gtid_real_oracles() {
    let reader = @moonbinlog.BinlogFileReader::new(data)
    let mut count = 0
    while reader.next() is Some(event) {
      if event.header.event_type == 33 || event.header.event_type == 34 {
        let value = @moonbinlog.GtidEvent::parse(
          event.format,
          event.raw,
          file_offset=event.header.file_offset,
        )
        gtid_assert(value, expected)
        assert_eq(value.header, event.header)
        assert_eq(value.header.file_offset, offset)
        count += 1
      }
    }
    assert_eq(count, 1)
  }
}
