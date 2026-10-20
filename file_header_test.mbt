// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
test "file signature accepts the magic and ignores the following bytes" {
  @moonbinlog.validate_file_header([0xfe, 0x62, 0x69, 0x6e])
  @moonbinlog.validate_file_header([0xfe, 0x62, 0x69, 0x6e, 0xff, 0x00])
}

///|
test "file signature rejects every truncated prefix with its actual length" {
  let magic : Bytes = [0xfe, 0x62, 0x69, 0x6e]
  for length in 0..<4 {
    try @moonbinlog.validate_file_header(magic[:length]) catch {
      TruncatedInput(file_offset~, expected~, actual~) => {
        assert_eq(file_offset, 0UL)
        assert_eq(expected, 4)
        assert_eq(actual, length)
      }
      other => fail("unexpected error: \{Repr(other)}")
    } noraise {
      _ => fail("truncated magic was accepted")
    }
  }
}

///|
test "file signature checks every byte and reports only the invalid signature" {
  let magic : Bytes = [0xfe, 0x62, 0x69, 0x6e]
  for changed in 0..<4 {
    let input = Bytes::makei(8, i => {
      if i >= 4 || i == changed {
        0
      } else {
        magic[i]
      }
    })
    try @moonbinlog.validate_file_header(input) catch {
      InvalidMagic(actual~) => assert_eq(actual, input[:4].to_owned())
      other => fail("unexpected error: \{Repr(other)}")
    } noraise {
      _ => fail("invalid magic was accepted")
    }
  }
}

///|
test "file signature works on a view starting inside another buffer" {
  let input : Bytes = [0x00, 0xfe, 0x62, 0x69, 0x6e, 0x00]
  @moonbinlog.validate_file_header(input[1:5])
}
