// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// Raw ordinal or membership bits. Names and member counts are not inferred.
pub(all) enum EnumSetValue {
  EnumIndex(UInt16)
  SetMask(UInt64)
} derive(Debug, Eq)

///|
pub extend EnumSetValue with Eq::{equal, not_equal}

///|
pub extend EnumSetValue with @debug.Debug::{to_repr}

///|
pub struct DecodedEnumSet {
  value : EnumSetValue
  bytes_read : Int32
} derive(Debug, Eq)

///|
pub extend DecodedEnumSet with Eq::{equal, not_equal}

///|
pub extend DecodedEnumSet with @debug.Debug::{to_repr}

///|
/// Decode present, non-NULL ENUM/SET in canonical STRING (254) representation.
/// Metadata is [247, 1|2] for ENUM, [248, 1|2|3|4|8] for SET. Field values
/// are little-endian, without a string length prefix. Preserve ENUM index 0
/// and empty SET mask 0 as values. Names/member counts are not decoded here.
/// `file_offset` is the field's first byte; `column_index` is zero-based.
/// Trailing input is not consumed; callers handle row presence/NULL bitmaps.
pub fn TableColumn::decode_enum_set(
  self : TableColumn,
  data : BytesView,
  file_offset~ : UInt64,
  column_index~ : Int32,
) -> DecodedEnumSet raise DecodeError {
  guard self.wire_type == 254 else {
    raise UnsupportedEnumSetColumn(
      file_offset~,
      column_index~,
      wire_type=self.wire_type,
    )
  }
  guard self.metadata.length() == 2 else {
    raise InvalidEnumSetMetadata(
      file_offset~,
      column_index~,
      reason="expected type and storage-width metadata",
    )
  }
  let tag = self.metadata[0].to_int()
  let width = self.metadata[1].to_int()
  let valid = match tag {
    247 => width == 1 || width == 2
    248 => width == 1 || width == 2 || width == 3 || width == 4 || width == 8
    _ => false
  }
  guard valid else {
    raise InvalidEnumSetMetadata(
      file_offset~,
      column_index~,
      reason="unsupported embedded ENUM/SET type or storage width",
    )
  }
  guard data.length() >= width else {
    raise TruncatedColumnValue(
      file_offset~,
      column_index~,
      expected=width,
      actual=data.length(),
    )
  }
  let mut raw = 0UL
  for i in 0..<width {
    raw = raw | (data[i].to_uint().to_uint64() << (8 * i))
  }
  let value = if tag == 247 { EnumIndex(raw.to_uint16()) } else { SetMask(raw) }
  { value, bytes_read: width, }
}
