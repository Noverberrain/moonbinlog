// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
let crc32_table : FixedArray[UInt32] = FixedArray::makei(256, i => {
  let mut value = i.reinterpret_as_uint()
  for _ in 0..<8 {
    value = if (value & 1) == 0 {
      value >> 1
    } else {
      (value >> 1) ^ 0xedb88320
    }
  }
  value
})

///|
// IEEE CRC32, matching zlib. MySQL ignores the FDE's mutable in-use flag.
fn checksum_crc32(
  data : BytesView,
  format_description~ : Bool = false,
) -> UInt32 {
  let mut crc = 0xffffffffU
  for i in 0..<data.length() {
    let byte = if format_description && i == 17 {
      data[i].to_uint() & 0xfe
    } else {
      data[i].to_uint()
    }
    let index = ((crc ^ byte) & 0xff).reinterpret_as_int()
    crc = (crc >> 8) ^ crc32_table[index]
  }
  crc ^ 0xffffffff
}

///|
// The caller establishes a complete event with at least four trailer bytes.
fn verify_crc32(
  event : BytesView,
  file_offset~ : UInt64,
  format_description~ : Bool = false,
) -> Unit raise DecodeError {
  let trailer = event.length() - 4
  let expected = read_u32_le(event, trailer)
  let actual = checksum_crc32(event[:trailer], format_description~)
  guard actual == expected else {
    raise ChecksumMismatch(file_offset~, expected~, actual~)
  }
}
