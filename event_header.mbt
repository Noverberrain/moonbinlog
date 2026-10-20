// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// Read-only decoded fields of a v4 common event header.
/// `event_size` includes the common header and any checksum trailer.
/// `next_position` is retained verbatim and must not replace the input cursor.
pub struct EventHeader {
  file_offset : UInt64
  timestamp : UInt32
  event_type : Byte
  server_id : UInt32
  event_size : UInt32
  next_position : UInt32
  flags : UInt16
} derive(Debug, Eq)

///|
pub extend EventHeader with Eq::{equal, not_equal}

///|
pub extend EventHeader with @debug.Debug::{to_repr}

///|
/// Decode the first 19 bytes without consuming or validating an event payload.
/// `data` starts at the event header; `file_offset` is its physical file offset.
/// Unknown event type codes and zero next positions are preserved.
///
/// The default event-size limit is 16 MiB. A limit below 19 is invalid.
/// A caller may pass only the header, then read the declared payload separately.
/// Full-event availability, FORMAT_DESCRIPTION and checksums are separate steps.
pub fn EventHeader::parse(
  data : BytesView,
  file_offset~ : UInt64,
  max_event_size~ : UInt32 = 16_777_216,
) -> EventHeader raise DecodeError {
  guard max_event_size >= 19 else { raise InvalidEventLimit(max_event_size~) }
  guard data.length() >= 19 else {
    raise TruncatedInput(file_offset~, expected=19, actual=data.length())
  }
  let event_size = read_u32_le(data, 9)
  guard event_size >= 19 else {
    raise InvalidEventLength(file_offset~, event_size~)
  }
  guard event_size <= max_event_size else {
    raise EventTooLarge(file_offset~, event_size~, max_event_size~)
  }
  {
    file_offset,
    timestamp: read_u32_le(data, 0),
    event_type: data[4],
    server_id: read_u32_le(data, 5),
    event_size,
    next_position: read_u32_le(data, 13),
    flags: read_u16_le(data, 17),
  }
}

///|
// Private helpers: the caller checks the complete 19-byte prefix before reads.
fn read_u32_le(data : BytesView, offset : Int32) -> UInt32 {
  data[offset].to_uint() |
  (data[offset + 1].to_uint() << 8) |
  (data[offset + 2].to_uint() << 16) |
  (data[offset + 3].to_uint() << 24)
}

///|
fn read_u16_le(data : BytesView, offset : Int32) -> UInt16 {
  (data[offset].to_uint() | (data[offset + 1].to_uint() << 8)).to_uint16()
}
