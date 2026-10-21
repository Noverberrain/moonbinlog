// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// Exact bytes of a non-NULL BLOB/TEXT, without its length prefix.
pub struct DecodedBlob {
  value : Bytes
  bytes_read : Int32
} derive(Debug, Eq)

///|
pub extend DecodedBlob with Eq::{equal, not_equal}

///|
pub extend DecodedBlob with @debug.Debug::{to_repr}

///|
/// Decode canonical MySQL BLOB (252), including TINY/MEDIUM/LONG BLOB/TEXT.
/// Its one metadata byte specifies a 1..4-byte little-endian length prefix.
/// `file_offset` is the field's first byte; `column_index` is zero-based.
/// The limit excludes the prefix; 0 allows only empty values. Values above
/// 2_147_483_643 are invalid limits so total consumed bytes fit Int32.
/// Check limits and available input before allocating or converting indices.
/// The caller handles row NULL/presence bitmaps and TEXT charset conversion.
pub fn TableColumn::decode_blob(
  self : TableColumn,
  data : BytesView,
  file_offset~ : UInt64,
  column_index~ : Int32,
  max_value_bytes~ : Int32 = 16_777_216,
) -> DecodedBlob raise DecodeError {
  guard max_value_bytes >= 0 && max_value_bytes <= 2_147_483_643 else {
    raise InvalidBlobLimit(max_value_bytes~)
  }
  guard self.wire_type == 252 else {
    raise UnsupportedBlobColumn(
      file_offset~,
      column_index~,
      wire_type=self.wire_type,
    )
  }
  guard self.metadata.length() == 1 else {
    raise InvalidBlobMetadata(
      file_offset~,
      column_index~,
      reason="expected one metadata byte",
    )
  }
  let width = self.metadata[0].to_int()
  guard width >= 1 && width <= 4 else {
    raise InvalidBlobMetadata(
      file_offset~,
      column_index~,
      reason="length prefix width must be 1..4",
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
  let mut length = 0UL
  for i in 0..<width {
    length = length | (data[i].to_uint().to_uint64() << (8 * i))
  }
  guard length <= max_value_bytes.reinterpret_as_uint().to_uint64() else {
    raise BlobTooLarge(file_offset~, column_index~, length~, max_value_bytes~)
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
  { value: data[width:bytes_read].to_owned(), bytes_read, }
}
