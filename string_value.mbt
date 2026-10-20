// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// One non-NULL SQL string's exact bytes; no charset conversion or padding.
pub struct DecodedString {
  value : Bytes
  bytes_read : Int32
} derive(Debug, Eq)

///|
pub extend DecodedString with Eq::{equal, not_equal}

///|
pub extend DecodedString with @debug.Debug::{to_repr}

///|
/// Decode a present, non-NULL VARCHAR (15) or genuine STRING (254) value.
/// CHAR/BINARY use STRING; VARCHAR/VARBINARY use VARCHAR. ENUM/SET embedded
/// in STRING metadata are rejected. The result owns only the value's bytes.
/// `file_offset` is this field's first byte; `column_index` is zero-based.
/// `bytes_read` includes the length prefix; trailing fields are not consumed.
/// The caller handles row presence/NULL bitmaps and any charset conversion.
pub fn TableColumn::decode_string(
  self : TableColumn,
  data : BytesView,
  file_offset~ : UInt64,
  column_index~ : Int32,
) -> DecodedString raise DecodeError {
  guard self.wire_type == 15 || self.wire_type == 254 else {
    raise UnsupportedStringColumn(
      file_offset~,
      column_index~,
      wire_type=self.wire_type,
    )
  }
  guard self.metadata.length() == 2 else {
    raise InvalidStringMetadata(
      file_offset~,
      column_index~,
      reason="expected two metadata bytes",
    )
  }
  let first = self.metadata[0].to_int()
  let second = self.metadata[1].to_int()
  let max_length = if self.wire_type == 15 {
    first | (second << 8)
  } else {
    // STRING's first metadata byte mixes the real type with two length bits.
    guard (first | 0x30) == 254 else {
      raise InvalidStringMetadata(
        file_offset~,
        column_index~,
        reason="not a genuine STRING type (ENUM/SET unsupported)",
      )
    }
    (((first & 0x30) ^ 0x30) << 4) | second
  }
  let prefix = if max_length > 255 { 2 } else { 1 }
  guard data.length() >= prefix else {
    raise TruncatedColumnValue(
      file_offset~,
      column_index~,
      expected=prefix,
      actual=data.length(),
    )
  }
  let length = if prefix == 1 {
    data[0].to_int()
  } else {
    data[0].to_int() | (data[1].to_int() << 8)
  }
  guard length <= max_length else {
    raise StringLengthExceeded(
      file_offset~,
      column_index~,
      length~,
      max_length~,
    )
  }
  let bytes_read = prefix + length
  guard data.length() >= bytes_read else {
    raise TruncatedColumnValue(
      file_offset~,
      column_index~,
      expected=bytes_read,
      actual=data.length(),
    )
  }
  { value: data[prefix:bytes_read].to_owned(), bytes_read, }
}
