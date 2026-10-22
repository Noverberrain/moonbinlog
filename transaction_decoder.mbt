// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// A declared committed span. XID is absent for QUERY COMMIT.
pub struct CommittedTransaction {
  start_offset : UInt64
  end_offset : UInt64
  xid : UInt64?
  events : ReadOnlyArray[RowsEvent]
  event_count : Int32
  change_count : Int32
  wire_bytes : UInt64
} derive(Debug, Eq)

///|
pub extend CommittedTransaction with Eq::{equal, not_equal}

///|
pub extend CommittedTransaction with @debug.Debug::{to_repr}

///|
pub(all) enum TransactionOutcome {
  Committed(CommittedTransaction)
  RolledBack(
    start_offset~ : UInt64,
    end_offset~ : UInt64,
    discarded_changes~ : Int32
  )
} derive(Debug, Eq)

///|
pub extend TransactionOutcome with Eq::{equal, not_equal}

///|
pub extend TransactionOutcome with @debug.Debug::{to_repr}

///|
/// Advance by header.event_size, even while outcome is None.
pub struct TransactionStep {
  header : EventHeader
  outcome : TransactionOutcome?
} derive(Debug, Eq)

///|
pub extend TransactionStep with Eq::{equal, not_equal}

///|
pub extend TransactionStep with @debug.Debug::{to_repr}

///|
/// Strict contiguous BEGIN..COMMIT/XID/ROLLBACK assembler for transactional RBR.
/// Unknown events and SQL are errors, not silently skipped. No GTID/XA/DDL,
/// autocommit inference, savepoints or nontransactional-table rollback model.
pub struct TransactionDecoder {
  priv tables : TableMapContext
  priv max_events : Int32
  priv max_changes : Int32
  priv max_bytes : UInt64
  priv mut active : Bool
  priv mut pending : Array[RowsEvent]
  priv mut start_offset : UInt64
  priv mut expected_offset : UInt64
  priv mut event_count : Int32
  priv mut change_count : Int32
  priv mut wire_bytes : UInt64
}

///|
/// Count all events and wire bytes, including BEGIN, maps and the ending event.
/// UPDATE pairs count as one change; these are not exact heap-memory budgets.
pub fn TransactionDecoder::new(
  format : FormatDescription,
  max_events~ : Int32 = 4096,
  max_changes~ : Int32 = 10000,
  max_bytes~ : UInt64 = 67_108_864,
) -> TransactionDecoder raise DecodeError {
  guard max_events > 0 && max_changes > 0 && max_bytes > 0 else {
    raise InvalidTransactionLimits(max_events~, max_changes~, max_bytes~)
  }
  {
    tables: TableMapContext::new(format),
    max_events,
    max_changes,
    max_bytes,
    active: false,
    pending: [],
    start_offset: 0,
    expected_offset: 0,
    event_count: 0,
    change_count: 0,
    wire_bytes: 0,
  }
}

///|
pub fn TransactionDecoder::is_active(self : TransactionDecoder) -> Bool {
  self.active
}

///|
fn TransactionDecoder::discard(self : TransactionDecoder) -> Unit {
  self.tables.clear()
  // Replace, rather than mutate, the array that may back a committed snapshot.
  self.pending = []
  self.active = false
  self.start_offset = 0
  self.expected_offset = 0
  self.event_count = 0
  self.change_count = 0
  self.wire_bytes = 0
}

///|
/// Feed one framed event; following bytes are not consumed. The caller must
/// feed every event in order inside an active span, using physical offsets.
/// Recognize QUERY, XID, TABLE_MAP and ordinary ROWS v2 only. Missing BEGIN,
/// nested BEGIN, gaps, duplicates, corruption and unsupported input discard
/// the entire pending transaction and table scope before raising.
/// Signedness is needed only for ROWS and is passed to the row decoder.
/// No pending changes are returned before commit; rollback returns only counts.
pub fn TransactionDecoder::feed(
  self : TransactionDecoder,
  data : BytesView,
  file_offset~ : UInt64,
  integer_unsigned~ : ReadOnlyArray[Bool?] = [],
) -> TransactionStep raise DecodeError {
  errdefer self.discard()
  let header = EventHeader::parse(data, file_offset~)
  guard header.event_type == 2 ||
    header.event_type == 16 ||
    header.event_type == 19 ||
    (header.event_type >= 30 && header.event_type <= 32) else {
    raise UnsupportedTransactionEvent(
      file_offset~,
      event_type=header.event_type,
    )
  }
  ignore(self.tables.format.payload(data, file_offset~))
  guard file_offset <= 0xffffffffffffffffUL - header.event_size.to_uint64() else {
    raise InvalidTransactionEvent(
      file_offset~,
      reason="physical event offset range overflows UInt64",
    )
  }
  let boundary = if header.event_type == 2 || header.event_type == 16 {
    Some(
      TransactionBoundary::parse(self.tables.format, data, file_offset~).action,
    )
  } else {
    None
  }
  if self.active {
    guard file_offset == self.expected_offset else {
      raise InvalidTransactionState(
        file_offset~,
        reason="gap or overlap inside active transaction",
      )
    }
    guard boundary != Some(Begin) else {
      raise InvalidTransactionState(file_offset~, reason="nested BEGIN")
    }
  } else {
    guard boundary == Some(Begin) else {
      raise InvalidTransactionState(
        file_offset~,
        reason="transaction must start with explicit BEGIN",
      )
    }
    self.active = true
    self.start_offset = file_offset
  }
  guard self.event_count < self.max_events else {
    raise TransactionLimitExceeded(file_offset~, reason="event count exceeded")
  }
  guard header.event_size.to_uint64() <= self.max_bytes - self.wire_bytes else {
    raise TransactionLimitExceeded(
      file_offset~,
      reason="wire-byte budget exceeded",
    )
  }
  self.event_count += 1
  self.wire_bytes += header.event_size.to_uint64()
  self.expected_offset = file_offset + header.event_size.to_uint64()
  match boundary {
    Some(Commit) | Some(Xid(_)) => {
      let transaction = CommittedTransaction::{
        start_offset: self.start_offset,
        end_offset: self.expected_offset,
        xid: match boundary {
          Some(Xid(value)) => Some(value)
          _ => None
        },
        events: ReadOnlyArray::from_array(self.pending),
        event_count: self.event_count,
        change_count: self.change_count,
        wire_bytes: self.wire_bytes,
      }
      self.discard()
      { header, outcome: Some(Committed(transaction)), }
    }
    Some(Rollback) => {
      let outcome = RolledBack(
        start_offset=self.start_offset,
        end_offset=self.expected_offset,
        discarded_changes=self.change_count,
      )
      self.discard()
      { header, outcome: Some(outcome), }
    }
    _ => {
      if header.event_type == 19 {
        ignore(self.tables.apply(data, file_offset~))
      } else if header.event_type >= 30 && header.event_type <= 32 {
        let rows = self.tables.decode_rows(
          data,
          integer_unsigned~,
          file_offset~,
        )
        guard rows.changes.length() <= self.max_changes - self.change_count else {
          raise TransactionLimitExceeded(
            file_offset~,
            reason="row-change count exceeded",
          )
        }
        self.change_count += rows.changes.length()
        self.pending.push(rows)
      }
      { header, outcome: None, }
    }
  }
}

///|
/// Call at EOF. An unfinished transaction is discarded and reported, never
/// emitted as committed. Construct a fresh decoder for another file/format.
pub fn TransactionDecoder::finish(
  self : TransactionDecoder,
) -> Unit raise DecodeError {
  errdefer self.discard()
  guard !self.active else {
    raise IncompleteTransaction(start_offset=self.start_offset)
  }
}
