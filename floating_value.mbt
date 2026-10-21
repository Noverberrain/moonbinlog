// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// The original binary precision, without decimal rounding or widening FLOAT.
pub(all) enum FloatingValue {
  Single(Float)
  DoublePrecision(Double)
} derive(Debug, Eq)

///|
pub extend FloatingValue with Eq::{equal, not_equal}

///|
pub extend FloatingValue with @debug.Debug::{to_repr}

///|
/// A finite value, its raw IEEE bits (low 32 for FLOAT), and bytes consumed.
/// Bits preserve negative zero independently of numeric equality or printing.
pub struct DecodedFloating {
  value : FloatingValue
  bits : UInt64
  bytes_read : Int32
} derive(Debug, Eq)

///|
pub extend DecodedFloating with Eq::{equal, not_equal}

///|
pub extend DecodedFloating with @debug.Debug::{to_repr}

///|
/// Decode a present, non-NULL FLOAT (4) or DOUBLE (5), little-endian IEEE 754.
/// Require a one-byte metadata width of 4 or 8 respectively; reject NaN/Inf
/// with raw bits in the error. Preserve signed zero and finite subnormals.
/// `file_offset` locates this field's first byte; `column_index` is zero-based.
/// No UNSIGNED schema constraint, SQL rounding or NULL bitmap is inferred.
/// Trailing input is untouched; bytes_read is 4 or 8.
pub fn TableColumn::decode_floating(
  self : TableColumn,
  data : BytesView,
  file_offset~ : UInt64,
  column_index~ : Int32,
) -> DecodedFloating raise DecodeError {
  let width = match self.wire_type {
    4 => 4
    5 => 8
    wire_type =>
      raise UnsupportedFloatingColumn(file_offset~, column_index~, wire_type~)
  }
  guard self.metadata.length() == 1 && self.metadata[0].to_int() == width else {
    raise InvalidFloatingMetadata(
      file_offset~,
      column_index~,
      expected_width=width,
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
  let mut bits = 0UL
  for i in 0..<width {
    bits = bits | (data[i].to_uint().to_uint64() << (8 * i))
  }
  let exponent_mask = if width == 4 {
    0x7f800000UL
  } else {
    0x7ff0000000000000UL
  }
  guard (bits & exponent_mask) != exponent_mask else {
    raise NonFiniteFloatingValue(
      file_offset~,
      column_index~,
      wire_type=self.wire_type,
      bits~,
    )
  }
  let value = if width == 4 {
    Single(Float::reinterpret_from_uint(bits.to_uint()))
  } else {
    DoublePrecision(bits.reinterpret_as_double())
  }
  { value, bits, bytes_read: width, }
}
