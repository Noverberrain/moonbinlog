// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn format_error(data : BytesView) -> @moonbinlog.DecodeError raise {
  try @moonbinlog.FormatDescription::parse(data, file_offset=4) catch {
    err => err
  } noraise {
    _ => fail("invalid format description was accepted")
  }
}

///|
fn changed_byte(data : BytesView, offset : Int32, byte : Byte) -> Bytes {
  Bytes::makei(data.length(), i => if i == offset { byte } else { data[i] })
}

///|
fn joined_bytes(first : BytesView, second : BytesView) -> Bytes {
  Bytes::makei(first.length() + second.length(), i => {
    if i < first.length() {
      first[i]
    } else {
      second[i - first.length()]
    }
  })
}

///|
test "format description decodes fixed fields and the exact post-header table" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  assert_eq(format.header.event_type, (15 : Byte))
  assert_eq(format.header.event_size, 122U)
  assert_eq(format.header.file_offset, 4UL)
  assert_eq(format.binlog_version, (4 : UInt16))
  assert_eq(format.server_version, "8.0.36-moonbinlog")
  assert_eq(format.created_timestamp, 0x65a0b1c2U)
  assert_eq(format.common_header_length, (19 : Byte))
  assert_true(format.checksum_algorithm is Crc32)
  assert_eq(format.post_header_lengths.length(), 41)
  assert_eq(format.post_header_lengths[1], (13 : Byte))
  assert_eq(format.post_header_lengths[14], (98 : Byte))
  assert_eq(format.post_header_lengths[18], (8 : Byte))
  assert_eq(format.post_header_lengths[29], (10 : Byte))
}

///|
test "OFF selects unchecked subsequent events but the format itself needs CRC" {
  let format = @moonbinlog.FormatDescription::parse(fde_off, file_offset=4)
  assert_true(format.checksum_algorithm is Off)
  assert_eq(format.post_header_lengths.length(), 41)
  assert_true(
    format_error(changed_byte(fde_off, 71, 0)) is ChecksumMismatch(..),
  )
}

///|
test "FDE CRC clears only the mutable in-use bit without changing input" {
  for (input, flags) in [(fde_in_use, 1U), (fde_other_flags, 0x8001U)] {
    let format = @moonbinlog.FormatDescription::parse(input, file_offset=4)
    assert_eq(format.header.flags.to_uint(), flags)
    assert_eq(input[17], (1 : Byte))
  }
  let other_bit = changed_byte(fde_in_use, 17, 3)
  assert_true(format_error(other_bit) is ChecksumMismatch(..))
}

///|
test "format CRC rejects altered header body and checksum bytes" {
  for offset in [0, 5, 18, 25, 71, 78, 118, 121] {
    let mutated = changed_byte(fde_crc32, offset, fde_crc32[offset] ^ 1)
    match format_error(mutated) {
      ChecksumMismatch(file_offset~, expected~, actual~) => {
        assert_eq(file_offset, 4UL)
        assert_true(expected != actual)
      }
      other => fail("unexpected error: \{Repr(other)}")
    }
  }
}

///|
test "format parser rejects non-format event types" {
  assert_true(
    format_error(event_crc32) is UnexpectedEventType(expected=15, actual=16, ..),
  )
}

///|
test "format parser checks every truncated prefix of a complete event" {
  for length in 0..<fde_crc32.length() {
    let err = format_error(fde_crc32[:length])
    if length < 19 {
      match err {
        TruncatedInput(expected=19, actual~, ..) => assert_eq(actual, length)
        _ => fail("expected a truncated common header")
      }
    } else {
      match err {
        TruncatedEvent(expected~, actual~, ..) => {
          assert_eq(expected, 122U)
          assert_eq(actual, length.reinterpret_as_uint())
        }
        _ => fail("expected a truncated event")
      }
    }
  }
}

///|
test "format parser does not overflow when an unavailable event length has its high bit set" {
  try
    @moonbinlog.FormatDescription::parse(
      with_event_size(0xffffffff),
      file_offset=4,
      max_event_size=0xffffffff,
    )
  catch {
    TruncatedEvent(expected=0xffffffff, actual=19, ..) => ()
    other => fail("unexpected error: \{Repr(other)}")
  } noraise {
    _ => fail("impossible event length was accepted")
  }
}

///|
test "format parser enforces the caller event-size bound" {
  try
    @moonbinlog.FormatDescription::parse(
      fde_crc32,
      file_offset=4,
      max_event_size=121,
    )
  catch {
    EventTooLarge(event_size=122, max_event_size=121, ..) => ()
    other => fail("unexpected error: \{Repr(other)}")
  } noraise {
    _ => fail("format event limit was ignored")
  }
}

///|
test "format parser rejects unsupported checksum and binlog versions" {
  assert_true(
    format_error(fde_bad_algorithm)
    is UnsupportedChecksumAlgorithm(algorithm=2, ..),
  )
  assert_true(
    format_error(fde_bad_binlog_version)
    is UnsupportedBinlogVersion(version=3, ..),
  )
}

///|
test "format parser explicitly bounds the supported server version" {
  assert_true(
    format_error(fde_other_server)
    is UnsupportedServerVersion(server_version="8.4.0", ..),
  )
  assert_true(
    format_error(fde_bad_version_text)
    is UnsupportedServerVersion(server_version="8.0.x", ..),
  )
}

///|
test "format parser rejects malformed fixed strings and format tables with valid CRC" {
  for
    input in [
      fde_unterminated_version, fde_non_ascii_version, fde_bad_table, fde_short_table,
    ] {
    assert_true(format_error(input) is InvalidFormatDescription(..))
  }
  assert_true(
    format_error(fde_bad_common_length)
    is UnsupportedHeaderLength(length=20, ..),
  )
}

///|
test "format parser isolates a nested view and leaves following events out of the CRC" {
  let wrapped = joined_bytes(b"abc", joined_bytes(fde_crc32, event_crc32))
  let format = @moonbinlog.FormatDescription::parse(
    wrapped[3:],
    file_offset=0x100000004,
  )
  assert_eq(format.header.file_offset, 0x100000004UL)
  assert_eq(format.header.event_size, 122U)
  assert_eq(format.post_header_lengths.length(), 41)
}

///|
test "CRC context verifies following events and strips exactly four trailer bytes" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  let payload = format.payload(event_crc32, file_offset=126)
  assert_eq(payload.to_owned(), ([1, 0, 0, 0, 0, 0, 0, 0] : Bytes))
  assert_eq(format.payload(empty_event_crc32, file_offset=157).length(), 0)
  let followed = joined_bytes(event_crc32, b"trailing bytes")
  assert_eq(format.payload(followed, file_offset=126), payload)
}

///|
test "CRC context detects corruption in ordinary flags as well as payload and trailer" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  for offset in [0, 5, 17, 19, 27, 30] {
    let mutated = changed_byte(event_crc32, offset, event_crc32[offset] ^ 1)
    try format.payload(mutated, file_offset=126) catch {
      ChecksumMismatch(file_offset=126, ..) => ()
      other => fail("unexpected error: \{Repr(other)}")
    } noraise {
      _ => fail("corrupt ordinary event was accepted")
    }
  }
}

///|
test "OFF context keeps all body bytes and supports an empty body" {
  let format = @moonbinlog.FormatDescription::parse(fde_off, file_offset=4)
  let payload = format.payload(event_off, file_offset=126)
  assert_eq(payload.to_owned(), ([1, 0, 0, 0, 0xaa, 0xbb, 0xcc, 0xdd] : Bytes))
  assert_eq(format.payload(empty_event_off, file_offset=153).length(), 0)
}

///|
test "CRC context refuses a declared event too small to contain its checksum" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  try format.payload(empty_event_off, file_offset=126) catch {
    InvalidEventLength(event_size=19, ..) => ()
    other => fail("unexpected error: \{Repr(other)}")
  } noraise {
    _ => fail("missing checksum was accepted")
  }
}

///|
test "payload checks complete-event availability and configured size bounds" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  try format.payload(event_crc32[:30], file_offset=126) catch {
    TruncatedEvent(expected=31, actual=30, ..) => ()
    other => fail("unexpected error: \{Repr(other)}")
  } noraise {
    _ => fail("truncated payload was accepted")
  }
  try format.payload(event_crc32, file_offset=126, max_event_size=30) catch {
    EventTooLarge(event_size=31, max_event_size=30, ..) => ()
    other => fail("unexpected error: \{Repr(other)}")
  } noraise {
    _ => fail("payload size limit was ignored")
  }
}

///|
test "a new format event requires a fresh context instead of using the old policy" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  try format.payload(fde_off, file_offset=126) catch {
    FormatContextResetRequired(file_offset=126) => ()
    other => fail("unexpected error: \{Repr(other)}")
  } noraise {
    _ => fail("new format event was treated as ordinary payload")
  }
  let next_format = @moonbinlog.FormatDescription::parse(
    fde_off,
    file_offset=126,
  )
  assert_true(next_format.checksum_algorithm is Off)
  assert_true(format.checksum_algorithm is Crc32)
}
