// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
priv struct JsonBinaryReader {
  data : BytesView
  file_offset : UInt64
  column_index : Int32
  max_depth : Int32
  max_nodes : Int32
  mut nodes : Int32
}

///|
fn JsonBinaryReader::invalid(
  self : JsonBinaryReader,
  position : Int32,
  reason : String,
) -> DecodeError {
  InvalidJsonValue(
    file_offset=self.file_offset,
    column_index=self.column_index,
    value_offset=position,
    reason~,
  )
}

///|
fn JsonBinaryReader::need(
  self : JsonBinaryReader,
  pos : Int32,
  size : Int32,
  limit : Int32,
) -> Unit raise DecodeError {
  guard pos >= 0 && pos <= limit && size >= 0 && size <= limit - pos else {
    raise self.invalid(pos, "JSON value exceeds its containing span")
  }
}

///|
fn JsonBinaryReader::uint(
  self : JsonBinaryReader,
  pos : Int32,
  width : Int32,
  limit : Int32,
) -> UInt64 raise DecodeError {
  self.need(pos, width, limit)
  let mut bits = 0UL
  for i in 0..<width {
    bits = bits | (self.data[pos + i].to_uint().to_uint64() << (8 * i))
  }
  bits
}

///|
fn JsonBinaryReader::string_span(
  self : JsonBinaryReader,
  pos : Int32,
  limit : Int32,
) -> (Int32, Int32) raise DecodeError {
  let mut length = 0UL
  for i in 0..<5 {
    let byte = self.uint(pos + i, 1, limit)
    length = length | ((byte & 0x7f) << (7 * i))
    if (byte & 0x80) == 0 {
      guard length <= 0xffffffffUL &&
        length <= (limit - pos - i - 1).reinterpret_as_uint().to_uint64() else {
        raise self.invalid(pos, "invalid JSON string length")
      }
      return (i + 1, length.to_int())
    }
  }
  raise self.invalid(pos, "unterminated JSON string length")
}

///|
// Measure before decoding/allocation so sibling aliasing cannot amplify strings
// or nested containers. Limits are checked before narrowing sizes to Int.
fn JsonBinaryReader::extent(
  self : JsonBinaryReader,
  kind : Byte,
  pos : Int32,
  limit : Int32,
) -> Int32 raise DecodeError {
  let size = match kind {
    0..<=3 => {
      let width = if kind == 0 || kind == 2 { 2 } else { 4 }
      let size = self.uint(pos + width, width, limit)
      guard size >= (2 * width).reinterpret_as_uint().to_uint64() &&
        size <= (limit - pos).reinterpret_as_uint().to_uint64() else {
        raise self.invalid(pos, "invalid JSON container size")
      }
      size.to_int()
    }
    4 => 1
    5 | 6 => 2
    7 | 8 => 4
    9..<=11 => 8
    12 => {
      let (prefix, length) = self.string_span(pos, limit)
      prefix + length
    }
    binary_type =>
      raise UnsupportedJsonType(
        file_offset=self.file_offset,
        column_index=self.column_index,
        value_offset=pos,
        binary_type~,
      )
  }
  self.need(pos, size, limit)
  size
}

///|
fn JsonBinaryReader::text(
  self : JsonBinaryReader,
  pos : Int32,
  size : Int32,
) -> String raise DecodeError {
  @utf8.decode(self.data[pos:pos + size]) catch {
    _ => raise self.invalid(pos, "invalid UTF-8 in JSON text")
  }
}

///|
fn json_inline(kind : Byte, width : Int32) -> Bool {
  (kind >= 4 && kind <= 6) || (width == 4 && (kind == 7 || kind == 8))
}

///|
fn JsonBinaryReader::value(
  self : JsonBinaryReader,
  kind : Byte,
  pos : Int32,
  limit : Int32,
  depth : Int32,
) -> BinaryJsonValue raise DecodeError {
  guard depth <= self.max_depth && self.nodes < self.max_nodes else {
    raise JsonLimitExceeded(
      file_offset=self.file_offset,
      column_index=self.column_index,
      reason="JSON depth/node budget exceeded",
    )
  }
  self.nodes += 1
  match kind {
    0..<=3 => self.container(kind, pos, limit, depth)
    4 =>
      match self.uint(pos, 1, limit) {
        0 => Null
        1 => Boolean(true)
        2 => Boolean(false)
        _ => raise self.invalid(pos, "invalid JSON literal")
      }
    5..<=10 => {
      let width = if kind <= 6 { 2 } else if kind <= 8 { 4 } else { 8 }
      let bits = self.uint(pos, width, limit)
      let integer = if kind == 5 || kind == 7 || kind == 9 {
        let extended = if width < 8 && (bits & (1UL << (width * 8 - 1))) != 0 {
          bits | (0xffffffffffffffffUL << (width * 8))
        } else {
          bits
        }
        Signed(extended.reinterpret_as_int64())
      } else {
        Unsigned(bits)
      }
      Integer(integer)
    }
    11 => {
      let bits = self.uint(pos, 8, limit)
      guard (bits & 0x7ff0000000000000UL) != 0x7ff0000000000000UL else {
        raise self.invalid(pos, "non-finite JSON double")
      }
      DoubleNumber(value=bits.reinterpret_as_double(), bits~)
    }
    12 => {
      let (prefix, length) = self.string_span(pos, limit)
      Text(self.text(pos + prefix, length))
    }
    binary_type =>
      raise UnsupportedJsonType(
        file_offset=self.file_offset,
        column_index=self.column_index,
        value_offset=pos,
        binary_type~,
      )
  }
}

///|
fn JsonBinaryReader::container(
  self : JsonBinaryReader,
  kind : Byte,
  pos : Int32,
  limit : Int32,
  depth : Int32,
) -> BinaryJsonValue raise DecodeError {
  let width = if kind == 0 || kind == 2 { 2 } else { 4 }
  let object = kind <= 1
  let size = self.extent(kind, pos, limit)
  let end = pos + size
  let count = self.uint(pos, width, end)
  let stride = 1 + width + (if object { width + 2 } else { 0 })
  guard count <= ((size - 2 * width) / stride).reinterpret_as_uint().to_uint64() else {
    raise self.invalid(pos, "JSON entry table exceeds container")
  }
  guard count <= (self.max_nodes - self.nodes).reinterpret_as_uint().to_uint64() else {
    raise JsonLimitExceeded(
      file_offset=self.file_offset,
      column_index=self.column_index,
      reason="JSON node budget exceeded",
    )
  }
  let count = count.to_int()
  let header = 2 * width + count * stride
  let values_start = pos +
    2 * width +
    (if object { count * (width + 2) } else { 0 })
  let spans : Array[(Int32, Int32)] = []
  let keys : Array[(Int32, Int32)] = []
  let values : Array[(Byte, Int32, Int32)] = []
  if object {
    for i in 0..<count {
      let entry = pos + 2 * width + i * (width + 2)
      let offset = self.uint(entry, width, end)
      let length = self.uint(entry + width, 2, end)
      guard offset >= header.reinterpret_as_uint().to_uint64() &&
        offset <= size.reinterpret_as_uint().to_uint64() &&
        length <= size.reinterpret_as_uint().to_uint64() - offset else {
        raise self.invalid(entry, "JSON key points outside data area")
      }
      let start = pos + offset.to_int()
      keys.push((start, length.to_int()))
      if length > 0 {
        spans.push((start, start + length.to_int()))
      }
    }
  }
  for i in 0..<count {
    let entry = values_start + i * (1 + width)
    let tag = self.data[entry]
    let start = if json_inline(tag, width) {
      entry + 1
    } else {
      let offset = self.uint(entry + 1, width, end)
      guard offset >= header.reinterpret_as_uint().to_uint64() &&
        offset <= size.reinterpret_as_uint().to_uint64() else {
        raise self.invalid(entry, "JSON value points outside data area")
      }
      pos + offset.to_int()
    }
    let value_end = if json_inline(tag, width) {
      entry + 1 + width
    } else {
      end
    }
    let consumed = self.extent(tag, start, value_end)
    if !json_inline(tag, width) {
      spans.push((start, start + consumed))
    }
    values.push((tag, start, value_end))
  }
  spans.sort_by((a, b) => a.0 - b.0)
  let mut previous_end = pos + header
  for (start, finish) in spans {
    guard start >= previous_end else {
      raise self.invalid(start, "overlapping JSON key/value spans")
    }
    previous_end = finish
  }
  let names = []
  for i, (start, length) in keys {
    if i > 0 {
      let (prev, prev_length) = keys[i - 1]
      let mut less = prev_length < length
      if prev_length == length {
        for j in 0..<length {
          if self.data[prev + j] != self.data[start + j] {
            less = self.data[prev + j] < self.data[start + j]
            break
          }
        }
      }
      guard less else {
        raise self.invalid(start, "duplicate or unsorted JSON object keys")
      }
    }
    names.push(self.text(start, length))
  }
  if object {
    let members = []
    for i, (tag, start, value_end) in values {
      members.push((names[i], self.value(tag, start, value_end, depth + 1)))
    }
    Object(ReadOnlyArray::from_array(members))
  } else {
    let elements = []
    for (tag, start, value_end) in values {
      elements.push(self.value(tag, start, value_end, depth + 1))
    }
    Array(ReadOnlyArray::from_array(elements))
  }
}
