// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// Complete (not partial-update) MySQL binary JSON, with exact integer values.
/// Object members retain binary order. Floating bits preserve negative zero.
pub(all) enum BinaryJsonValue {
  Null
  Boolean(Bool)
  Integer(IntegerValue)
  DoubleNumber(value~ : Double, bits~ : UInt64)
  Text(String)
  Array(ReadOnlyArray[BinaryJsonValue])
  Object(ReadOnlyArray[(String, BinaryJsonValue)])
} derive(Debug, Eq)

///|
pub extend BinaryJsonValue with Eq::{equal, not_equal}

///|
pub extend BinaryJsonValue with @debug.Debug::{to_repr}

///|
pub struct DecodedJson {
  value : BinaryJsonValue
  bytes_read : Int32
} derive(Debug, Eq)

///|
pub extend DecodedJson with Eq::{equal, not_equal}

///|
pub extend DecodedJson with @debug.Debug::{to_repr}

///|
/// Decode MYSQL_TYPE_JSON (245) with its 1..4 byte length prefix. The byte
/// budget excludes the prefix; depth counts the root as one (hard cap 128),
/// nodes count values including containers. Opaque types and empty documents
/// are rejected. String bytes must be UTF-8; no replacement or BOM stripping.
pub fn TableColumn::decode_json(
  self : TableColumn,
  data : BytesView,
  file_offset~ : UInt64,
  column_index~ : Int32,
  max_value_bytes~ : Int32 = 16_777_216,
  max_depth~ : Int32 = 64,
  max_nodes~ : Int32 = 65536,
) -> DecodedJson raise DecodeError {
  guard max_value_bytes >= 0 &&
    max_value_bytes <= 2_147_483_643 &&
    max_depth > 0 &&
    max_depth <= 128 &&
    max_nodes > 0 else {
    raise InvalidJsonLimits(max_value_bytes~, max_depth~, max_nodes~)
  }
  guard self.wire_type == 245 else {
    raise UnsupportedJsonColumn(
      file_offset~,
      column_index~,
      wire_type=self.wire_type,
    )
  }
  guard self.metadata.length() == 1 &&
    self.metadata[0] >= 1 &&
    self.metadata[0] <= 4 else {
    raise InvalidJsonMetadata(file_offset~, column_index~)
  }
  let width = self.metadata[0].to_int()
  guard data.length() >= width else {
    raise TruncatedColumnValue(
      file_offset~,
      column_index~,
      expected=width,
      actual=data.length(),
    )
  }
  let mut length = 0UL
  for i in 0..<width {
    length = length | (data[i].to_uint().to_uint64() << (i * 8))
  }
  guard length <= max_value_bytes.reinterpret_as_uint().to_uint64() else {
    raise JsonLimitExceeded(
      file_offset~,
      column_index~,
      reason="JSON byte budget exceeded",
    )
  }
  let bytes_read = width + length.to_int()
  guard data.length() >= bytes_read else {
    raise TruncatedColumnValue(
      file_offset~,
      column_index~,
      expected=bytes_read,
      actual=data.length(),
    )
  }
  guard file_offset <=
    0xffffffffffffffffUL - bytes_read.reinterpret_as_uint().to_uint64() else {
    raise InvalidJsonValue(
      file_offset~,
      column_index~,
      value_offset=0,
      reason="physical offset range overflows",
    )
  }
  let reader = JsonBinaryReader::{
    data: data[width:bytes_read],
    file_offset,
    column_index,
    max_depth,
    max_nodes,
    nodes: 0,
  }
  guard length > 0 else {
    raise reader.invalid(0, "empty binary JSON document")
  }
  let size = reader.extent(reader.data[0], 1, reader.data.length())
  guard size == reader.data.length() - 1 else {
    raise reader.invalid(1 + size, "trailing JSON document bytes")
  }
  let value = reader.value(reader.data[0], 1, reader.data.length(), 1)
  { value, bytes_read, }
}
