// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// A MySQL 8.0 ROTATE_EVENT (4), independent of the common header's next_position.
/// The target identifier is retained verbatim, without charset/path interpretation.
pub struct RotateEvent {
  header : EventHeader
  position : UInt64
  next_binlog : Bytes
} derive(Debug, Eq)

///|
pub extend RotateEvent with Eq::{equal, not_equal}

///|
pub extend RotateEvent with @debug.Debug::{to_repr}

///|
/// Validate one full event using its current FDE. Requires an eight-byte
/// little-endian position and a nonempty identifier byte sequence. No NUL is
/// appended or stripped from the identifier.
/// Unknown filename encodings and all UInt64 positions (including zero) are
/// preserved. Trailing input outside the declared event is not consumed.
/// No next file is opened and no cross-file/transaction state is advanced.
/// For a framed event from BinlogFileReader, pass event.format, event.raw and
/// file_offset=event.header.file_offset; position is the target file's offset.
pub fn RotateEvent::parse(
  format : FormatDescription,
  data : BytesView,
  file_offset~ : UInt64,
  max_event_size~ : UInt32 = 16_777_216,
) -> RotateEvent raise DecodeError {
  let header = EventHeader::parse(data, file_offset~, max_event_size~)
  guard header.event_type == 4 else {
    raise UnexpectedEventType(
      file_offset~,
      expected=4,
      actual=header.event_type,
    )
  }
  let body = format.payload(data, file_offset~, max_event_size~)
  guard format.post_header_lengths.get(3) is Some(8) else {
    raise InvalidRotateEvent(
      file_offset~,
      reason="ROTATE requires an eight-byte post-header",
    )
  }
  guard body.length() > 8 else {
    raise InvalidRotateEvent(
      file_offset~,
      reason="ROTATE requires a complete position and nonempty filename",
    )
  }
  let mut position = 0UL
  for i in 0..<8 {
    position = position | (body[i].to_uint().to_uint64() << (8 * i))
  }
  { header, position, next_binlog: body[8:].to_owned(), }
}
