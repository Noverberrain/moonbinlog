// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
test "CRC32 matches the standard empty and check vectors" {
  assert_eq(checksum_crc32(b""), 0U)
  assert_eq(checksum_crc32(b"123456789"), 0xcbf43926U)
}

///|
test "CRC32 matches zlib for all possible byte values" {
  let data = Bytes::makei(256, i => i.to_byte())
  assert_eq(checksum_crc32(data), 0x29058c73U)
  assert_eq(checksum_crc32(data[:]), 0x29058c73U)
}
