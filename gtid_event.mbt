// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// Commit timestamps in microseconds, with the immediate timestamp's flag bit
/// removed. When only one timestamp is encoded, both fields have that value.
pub struct GtidCommitTimestamps {
  immediate : UInt64
  original : UInt64
} derive(Debug, Eq)

///|
pub extend GtidCommitTimestamps with Eq::{equal, not_equal}

///|
pub extend GtidCommitTimestamps with @debug.Debug::{to_repr}

///|
/// Raw numeric MySQL server versions, without the immediate version's flag bit.
pub struct GtidServerVersions {
  immediate : UInt32
  original : UInt32
} derive(Debug, Eq)

///|
pub extend GtidServerVersions with Eq::{equal, not_equal}

///|
pub extend GtidServerVersions with @debug.Debug::{to_repr}

///|
/// MySQL 8.0 GTID_EVENT (33) or ANONYMOUS_GTID_EVENT (34), logical typecode 2.
/// Optional extensions use None when absent, distinct from an encoded zero.
/// SID bytes and unknown flag bits are retained; anonymous SID/GNO fields do
/// not assign a transaction identity. This event is not evidence of a commit.
pub struct GtidEvent {
  header : EventHeader
  flags : Byte
  sid : Bytes
  gno : UInt64
  last_committed : UInt64
  sequence_number : UInt64
  commit_timestamps : GtidCommitTimestamps?
  transaction_length : UInt64?
  server_versions : GtidServerVersions?
  commit_group_ticket : UInt64?
} derive(Debug, Eq)

///|
pub extend GtidEvent with Eq::{equal, not_equal}

///|
pub extend GtidEvent with @debug.Debug::{to_repr}

///|
pub fn GtidEvent::is_anonymous(self : GtidEvent) -> Bool {
  self.header.event_type == 34
}

///|
pub fn GtidEvent::may_have_sbr_statements(self : GtidEvent) -> Bool {
  (self.flags.to_int() & 1) != 0
}

///|
priv struct GtidEventReader {
  data : BytesView
  file_offset : UInt64
  mut position : Int32
}

///|
fn GtidEventReader::invalid(
  self : GtidEventReader,
  reason : String,
) -> DecodeError {
  InvalidGtidEvent(
    file_offset=self.file_offset,
    body_offset=self.position,
    reason~,
  )
}

///|
fn GtidEventReader::remaining(self : GtidEventReader) -> Int32 {
  self.data.length() - self.position
}

///|
fn GtidEventReader::uint_le(
  self : GtidEventReader,
  width : Int32,
) -> UInt64 raise DecodeError {
  guard self.remaining() >= width else {
    raise self.invalid("truncated GTID field")
  }
  let mut value = 0UL
  for i in 0..<width {
    value = value |
      (self.data[self.position + i].to_uint().to_uint64() << (8 * i))
  }
  self.position += width
  value
}

///|
fn GtidEventReader::packed_length(
  self : GtidEventReader,
) -> UInt64 raise DecodeError {
  match self.uint_le(1) {
    0UL..<=250UL as value => value
    252 => self.uint_le(2)
    253 => self.uint_le(3)
    254 => self.uint_le(8)
    _ => raise self.invalid("NULL or reserved transaction-length marker")
  }
}

///|
/// Validate a complete event with its current FDE, CRC32/OFF and byte budget.
/// Requires a 42-byte post-header and logical timestamp typecode 2. Extensions
/// may end after any complete stage: timestamps, transaction length, server
/// versions, or an eight-byte ticket; partial fields/trailing bytes are errors.
/// GNO must be 1..INT64_MAX-1 for type 33 and zero for type 34. Logical clocks,
/// lengths and tickets are retained without cross-event ordering assumptions.
/// No transaction is opened, committed, deduplicated or bound to this GTID.
pub fn GtidEvent::parse(
  format : FormatDescription,
  data : BytesView,
  file_offset~ : UInt64,
  max_event_size~ : UInt32 = 16_777_216,
) -> GtidEvent raise DecodeError {
  let header = EventHeader::parse(data, file_offset~, max_event_size~)
  guard header.event_type == 33 || header.event_type == 34 else {
    raise UnsupportedGtidEvent(file_offset~, event_type=header.event_type)
  }
  let body = format.payload(data, file_offset~, max_event_size~)
  let reader = GtidEventReader::{ data: body, file_offset, position: 0, }
  guard format.post_header_lengths.get(header.event_type.to_int() - 1)
    is Some(42) else {
    raise reader.invalid("GTID requires a 42-byte post-header")
  }
  guard body.length() >= 42 else {
    raise reader.invalid("incomplete GTID post-header")
  }
  reader.position = 17
  let gno = reader.uint_le(8)
  guard (if header.event_type == 33 {
    gno >= 1 && gno < 0x7fffffffffffffffUL
  } else {
    gno == 0
  }) else {
    raise reader.invalid("invalid assigned or anonymous GNO")
  }
  guard reader.uint_le(1) == 2 else {
    raise reader.invalid("unsupported logical timestamp typecode")
  }
  let last_committed = reader.uint_le(8)
  let sequence_number = reader.uint_le(8)
  let commit_timestamps = if reader.remaining() > 0 {
    let encoded = reader.uint_le(7)
    let immediate = encoded & 0x7fffffffffffffUL
    let original = if (encoded & 0x80000000000000UL) != 0 {
      reader.uint_le(7)
    } else {
      immediate
    }
    Some(GtidCommitTimestamps::{ immediate, original, })
  } else {
    None
  }
  let transaction_length = if reader.remaining() > 0 {
    Some(reader.packed_length())
  } else {
    None
  }
  let server_versions = if reader.remaining() > 0 {
    let encoded = reader.uint_le(4)
    let immediate = (encoded & 0x7fffffffUL).to_uint()
    let original = if (encoded & 0x80000000UL) != 0 {
      reader.uint_le(4).to_uint()
    } else {
      immediate
    }
    Some(GtidServerVersions::{ immediate, original, })
  } else {
    None
  }
  let commit_group_ticket = if reader.remaining() > 0 {
    Some(reader.uint_le(8))
  } else {
    None
  }
  guard reader.remaining() == 0 else {
    raise reader.invalid("trailing bytes after GTID extensions")
  }
  {
    header,
    flags: body[0],
    sid: body[1:17].to_owned(),
    gno,
    last_committed,
    sequence_number,
    commit_timestamps,
    transaction_length,
    server_versions,
    commit_group_ticket,
  }
}
