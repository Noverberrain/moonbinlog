// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
priv struct RowsReader {
  data : BytesView
  file_offset : UInt64
  mut position : Int32
}

///|
fn RowsReader::remaining(self : RowsReader) -> Int32 {
  self.data.length() - self.position
}

///|
fn RowsReader::invalid(self : RowsReader, reason : String) -> DecodeError {
  InvalidRowsEvent(
    file_offset=self.file_offset,
    body_offset=self.position,
    reason~,
  )
}

///|
fn RowsReader::take(
  self : RowsReader,
  length : Int32,
) -> BytesView raise DecodeError {
  guard length >= 0 && length <= self.remaining() else {
    raise self.invalid("truncated ROWS field")
  }
  let start = self.position
  self.position += length
  self.data[start:self.position]
}

///|
fn RowsReader::uint_le(
  self : RowsReader,
  width : Int32,
) -> UInt64 raise DecodeError {
  let bytes = self.take(width)
  let mut value = 0UL
  for i in 0..<width {
    value = value | (bytes[i].to_uint().to_uint64() << (8 * i))
  }
  value
}

///|
fn RowsReader::packed_length(self : RowsReader) -> UInt64 raise DecodeError {
  match self.take(1)[0] {
    0..<=250 as value => value.to_uint().to_uint64()
    252 => self.uint_le(2)
    253 => self.uint_le(3)
    254 => self.uint_le(8)
    _ => raise self.invalid("NULL or reserved column-count marker")
  }
}

///|
fn RowsReader::image(
  self : RowsReader,
  table : TableMap,
  present : BytesView,
  signs : ReadOnlyArray[Bool?],
  max_bytes : Int32,
) -> RowImage raise DecodeError {
  let image = table.decode_row_image(
    self.data[self.position:],
    columns_present=present,
    integer_unsigned=signs,
    file_offset=self.file_offset +
      19 +
      self.position.reinterpret_as_uint().to_uint64(),
    max_bytes~,
  )
  self.position += image.bytes_read
  image
}
