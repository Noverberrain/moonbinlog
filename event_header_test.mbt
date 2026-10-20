///|
// Independent, asymmetric wire values make byte order and field overlap visible.
let header_bytes : Bytes = [
  0x78, 0x56, 0x34, 0x12, // timestamp = 0x12345678
   0x1e, // WRITE_ROWS_EVENT v2
   0xef, 0xcd, 0xab, 0x89, // server_id = 0x89abcdef
   0x67, 0x00, 0x00, 0x00, // event_size = 103
   0x98, 0xba, 0xdc, 0xfe, // next_position = 0xfedcba98
   0x34, 0x92, // flags = 0x9234
]

///|
fn with_event_size(size : UInt32) -> Bytes {
  Bytes::makei(19, i => {
    if i >= 9 && i < 13 {
      ((size >> ((i - 9) * 8)) & 0xff).to_byte()
    } else {
      header_bytes[i]
    }
  })
}

///|
test "common header decodes every field and keeps physical and log positions distinct" {
  let header = @moonbinlog.EventHeader::parse(header_bytes, file_offset=4)
  assert_eq(header.file_offset, 4UL)
  assert_eq(header.timestamp, 0x12345678U)
  assert_eq(header.event_type, (0x1e : Byte))
  assert_eq(header.server_id, 0x89abcdefU)
  assert_eq(header.event_size, 103U)
  assert_eq(header.next_position, 0xfedcba98U)
  assert_eq(header.flags, (0x9234 : UInt16))
}

///|
test "common header accepts all unsigned 32-bit bits without signed overflow" {
  let input = Bytes::makei(19, _ => 0xff)
  let header = @moonbinlog.EventHeader::parse(
    input,
    file_offset=4,
    max_event_size=0xffffffff,
  )
  assert_eq(header.timestamp, 0xffffffffU)
  assert_eq(header.server_id, 0xffffffffU)
  assert_eq(header.event_size, 0xffffffffU)
  assert_eq(header.next_position, 0xffffffffU)
  assert_eq(header.flags, (0xffff : UInt16))
  assert_eq(header.event_type, (0xff : Byte))
}

///|
test "common header keeps zero timestamp zero next position and unknown type" {
  let input = Bytes::makei(19, i => if i == 9 { 19 } else { 0 })
  let header = @moonbinlog.EventHeader::parse(input, file_offset=4)
  assert_eq(header.timestamp, 0U)
  assert_eq(header.event_type, (0 : Byte))
  assert_eq(header.next_position, 0U)
  assert_eq(header.event_size, 19U)
}

///|
test "common header rejects every truncated prefix without reading beyond input" {
  for length in 0..<19 {
    try
      @moonbinlog.EventHeader::parse(
        header_bytes[:length],
        file_offset=0x100000004,
      )
    catch {
      TruncatedInput(file_offset~, expected~, actual~) => {
        assert_eq(file_offset, 0x100000004UL)
        assert_eq(expected, 19)
        assert_eq(actual, length)
      }
      other => fail("unexpected error: \{Repr(other)}")
    } noraise {
      _ => fail("truncated header was accepted")
    }
  }
}

///|
test "common header rejects every event size smaller than the header" {
  for size in 0..<19 {
    try
      @moonbinlog.EventHeader::parse(
        with_event_size(size.reinterpret_as_uint()),
        file_offset=128,
      )
    catch {
      InvalidEventLength(file_offset~, event_size~) => {
        assert_eq(file_offset, 128UL)
        assert_eq(event_size, size.reinterpret_as_uint())
      }
      other => fail("unexpected error: \{Repr(other)}")
    } noraise {
      _ => fail("undersized event was accepted")
    }
  }
}

///|
test "common header enforces the default event-size limit before payload allocation" {
  let size = 16_777_217U
  try
    @moonbinlog.EventHeader::parse(with_event_size(size), file_offset=4)
  catch {
    EventTooLarge(file_offset~, event_size~, max_event_size~) => {
      assert_eq(file_offset, 4UL)
      assert_eq(event_size, size)
      assert_eq(max_event_size, 16_777_216U)
    }
    other => fail("unexpected error: \{Repr(other)}")
  } noraise {
    _ => fail("oversized event was accepted")
  }
}

///|
test "common header accepts the exact default event-size limit" {
  let header = @moonbinlog.EventHeader::parse(
    with_event_size(16_777_216),
    file_offset=4,
  )
  assert_eq(header.event_size, 16_777_216U)
}

///|
test "common header accepts the exact custom limit and rejects its next byte" {
  let header = @moonbinlog.EventHeader::parse(
    header_bytes,
    file_offset=4,
    max_event_size=103,
  )
  assert_eq(header.event_size, 103U)
  try
    @moonbinlog.EventHeader::parse(
      header_bytes,
      file_offset=4,
      max_event_size=102,
    )
  catch {
    EventTooLarge(file_offset=_, event_size=103, max_event_size=102) => ()
    other => fail("unexpected error: \{Repr(other)}")
  } noraise {
    _ => fail("custom limit was ignored")
  }
}

///|
test "common header rejects limits too small for any event" {
  for limit in [0U, 18U] {
    try
      @moonbinlog.EventHeader::parse(
        header_bytes,
        file_offset=4,
        max_event_size=limit,
      )
    catch {
      InvalidEventLimit(max_event_size~) => assert_eq(max_event_size, limit)
      other => fail("unexpected error: \{Repr(other)}")
    } noraise {
      _ => fail("invalid event limit was accepted")
    }
  }
  let header = @moonbinlog.EventHeader::parse(
    with_event_size(19),
    file_offset=4,
    max_event_size=19,
  )
  assert_eq(header.event_size, 19U)
}

///|
test "common header accepts a header-only input and ignores subsequent bytes" {
  let input = Bytes::makei(27, i => if i < 19 { header_bytes[i] } else { 0xaa })
  let prefix = @moonbinlog.EventHeader::parse(header_bytes, file_offset=4)
  assert_eq(@moonbinlog.EventHeader::parse(input, file_offset=4), prefix)
}

///|
test "common header works on a nested view and offsets larger than four GiB" {
  let input = Bytes::makei(25, i => {
    if i >= 3 && i < 22 {
      header_bytes[i - 3]
    } else {
      0
    }
  })
  let header = @moonbinlog.EventHeader::parse(
    input[3:22],
    file_offset=0x100000004,
  )
  assert_eq(header.file_offset, 0x100000004UL)
  assert_eq(header.event_size, 103U)
  assert_eq(header.server_id, 0x89abcdefU)
}
