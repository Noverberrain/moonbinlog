// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
pub(all) suberror RowScanError {
  MissingFormat(file_offset~ : UInt64)
  UnsupportedEvent(file_offset~ : UInt64, event_type~ : Byte)
  InvalidOutput(String)
} derive(Debug)

///|
pub extend RowScanError with @debug.Debug::{to_repr}

///|
/// CLI-only row dispatch. No commit inference, GTID/SQL interpretation or cache
/// recovery by skipping unknown events. Schema is checked on every TABLE_MAP.
pub struct RowScanner {
  priv schema : @moonbinlog.SchemaConfig
  priv max_event_size : UInt32
  priv mut context : @moonbinlog.TableMapContext?
}

///|
pub fn RowScanner::new(
  schema : @moonbinlog.SchemaConfig,
  max_event_size~ : UInt32 = 16_777_216,
) -> RowScanner {
  { schema, max_event_size, context: None, }
}

///|
fn RowScanner::clear(self : RowScanner) -> Unit {
  if self.context is Some(context) {
    context.clear()
  }
}

///|
/// Feed a fully framed/checksummed file event. Return whole ROWS events only.
pub fn RowScanner::feed(
  self : RowScanner,
  event : @moonbinlog.BinlogFileEvent,
) -> (@moonbinlog.RowsEvent, @moonbinlog.BoundTableSchema)? raise {
  errdefer self.clear()
  let file_offset = event.header.file_offset
  if event.header.event_type == 15 {
    self.context = Some(@moonbinlog.TableMapContext::new(event.format))
    return None
  }
  guard self.context is Some(context) else { raise MissingFormat(file_offset~) }
  match event.header.event_type {
    19 => {
      let table = context.apply(
        event.raw,
        file_offset~,
        max_event_size=self.max_event_size,
      )
      self.schema.bind(table) |> ignore
      None
    }
    30..<=32 => {
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
      guard context.get(table_id) is Some(table) else {
        raise @moonbinlog.MissingTableMap(file_offset~, table_id~)
      }
      let bound = self.schema.bind(table)
      let rows = context.decode_rows(
        event.raw,
        file_offset~,
        integer_unsigned=bound.integer_unsigned,
        max_event_size=self.max_event_size,
      )
      Some((rows, bound))
    }
    // Explicitly allowed envelopes. Clear maps; their body semantics and
    // transaction effects are not interpreted in this unconfirmed row mode.
    2 | 3 | 4 | 16 | 27 | 33 | 34 | 35 => {
      context.clear()
      None
    }
    _ =>
      raise UnsupportedEvent(file_offset~, event_type=event.header.event_type)
  }
}
