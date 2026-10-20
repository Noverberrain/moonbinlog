// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// A wire type, its exact metadata bytes, and the column's nullable flag.
/// This does not supply its SQL name, signedness, charset or decoded row value.
pub struct TableColumn {
  wire_type : Byte
  metadata : Bytes
  nullable : Bool
} derive(Debug, Eq)

///|
pub extend TableColumn with Eq::{equal, not_equal}

///|
pub extend TableColumn with @debug.Debug::{to_repr}

///|
/// A structurally checked optional metadata TLV, preserved without interpretation.
pub struct TableMetadataField {
  field_type : Byte
  value : Bytes
} derive(Debug, Eq)

///|
pub extend TableMetadataField with Eq::{equal, not_equal}

///|
pub extend TableMetadataField with @debug.Debug::{to_repr}

///|
/// An immutable MySQL 8.0 TABLE_MAP_EVENT (type 19).
pub struct TableMap {
  header : EventHeader
  table_id : UInt64
  flags : UInt16
  database : String
  table : String
  columns : ReadOnlyArray[TableColumn]
  optional_metadata : ReadOnlyArray[TableMetadataField]
} derive(Debug, Eq)

///|
pub extend TableMap with Eq::{equal, not_equal}

///|
pub extend TableMap with @debug.Debug::{to_repr}

///|
/// Decode one complete, checksum-validated table map using an existing format.
/// Only the 8-byte table-map post-header is supported. Unknown wire types fail.
/// Optional metadata is preserved as TLVs, not interpreted as a SQL schema.
pub fn TableMap::parse(
  format : FormatDescription,
  data : BytesView,
  file_offset~ : UInt64,
  max_columns~ : Int32 = 1024,
  max_event_size~ : UInt32 = 16_777_216,
) -> TableMap raise DecodeError {
  guard max_columns > 0 else { raise InvalidColumnLimit(max_columns~) }
  let header = EventHeader::parse(data, file_offset~, max_event_size~)
  guard header.event_type == 19 else {
    raise UnexpectedEventType(
      file_offset~,
      expected=19,
      actual=header.event_type,
    )
  }
  let body = format.payload(data, file_offset~, max_event_size~)
  guard format.post_header_lengths.get(18) is Some(8) else {
    raise InvalidTableMap(
      file_offset~,
      body_offset=0,
      reason="unsupported table-map post-header length",
    )
  }
  let reader = MapReader::{ data: body, base: 0, file_offset, position: 0, }
  let table_id = reader.uint_le(6)
  let flags = read_u16_le(reader.take(2), 0)
  let database = reader.name()
  let table = reader.name()
  let count = reader.packed_length()
  guard count > 0 else { raise reader.invalid("table has no columns") }
  guard count <= max_columns.reinterpret_as_uint().to_uint64() else {
    raise ColumnLimitExceeded(file_offset~, count~, max_columns~)
  }
  let column_count = count.to_int()
  let types = reader.take(column_count)
  let metadata = reader.sized_field()
  let metadata_start = reader.position - metadata.length()
  let null_bytes = column_count / 8 +
    (if column_count % 8 == 0 { 0 } else { 1 })
  let nullable = reader.take(null_bytes)
  let metadata_reader = MapReader::{
    data: metadata,
    base: metadata_start,
    file_offset,
    position: 0,
  }
  let columns = []
  for i in 0..<column_count {
    let length = column_metadata_length(types[i], file_offset~, column_index=i)
    columns.push(TableColumn::{
      wire_type: types[i],
      metadata: metadata_reader.take(length).to_owned(),
      nullable: ((nullable[i / 8].to_uint() >> (i % 8)) & 1) != 0,
    })
  }
  guard metadata_reader.remaining() == 0 else {
    raise metadata_reader.invalid("unused column metadata bytes")
  }
  let optional = []
  while reader.remaining() > 0 {
    guard optional.length() < 256 else {
      raise reader.invalid("optional metadata exceeds 256 TLV fields")
    }
    let field_type = reader.byte()
    let value = reader.sized_field().to_owned()
    optional.push(TableMetadataField::{ field_type, value, })
  }
  {
    header,
    table_id,
    flags,
    database,
    table,
    columns: ReadOnlyArray::from_array(columns),
    optional_metadata: ReadOnlyArray::from_array(optional),
  }
}

///|
// Layout widths follow MySQL 8.0's read_field_metadata. Internal NEWDATE,
// VAR_STRING and typed-array representations are deliberately not guessed.
fn column_metadata_length(
  wire_type : Byte,
  file_offset~ : UInt64,
  column_index~ : Int32,
) -> Int32 raise DecodeError {
  match wire_type {
    0..<=3 | 6..<=13 => 0
    4 | 5 | 17..<=19 | 245 | 249..<=252 | 255 => 1
    15 | 16 | 246..<=248 | 254 => 2
    _ => raise UnsupportedColumnType(file_offset~, column_index~, wire_type~)
  }
}
