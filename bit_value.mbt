// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// An unsigned BIT value and its declared width, preserving leading-zero width.
pub struct DecodedBit {
  value : UInt64
  bit_length : Int32
  bytes_read : Int32
} derive(Debug, Eq)

///|
pub extend DecodedBit with Eq::{equal, not_equal}

///|
pub extend DecodedBit with @debug.Debug::{to_repr}

///|
/// Decode a present, non-NULL BIT (16) with declared width 1..64.
/// Metadata contains remainder bits (0..7), then complete bytes (0..8).
/// The value is big-endian; unused high bits of a partial first byte are
/// ignored, matching upstream handling of padding. No shift by 64 is used.
/// `file_offset` is the field's first byte; `column_index` is zero-based.
/// bytes_read is ceil(bit_length/8); trailing input is not consumed.
/// The caller handles row presence/NULL bitmaps. BIT(1) remains an integer.
pub fn TableColumn::decode_bit(
  self : TableColumn,
  data : BytesView,
  file_offset~ : UInt64,
  column_index~ : Int32,
) -> DecodedBit raise DecodeError {
  guard self.wire_type == 16 else {
    raise UnsupportedBitColumn(
      file_offset~,
      column_index~,
      wire_type=self.wire_type,
    )
  }
  guard self.metadata.length() == 2 else {
    raise InvalidBitMetadata(
      file_offset~,
      column_index~,
      reason="expected remainder and byte-count metadata",
    )
  }
  let remainder = self.metadata[0].to_int()
  let whole_bytes = self.metadata[1].to_int()
  let bit_length = whole_bytes * 8 + remainder
  guard remainder <= 7 && bit_length >= 1 && bit_length <= 64 else {
    raise InvalidBitMetadata(
      file_offset~,
      column_index~,
      reason="BIT width must be 1..64 with remainder 0..7",
    )
  }
  let bytes_read = whole_bytes + (if remainder == 0 { 0 } else { 1 })
  guard data.length() >= bytes_read else {
    raise TruncatedColumnValue(
      file_offset~,
      column_index~,
      expected=bytes_read,
      actual=data.length(),
    )
  }
  let mut value = 0UL
  for i in 0..<bytes_read {
    let byte = if i == 0 && remainder != 0 {
      data[i].to_int() & ((1 << remainder) - 1)
    } else {
      data[i].to_int()
    }
    value = (value << 8) | byte.reinterpret_as_uint().to_uint64()
  }
  { value, bit_length, bytes_read, }
}
