// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// An uncommitted row change; transaction outcome must be handled separately.
pub(all) enum RowChange {
  Insert(RowImage)
  Update(before~ : RowImage, after~ : RowImage)
  Delete(RowImage)
} derive(Debug, Eq)

///|
pub extend RowChange with Eq::{equal, not_equal}

///|
pub extend RowChange with @debug.Debug::{to_repr}

///|
/// One verified v2 ROWS event and an immutable snapshot of its table map.
/// Extra header bytes are preserved without interpreting NDB/partition tags.
pub struct RowsEvent {
  header : EventHeader
  table : TableMap
  flags : UInt16
  extra_data : Bytes
  columns_before : Bytes?
  columns_after : Bytes?
  changes : ReadOnlyArray[RowChange]
} derive(Debug, Eq)

///|
pub extend RowsEvent with Eq::{equal, not_equal}

///|
pub extend RowsEvent with @debug.Debug::{to_repr}

///|
/// Decode WRITE/UPDATE/DELETE_ROWS v2 (30/31/32) with a 10-byte post-header.
/// Validate framing/checksum before decoding, resolve table_id from this cache,
/// and require an exact column-count match. Ignore data after this event.
/// Signedness is the same per-table array used by decode_row_image.
/// max_rows counts changes (an UPDATE pair is one); max_row_bytes bounds each
/// image. Defaults are 1024 changes and 16 MiB per image/event.
/// Any failure clears all cached maps. A successful STMT_END_F also clears all
/// maps; the returned table snapshot remains usable. This does not commit rows.
/// Legacy, partial-JSON, compressed and dummy table-id events are unsupported.
pub fn TableMapContext::decode_rows(
  self : TableMapContext,
  data : BytesView,
  integer_unsigned~ : ReadOnlyArray[Bool?],
  file_offset~ : UInt64,
  max_rows~ : Int32 = 1024,
  max_row_bytes~ : Int32 = 16_777_216,
  max_event_size~ : UInt32 = 16_777_216,
) -> RowsEvent raise DecodeError {
  errdefer self.clear()
  guard max_rows > 0 else { raise InvalidRowsLimit(max_rows~) }
  guard max_row_bytes >= 0 && max_row_bytes <= 2_147_483_643 else {
    raise InvalidRowImageLimit(max_bytes=max_row_bytes)
  }
  let header = EventHeader::parse(data, file_offset~, max_event_size~)
  guard header.event_type >= 30 && header.event_type <= 32 else {
    raise UnsupportedRowsEvent(file_offset~, event_type=header.event_type)
  }
  let body = self.format.payload(data, file_offset~, max_event_size~)
  let reader = RowsReader::{ data: body, file_offset, position: 0, }
  guard self.format.post_header_lengths.get(header.event_type.to_int() - 1)
    is Some(10) else {
    raise reader.invalid("unsupported ROWS post-header length")
  }
  guard file_offset <= 0xffffffffffffffffUL - header.event_size.to_uint64() else {
    raise reader.invalid("physical event offset range overflows UInt64")
  }
  let table_id = reader.uint_le(6)
  let flags = read_u16_le(reader.take(2), 0)
  let extra_length = read_u16_le(reader.take(2), 0)
    .to_uint()
    .reinterpret_as_int()
  guard extra_length >= 2 else {
    raise reader.invalid(
      "extra-header length must include its two length bytes",
    )
  }
  let extra_data = reader.take(extra_length - 2).to_owned()
  let count = reader.packed_length()
  guard self.tables.get(table_id) is Some(table) else {
    raise MissingTableMap(file_offset~, table_id~)
  }
  guard count == table.columns.length().reinterpret_as_uint().to_uint64() else {
    raise reader.invalid("event column count does not match table map")
  }
  guard integer_unsigned.length() == table.columns.length() else {
    raise InvalidRowImage(
      file_offset~,
      reason="signedness array length does not match table columns",
    )
  }
  let bitmap_length = table.columns.length() / 8 +
    (if table.columns.length() % 8 == 0 { 0 } else { 1 })
  let first = reader.take(bitmap_length)
  let second = if header.event_type == 31 {
    reader.take(bitmap_length)
  } else {
    first
  }
  let changes = []
  while reader.remaining() > 0 {
    guard changes.length() < max_rows else {
      raise RowsLimitExceeded(file_offset~, max_rows~)
    }
    let start = reader.position
    let image = reader.image(table, first, integer_unsigned, max_row_bytes)
    let change = match header.event_type {
      30 => Insert(image)
      31 => {
        let after = reader.image(table, second, integer_unsigned, max_row_bytes)
        Update(before=image, after~)
      }
      _ => Delete(image)
    }
    guard reader.position > start else {
      raise reader.invalid("row change made no progress")
    }
    changes.push(change)
  }
  let result = RowsEvent::{
    header,
    table,
    flags,
    extra_data,
    columns_before: if header.event_type == 30 {
      None
    } else {
      Some(first.to_owned())
    },
    columns_after: if header.event_type == 32 {
      None
    } else {
      Some(second.to_owned())
    },
    changes: ReadOnlyArray::from_array(changes),
  }
  if (flags.to_uint() & 1) != 0 {
    self.clear()
  }
  result
}
