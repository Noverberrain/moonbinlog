// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// One GTID interval [start, end_exclusive). Values fit MySQL's positive GNO
/// range; end_exclusive may equal INT64_MAX, which is not itself a valid GNO.
pub struct GtidInterval {
  start : UInt64
  end_exclusive : UInt64
} derive(Debug, Eq)

///|
pub extend GtidInterval with Eq::{equal, not_equal}

///|
pub extend GtidInterval with @debug.Debug::{to_repr}

///|
/// A 16-byte SID and its ordered, nonoverlapping, nonadjacent intervals.
/// The SID is retained verbatim, without UUID version/variant restrictions.
pub struct GtidSidIntervals {
  sid : Bytes
  intervals : ReadOnlyArray[GtidInterval]
} derive(Debug, Eq)

///|
pub extend GtidSidIntervals with Eq::{equal, not_equal}

///|
pub extend GtidSidIntervals with @debug.Debug::{to_repr}

///|
/// Historical GTIDs declared by PREVIOUS_GTIDS_EVENT (35).
/// SID entries retain wire order, including repeated SIDs and empty entries;
/// this is a decoded representation, not a normalized GTID set.
pub struct PreviousGtidsEvent {
  header : EventHeader
  sids : ReadOnlyArray[GtidSidIntervals]
} derive(Debug, Eq)

///|
pub extend PreviousGtidsEvent with Eq::{equal, not_equal}

///|
pub extend PreviousGtidsEvent with @debug.Debug::{to_repr}

///|
priv struct GtidSetReader {
  data : BytesView
  file_offset : UInt64
  mut position : Int32
}

///|
fn GtidSetReader::invalid(self : GtidSetReader, reason : String) -> DecodeError {
  InvalidPreviousGtidsEvent(
    file_offset=self.file_offset,
    body_offset=self.position,
    reason~,
  )
}

///|
fn GtidSetReader::remaining(self : GtidSetReader) -> Int32 {
  self.data.length() - self.position
}

///|
fn GtidSetReader::uint64(self : GtidSetReader) -> UInt64 raise DecodeError {
  guard self.remaining() >= 8 else {
    raise self.invalid("truncated eight-byte integer")
  }
  let mut value = 0UL
  for i in 0..<8 {
    value = value |
      (self.data[self.position + i].to_uint().to_uint64() << (8 * i))
  }
  self.position += 8
  value
}

///|
/// Decode a complete MySQL 8.0 event using its current FDE, including CRC/OFF.
/// Requires a zero-length post-header and exact consumption of the event body.
/// Counts are checked against remaining bytes and quotas before narrowing or
/// allocating entries. max_intervals bounds the sum across all SID entries.
/// Zero quotas allow only the corresponding empty collection; negative quotas
/// are invalid. Trailing input outside the declared event is ignored.
/// This does not validate transaction history, advance replication state, or
/// add support for GTID-tagged transactions to TransactionDecoder/the CLI.
pub fn PreviousGtidsEvent::parse(
  format : FormatDescription,
  data : BytesView,
  file_offset~ : UInt64,
  max_event_size~ : UInt32 = 16_777_216,
  max_sids~ : Int32 = 1024,
  max_intervals~ : Int32 = 65536,
) -> PreviousGtidsEvent raise DecodeError {
  guard max_sids >= 0 && max_intervals >= 0 else {
    raise InvalidGtidSetLimits(max_sids~, max_intervals~)
  }
  let header = EventHeader::parse(data, file_offset~, max_event_size~)
  guard header.event_type == 35 else {
    raise UnexpectedEventType(
      file_offset~,
      expected=35,
      actual=header.event_type,
    )
  }
  let body = format.payload(data, file_offset~, max_event_size~)
  let reader = GtidSetReader::{ data: body, file_offset, position: 0, }
  guard format.post_header_lengths.get(34) is Some(0) else {
    raise reader.invalid("PREVIOUS_GTIDS requires a zero-length post-header")
  }
  let count = reader.uint64()
  guard count <= max_sids.reinterpret_as_uint().to_uint64() else {
    raise GtidSetLimitExceeded(
      file_offset~,
      reason="SID count exceeds max_sids",
    )
  }
  guard count <= (reader.remaining() / 24).reinterpret_as_uint().to_uint64() else {
    raise reader.invalid("SID count exceeds remaining body")
  }
  let sids = []
  let mut total_intervals = 0
  for _ in 0..<count.to_int() {
    // The SID-count preflight guarantees 24 bytes per entry initially, but
    // earlier intervals may have consumed bytes needed by later entries.
    guard reader.remaining() >= 24 else {
      raise reader.invalid("truncated SID entry")
    }
    let sid = body[reader.position:reader.position + 16].to_owned()
    reader.position += 16
    let interval_count = reader.uint64()
    guard interval_count <=
      (max_intervals - total_intervals).reinterpret_as_uint().to_uint64() else {
      raise GtidSetLimitExceeded(
        file_offset~,
        reason="total interval count exceeds max_intervals",
      )
    }
    guard interval_count <=
      (reader.remaining() / 16).reinterpret_as_uint().to_uint64() else {
      raise reader.invalid("interval count exceeds remaining body")
    }
    total_intervals += interval_count.to_int()
    let intervals = []
    let mut last_end = 0UL
    for _ in 0..<interval_count.to_int() {
      let start = reader.uint64()
      let end_exclusive = reader.uint64()
      guard start > last_end &&
        end_exclusive > start &&
        end_exclusive <= 0x7fffffffffffffffUL else {
        raise reader.invalid(
          "invalid, unordered, overlapping or adjacent interval",
        )
      }
      intervals.push(GtidInterval::{ start, end_exclusive, })
      last_end = end_exclusive
    }
    sids.push(GtidSidIntervals::{
      sid,
      intervals: ReadOnlyArray::from_array(intervals),
    })
  }
  guard reader.remaining() == 0 else {
    raise reader.invalid("trailing bytes inside PREVIOUS_GTIDS body")
  }
  { header, sids: ReadOnlyArray::from_array(sids), }
}
