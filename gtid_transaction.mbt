// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// A completed explicit transactional span with its preceding GTID event.
/// The outer range/count/bytes include the GTID prefix. The nested transaction
/// retains its existing BEGIN-based range and rollback/commit semantics.
/// Anonymous prefixes remain anonymous; no executed-GTID set is updated.
pub struct GtidTransactionOutcome {
  gtid : GtidEvent
  transaction : TransactionOutcome
  start_offset : UInt64
  end_offset : UInt64
  event_count : Int32
  wire_bytes : UInt64
} derive(Debug, Eq)

///|
pub extend GtidTransactionOutcome with Eq::{equal, not_equal}

///|
pub extend GtidTransactionOutcome with @debug.Debug::{to_repr}

///|
/// No outcome is exposed until the inner span reaches COMMIT/XID/ROLLBACK.
pub struct GtidTransactionStep {
  header : EventHeader
  outcome : GtidTransactionOutcome?
} derive(Debug, Eq)

///|
pub extend GtidTransactionStep with Eq::{equal, not_equal}

///|
pub extend GtidTransactionStep with @debug.Debug::{to_repr}

///|
/// Strict GTID -> BEGIN -> transactional RBR -> COMMIT/XID/ROLLBACK wrapper.
/// Every event within a span must be fed at contiguous physical offsets.
/// Any feed/finish error permanently fails this instance and discards pending
/// identity, rows and table mappings. Construct a fresh decoder to recover.
pub struct GtidTransactionDecoder {
  priv format : FormatDescription
  priv decoder : TransactionDecoder
  priv max_events : Int32
  priv max_bytes : UInt64
  priv mut failed : Bool
  priv mut pending : GtidEvent?
  priv mut expected_offset : UInt64
  priv mut event_count : Int32
  priv mut wire_bytes : UInt64
}

///|
/// Positive budgets include the GTID prefix, BEGIN, maps, rows and terminal
/// event. max_changes uses the existing row-change counting rules.
pub fn GtidTransactionDecoder::new(
  format : FormatDescription,
  max_events~ : Int32 = 4096,
  max_changes~ : Int32 = 10000,
  max_bytes~ : UInt64 = 67_108_864,
) -> GtidTransactionDecoder raise DecodeError {
  let decoder = TransactionDecoder::new(
    format,
    max_events~,
    max_changes~,
    max_bytes~,
  )
  {
    format,
    decoder,
    max_events,
    max_bytes,
    failed: false,
    pending: None,
    expected_offset: 0,
    event_count: 0,
    wire_bytes: 0,
  }
}

///|
/// True from a valid GTID prefix until its explicit span ends, including the
/// interval before BEGIN. False after an error, which still prevents reuse.
pub fn GtidTransactionDecoder::is_active(self : GtidTransactionDecoder) -> Bool {
  self.pending is Some(_)
}

///|
fn GtidTransactionDecoder::clear(self : GtidTransactionDecoder) -> Unit {
  self.decoder.discard()
  self.pending = None
  self.expected_offset = 0
  self.event_count = 0
  self.wire_bytes = 0
}

///|
fn GtidTransactionDecoder::abort(self : GtidTransactionDecoder) -> Unit {
  self.clear()
  self.failed = true
}

///|
/// Feed one complete event (trailing input outside its declared size is ignored).
/// Only an idle GTID/anonymous GTID can begin a span; it must immediately precede
/// a supported explicit BEGIN. Other events delegate to TransactionDecoder.
/// Signedness is needed only for ROWS. Framing retains the existing 16 MiB
/// per-event limit. Logical clocks/transaction_length do not control traversal.
pub fn GtidTransactionDecoder::feed(
  self : GtidTransactionDecoder,
  data : BytesView,
  file_offset~ : UInt64,
  integer_unsigned~ : ReadOnlyArray[Bool?] = [],
) -> GtidTransactionStep raise DecodeError {
  guard !self.failed else { raise GtidTransactionFailed }
  errdefer self.abort()
  let header = EventHeader::parse(data, file_offset~)
  guard file_offset <= 0xffffffffffffffffUL - header.event_size.to_uint64() else {
    raise InvalidGtidTransactionState(
      file_offset~,
      reason="physical event offset range overflows UInt64",
    )
  }
  guard self.event_count < self.max_events else {
    raise TransactionLimitExceeded(
      file_offset~,
      reason="GTID span event count exceeded",
    )
  }
  guard header.event_size.to_uint64() <= self.max_bytes - self.wire_bytes else {
    raise TransactionLimitExceeded(
      file_offset~,
      reason="GTID span wire-byte budget exceeded",
    )
  }
  let outcome = if self.pending is Some(gtid) {
    guard file_offset == self.expected_offset else {
      raise InvalidGtidTransactionState(
        file_offset~,
        reason="gap or overlap in GTID span",
      )
    }
    let step = self.decoder.feed(data, file_offset~, integer_unsigned~)
    step.outcome.map(transaction => GtidTransactionOutcome::{
      gtid,
      transaction,
      start_offset: gtid.header.file_offset,
      end_offset: file_offset + header.event_size.to_uint64(),
      event_count: self.event_count + 1,
      wire_bytes: self.wire_bytes + header.event_size.to_uint64(),
    })
  } else {
    guard header.event_type == 33 || header.event_type == 34 else {
      raise InvalidGtidTransactionState(
        file_offset~,
        reason="GTID event required before BEGIN",
      )
    }
    self.pending = Some(GtidEvent::parse(self.format, data, file_offset~))
    None
  }
  if outcome is Some(_) {
    self.clear()
  } else {
    self.expected_offset = file_offset + header.event_size.to_uint64()
    self.event_count += 1
    self.wire_bytes += header.event_size.to_uint64()
  }
  { header, outcome, }
}

///|
/// Call at EOF or before a file/format boundary. A lone GTID prefix is also an
/// incomplete span. Success leaves an idle instance usable; errors are final.
pub fn GtidTransactionDecoder::finish(
  self : GtidTransactionDecoder,
) -> Unit raise DecodeError {
  guard !self.failed else { raise GtidTransactionFailed }
  errdefer self.abort()
  if self.pending is Some(gtid) {
    raise IncompleteGtidTransaction(start_offset=gtid.header.file_offset)
  }
}
