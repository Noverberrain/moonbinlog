// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// Bounded table-id cache associated with one format and caller-managed scope.
/// Call clear at statement ends and reset for a new file or format description.
/// Any failed apply clears cached maps to prevent reuse of stale definitions.
pub struct TableMapContext {
  priv tables : Map[UInt64, TableMap]
  priv mut format : FormatDescription
  priv max_tables : Int32
  priv max_bytes : UInt64
  priv mut byte_size : UInt64
}

///|
/// `max_bytes` bounds retained wire-event sizes, not exact heap usage.
pub fn TableMapContext::new(
  format : FormatDescription,
  max_tables~ : Int32 = 1024,
  max_bytes~ : UInt64 = 33_554_432,
) -> TableMapContext raise DecodeError {
  guard max_tables > 0 && max_bytes > 0 else {
    raise InvalidTableContextLimit(max_tables~, max_bytes~)
  }
  { tables: {}, format, max_tables, max_bytes, byte_size: 0, }
}

///|
pub fn TableMapContext::length(self : TableMapContext) -> Int32 {
  self.tables.length()
}

///|
pub fn TableMapContext::get(
  self : TableMapContext,
  table_id : UInt64,
) -> TableMap? {
  self.tables.get(table_id)
}

///|
pub fn TableMapContext::clear(self : TableMapContext) -> Unit {
  self.tables.clear()
  self.byte_size = 0
}

///|
pub fn TableMapContext::reset(
  self : TableMapContext,
  format : FormatDescription,
) -> Unit {
  self.clear()
  self.format = format
}

///|
/// Validate and install a map. Reusing an id replaces its earlier definition.
/// Invalid input and quota failures invalidate the entire current map scope.
pub fn TableMapContext::apply(
  self : TableMapContext,
  data : BytesView,
  file_offset~ : UInt64,
  max_columns~ : Int32 = 1024,
  max_event_size~ : UInt32 = 16_777_216,
) -> TableMap raise DecodeError {
  errdefer self.clear()
  let table = TableMap::parse(
    self.format,
    data,
    file_offset~,
    max_columns~,
    max_event_size~,
  )
  let previous_size = match self.tables.get(table.table_id) {
    Some(previous) => previous.header.event_size.to_uint64()
    None => 0UL
  }
  guard previous_size > 0 || self.tables.length() < self.max_tables else {
    raise TableContextLimitExceeded(file_offset~, reason="too many table ids")
  }
  let byte_size = self.byte_size -
    previous_size +
    table.header.event_size.to_uint64()
  guard byte_size <= self.max_bytes else {
    raise TableContextLimitExceeded(
      file_offset~,
      reason="retained event-byte budget exceeded",
    )
  }
  self.tables[table.table_id] = table
  self.byte_size = byte_size
  table
}
