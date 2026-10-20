// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
priv struct MapReader {
  data : BytesView
  base : Int32
  file_offset : UInt64
  mut position : Int32
}

///|
fn MapReader::remaining(self : MapReader) -> Int32 {
  self.data.length() - self.position
}

///|
fn MapReader::invalid(self : MapReader, reason : String) -> DecodeError {
  InvalidTableMap(
    file_offset=self.file_offset,
    body_offset=self.base + self.position,
    reason~,
  )
}

///|
fn MapReader::take(
  self : MapReader,
  length : Int32,
) -> BytesView raise DecodeError {
  guard length >= 0 && length <= self.remaining() else {
    raise self.invalid("truncated table-map field")
  }
  let start = self.position
  self.position += length
  self.data[start:self.position]
}

///|
fn MapReader::byte(self : MapReader) -> Byte raise DecodeError {
  self.take(1)[0]
}

///|
fn MapReader::uint_le(
  self : MapReader,
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
fn MapReader::packed_length(self : MapReader) -> UInt64 raise DecodeError {
  match self.byte() {
    0x00..<=0xfa as value => value.to_uint().to_uint64()
    0xfc => self.uint_le(2)
    0xfd => self.uint_le(3)
    0xfe => self.uint_le(8)
    _ => raise self.invalid("NULL or reserved packed-length marker")
  }
}

///|
fn MapReader::sized_field(self : MapReader) -> BytesView raise DecodeError {
  let length = self.packed_length()
  guard length <= self.remaining().reinterpret_as_uint().to_uint64() else {
    raise self.invalid("packed length exceeds remaining payload")
  }
  self.take(length.to_int())
}

///|
fn MapReader::name(self : MapReader) -> String raise DecodeError {
  let length = self.byte().to_int()
  guard length > 0 else { raise self.invalid("empty database or table name") }
  let bytes = self.take(length)
  for byte in bytes {
    guard byte != 0 else { raise self.invalid("NUL inside identifier") }
  }
  guard self.byte() == 0 else {
    raise self.invalid("missing identifier terminator")
  }
  @utf8.decode(bytes) catch {
    _ => raise self.invalid("identifier is not valid UTF-8")
  }
}
