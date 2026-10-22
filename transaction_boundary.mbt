// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
pub(all) enum TransactionAction {
  Begin
  Commit
  Rollback
  Xid(UInt64)
} derive(Debug, Eq)

///|
pub extend TransactionAction with Eq::{equal, not_equal}

///|
pub extend TransactionAction with @debug.Debug::{to_repr}

///|
pub struct TransactionBoundary {
  header : EventHeader
  action : TransactionAction
} derive(Debug, Eq)

///|
pub extend TransactionBoundary with Eq::{equal, not_equal}

///|
pub extend TransactionBoundary with @debug.Debug::{to_repr}

///|
/// Parse checksum-verified QUERY (2) or XID (16) transaction control.
/// QUERY requires a 13-byte post-header, zero error_code, bounded status/db
/// fields and the terminating db NUL. Status variable contents are not decoded.
/// Only BEGIN, COMMIT and ROLLBACK are accepted, case-insensitively, with ASCII
/// whitespace and at most one final semicolon. No general SQL interpretation.
pub fn TransactionBoundary::parse(
  format : FormatDescription,
  data : BytesView,
  file_offset~ : UInt64,
) -> TransactionBoundary raise DecodeError {
  let header = EventHeader::parse(data, file_offset~)
  guard header.event_type == 2 || header.event_type == 16 else {
    raise UnsupportedTransactionEvent(
      file_offset~,
      event_type=header.event_type,
    )
  }
  let body = format.payload(data, file_offset~)
  let action = if header.event_type == 16 {
    guard format.post_header_lengths.get(15) is Some(0) && body.length() == 8 else {
      raise InvalidTransactionEvent(
        file_offset~,
        reason="XID requires zero post-header and exactly eight body bytes",
      )
    }
    let mut xid = 0UL
    for i in 0..<8 {
      xid = xid | (body[i].to_uint().to_uint64() << (8 * i))
    }
    Xid(xid)
  } else {
    guard format.post_header_lengths.get(1) is Some(13) && body.length() >= 13 else {
      raise InvalidTransactionEvent(
        file_offset~,
        reason="QUERY requires a complete thirteen-byte post-header",
      )
    }
    guard read_u16_le(body, 9) == 0 else {
      raise InvalidTransactionEvent(
        file_offset~,
        reason="failed QUERY cannot establish a transaction boundary",
      )
    }
    let status_length = read_u16_le(body, 11).to_uint().reinterpret_as_int()
    let database_length = body[8].to_int()
    let query_start = 13 + status_length + database_length + 1
    guard query_start <= body.length() && body[query_start - 1] == 0 else {
      raise InvalidTransactionEvent(
        file_offset~,
        reason="truncated status/database or missing database terminator",
      )
    }
    let database_start = 13 + status_length
    for i in database_start..<(query_start - 1) {
      guard body[i] != 0 else {
        raise InvalidTransactionEvent(
          file_offset~,
          reason="NUL inside QUERY database name",
        )
      }
    }
    let mut start = query_start
    let mut end = body.length()
    while start < end && transaction_space(body[start]) {
      start += 1
    }
    while end > start && transaction_space(body[end - 1]) {
      end -= 1
    }
    if end > start && body[end - 1] == 59 {
      end -= 1
      while end > start && transaction_space(body[end - 1]) {
        end -= 1
      }
    }
    guard end - start == 5 || end - start == 6 || end - start == 8 else {
      raise UnsupportedTransactionStatement(file_offset~)
    }
    let statement = Bytes::makei(end - start, i => {
      let byte = body[start + i].to_int()
      (if byte >= 97 && byte <= 122 { byte - 32 } else { byte }).to_byte()
    })
    if statement == b"BEGIN" {
      Begin
    } else if statement == b"COMMIT" {
      Commit
    } else if statement == b"ROLLBACK" {
      Rollback
    } else {
      raise UnsupportedTransactionStatement(file_offset~)
    }
  }
  { header, action, }
}

///|
fn transaction_space(byte : Byte) -> Bool {
  byte == 32 || (byte >= 9 && byte <= 13)
}
