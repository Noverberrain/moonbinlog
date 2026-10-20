// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// Exact integers retain their signedness, including the full UInt64 range.
pub(all) enum IntegerValue {
  Signed(Int64)
  Unsigned(UInt64)
} derive(Debug, Eq)

///|
pub extend IntegerValue with Eq::{equal, not_equal}

///|
pub extend IntegerValue with @debug.Debug::{to_repr}

///|
/// One non-NULL integer value and the number of bytes consumed from its view.
pub struct DecodedInteger {
  value : IntegerValue
  bytes_read : Int32
} derive(Debug, Eq)

///|
pub extend DecodedInteger with Eq::{equal, not_equal}

///|
pub extend DecodedInteger with @debug.Debug::{to_repr}

///|
/// Decode a present, non-NULL TINY/SHORT/INT24/LONG/LONGLONG column value.
/// `unsigned` is mandatory: a wire type alone does not determine signedness.
/// `file_offset` locates this field's first byte; `column_index` is zero-based.
/// Extra bytes in the view are left for the next field. nullable is a schema
/// capability, not the row's NULL marker; row bitmaps must be handled by callers.
pub fn TableColumn::decode_integer(
  self : TableColumn,
  data : BytesView,
  unsigned~ : Bool,
  file_offset~ : UInt64,
  column_index~ : Int32,
) -> DecodedInteger raise DecodeError {
  let width = match self.wire_type {
    1 => 1
    2 => 2
    9 => 3
    3 => 4
    8 => 8
    wire_type =>
      raise UnsupportedIntegerColumn(file_offset~, column_index~, wire_type~)
  }
  guard data.length() >= width else {
    raise TruncatedColumnValue(
      file_offset~,
      column_index~,
      expected=width,
      actual=data.length(),
    )
  }
  let mut bits = 0UL
  for i in 0..<width {
    bits = bits | (data[i].to_uint().to_uint64() << (8 * i))
  }
  let value = if unsigned {
    Unsigned(bits)
  } else {
    // Extend the field's sign bit, but never shift UInt64 by its entire width.
    let extended = if width < 8 && (data[width - 1].to_uint() & 0x80) != 0 {
      bits | (0xffffffffffffffffUL << (8 * width))
    } else {
      bits
    }
    Signed(extended.reinterpret_as_int64())
  }
  { value, bytes_read: width, }
}
