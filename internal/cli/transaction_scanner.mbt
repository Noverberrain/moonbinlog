// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
priv enum TransactionCore {
  Plain(@moonbinlog.TransactionDecoder)
  Bound(@moonbinlog.GtidTransactionDecoder)
}

///|
fn TransactionCore::is_active(self : TransactionCore) -> Bool {
  match self {
    Plain(decoder) => decoder.is_active()
    Bound(decoder) => decoder.is_active()
  }
}

///|
fn TransactionCore::finish(
  self : TransactionCore,
) -> Unit raise @moonbinlog.DecodeError {
  match self {
    Plain(decoder) => decoder.finish()
    Bound(decoder) => decoder.finish()
  }
}

///|
/// File dispatch for explicit transactional RBR spans. Envelopes may only be
/// skipped while idle; no pending span survives a format change or failure.
pub struct TransactionScanner {
  priv schema : @moonbinlog.SchemaConfig
  priv filter : TableFilter
  priv with_gtid : Bool
  priv mut failed : Bool
  priv mut gtid : @moonbinlog.GtidTransactionOutcome?
  priv mut matched : Bool
  priv mut selected : Bool
  priv max_events : Int32
  priv max_changes : Int32
  priv max_bytes : UInt64
  priv mut state : (TransactionCore, @moonbinlog.TableMapContext)?
}

///|
pub fn TransactionScanner::new(
  schema : @moonbinlog.SchemaConfig,
  filter~ : TableFilter = TableFilter::all(),
  with_gtid~ : Bool = false,
  max_events~ : Int32 = 4096,
  max_changes~ : Int32 = 10000,
  max_bytes~ : UInt64 = 67_108_864,
) -> TransactionScanner {
  {
    schema,
    filter,
    with_gtid,
    failed: false,
    gtid: None,
    matched: false,
    selected: false,
    max_events,
    max_changes,
    max_bytes,
    state: None,
  }
}

///|
/// Whether the outcome from the last feed matches. Reset by the next feed.
/// With an active filter only verified ROWS can select a complete span.
pub fn TransactionScanner::outcome_selected(self : TransactionScanner) -> Bool {
  self.selected
}

///|
/// Bound metadata for the last completed feed, reset by the next feed/error.
pub fn TransactionScanner::gtid_outcome(
  self : TransactionScanner,
) -> @moonbinlog.GtidTransactionOutcome? {
  self.gtid
}

///|
pub fn TransactionScanner::feed(
  self : TransactionScanner,
  event : @moonbinlog.BinlogFileEvent,
) -> @moonbinlog.TransactionOutcome? raise {
  guard !self.failed else { raise @moonbinlog.GtidTransactionFailed }
  errdefer {
    self.state = None
    self.matched = false
    self.selected = false
    self.gtid = None
    self.failed = self.with_gtid
  }
  self.selected = false
  self.gtid = None
  let file_offset = event.header.file_offset
  if event.header.event_type == 15 {
    self.finish()
    self.matched = false
    let decoder = if self.with_gtid {
      Bound(
        @moonbinlog.GtidTransactionDecoder::new(
          event.format,
          max_events=self.max_events,
          max_changes=self.max_changes,
          max_bytes=self.max_bytes,
        ),
      )
    } else {
      Plain(
        @moonbinlog.TransactionDecoder::new(
          event.format,
          max_events=self.max_events,
          max_changes=self.max_changes,
          max_bytes=self.max_bytes,
        ),
      )
    }
    self.state = Some((decoder, @moonbinlog.TableMapContext::new(event.format)))
    return None
  }
  guard self.state is Some((decoder, tables)) else {
    raise @moonbinlog.InvalidTransactionState(
      file_offset~,
      reason="format description required",
    )
  }
  let kind = event.header.event_type
  if !decoder.is_active() &&
    (
      kind == 3 ||
      kind == 4 ||
      kind == 27 ||
      (!self.with_gtid && (kind == 33 || kind == 34)) ||
      kind == 35
    ) {
    // Envelope bodies are not interpreted, nor used as transaction identities.
    tables.clear()
    return None
  }
  let mut signs : ReadOnlyArray[Bool?] = []
  let mut event_matches = false
  if kind == 19 && decoder.is_active() {
    let table = tables.apply(event.raw, file_offset~)
    self.schema.bind(table) |> ignore
  } else if kind >= 30 && kind <= 32 && decoder.is_active() {
    guard event.body.length() >= 10 else {
      raise @moonbinlog.InvalidRowsEvent(
        file_offset~,
        body_offset=0,
        reason="truncated ROWS post-header",
      )
    }
    let mut table_id = 0UL
    for i in 0..<6 {
      table_id = table_id | (event.body[i].to_uint().to_uint64() << (i * 8))
    }
    guard tables.get(table_id) is Some(table) else {
      raise @moonbinlog.MissingTableMap(file_offset~, table_id~)
    }
    signs = self.schema.bind(table).integer_unsigned
    event_matches = self.filter.matches(table.database, table.table)
  }
  let outcome = match decoder {
    Plain(decoder) =>
      decoder.feed(event.raw, file_offset~, integer_unsigned=signs).outcome
    Bound(decoder) => {
      let step = decoder.feed(event.raw, file_offset~, integer_unsigned=signs)
      self.gtid = step.outcome
      step.outcome.map(value => value.transaction)
    }
  }
  self.matched = self.matched || event_matches
  if outcome is Some(_) {
    self.selected = !self.filter.is_active() || self.matched
    self.matched = false
  }
  // The decoding core owns statement cleanup. Mirror it only for the schema
  // lookup cache; never cache bindings across statement/transaction scopes.
  if outcome is Some(_) ||
    (kind >= 30 && kind <= 32 && (event.body[6].to_int() & 1) != 0) {
    tables.clear()
  }
  outcome
}

///|
pub fn TransactionScanner::finish(self : TransactionScanner) -> Unit raise {
  guard !self.failed else { raise @moonbinlog.GtidTransactionFailed }
  errdefer {
    self.state = None
    self.matched = false
    self.selected = false
    self.gtid = None
    self.failed = self.with_gtid
  }
  if self.state is Some((decoder, _)) {
    decoder.finish()
  }
}
