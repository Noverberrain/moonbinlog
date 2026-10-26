// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn json_table() -> @moonbinlog.TableMap raise {
  @moonbinlog.TableMap::parse(tx_format(), tm_json, file_offset=126)
}

///|
fn json_field(payload : BytesView, width~ : Int32 = 4) -> Bytes {
  Bytes::makei(width + payload.length(), i => {
    if i < width {
      ((payload.length().reinterpret_as_uint() >> (i * 8)) & 255).to_byte()
    } else {
      payload[i - width]
    }
  })
}

///|
fn json_decode(payload : BytesView) -> @moonbinlog.DecodedJson raise {
  json_table().columns[3].decode_json(
    json_field(payload),
    file_offset=0x100000004,
    column_index=3,
  )
}

///|
test "binary JSON independently encoded scalars small large and nested containers" {
  for (payload, expected) in json_valid_cases {
    let decoded = json_decode(payload)
    assert_eq(decoded.bytes_read, payload.length() + 4)
    assert_eq(@json.parse(decoded.value.to_json_text()), @json.parse(expected))
  }
}

///|
test "binary JSON integers keep full signed unsigned precision and double negative zero bits" {
  let signed = json_decode(b"\x09\x00\x00\x00\x00\x00\x00\x00\x80")
  assert_eq(signed.value, Integer(Signed(-9223372036854775808L)))
  assert_eq(signed.value.to_json_text(), "-9223372036854775808")
  let unsigned = json_decode(b"\x0a\xff\xff\xff\xff\xff\xff\xff\xff")
  assert_eq(unsigned.value, Integer(Unsigned(0xffffffffffffffffUL)))
  assert_eq(unsigned.value.to_json_text(), "18446744073709551615")
  let zero = json_decode(b"\x0b\x00\x00\x00\x00\x00\x00\x00\x80")
  guard zero.value is DoubleNumber(bits=0x8000000000000000, ..) else {
    fail("lost floating bits")
  }
  assert_eq(zero.value.to_json_text(), "-0.0")
}

///|
test "binary JSON length prefix widths metadata limits and following bytes" {
  let table = json_table()
  for width in 1..<=4 {
    let field = json_field(b"\x04\x01", width~) + b"next"
    let decoded = table.columns[width - 1].decode_json(
      field,
      file_offset=10,
      column_index=width - 1,
    )
    assert_eq(decoded.bytes_read, width + 2)
    assert_eq(decoded.value, Boolean(true))
  }
  for index in [4, 5] {
    try
      table.columns[index].decode_json(b"", file_offset=10, column_index=index)
    catch {
      InvalidJsonMetadata(..) => ()
      other => fail("unexpected metadata error: \{Repr(other)}")
    } noraise {
      _ => fail("invalid JSON prefix width")
    }
  }
  try
    row_image_table().columns[0].decode_json(
      b"",
      file_offset=10,
      column_index=0,
    )
  catch {
    @moonbinlog.DecodeError::UnsupportedJsonColumn(..) => ()
    other => fail("unexpected type error: \{Repr(other)}")
  } noraise {
    _ => fail("integer coerced to JSON")
  }
  try
    table.columns[3].decode_json(
      b"\xff\xff\xff\xff",
      file_offset=10,
      column_index=3,
    )
  catch {
    JsonLimitExceeded(..) => ()
    other => fail("length narrowed before limit check: \{Repr(other)}")
  } noraise {
    _ => fail("huge JSON length accepted")
  }
}

///|
test "binary JSON rejects every truncated document and field prefix" {
  for (payload, _) in json_valid_cases {
    let field = json_field(payload)
    for cut in 0..<field.length() {
      try
        json_table().columns[3].decode_json(
          field[:cut],
          file_offset=500,
          column_index=3,
        )
      catch {
        @moonbinlog.DecodeError::TruncatedColumnValue(
          file_offset~,
          column_index~,
          ..
        ) => {
          assert_eq(file_offset, 500UL)
          assert_eq(column_index, 3)
        }
        other => fail("unexpected field truncation: \{Repr(other)}")
      } noraise {
        _ => fail("truncated JSON field accepted")
      }
    }
    for cut in 0..<payload.length() {
      try json_decode(payload[:cut]) catch {
        @moonbinlog.DecodeError::InvalidJsonValue(..) => ()
        other => fail("unexpected document truncation: \{Repr(other)}")
      } noraise {
        _ => fail("truncated binary JSON document accepted")
      }
    }
  }
}

///|
test "binary JSON malformed offsets aliases key order UTF8 literals and opaque types fail" {
  for payload in json_invalid_cases {
    try json_decode(payload) catch {
      @moonbinlog.DecodeError::InvalidJsonValue(file_offset~, column_index~, ..)
      | @moonbinlog.DecodeError::UnsupportedJsonType(
        file_offset~,
        column_index~,
        ..
      ) => {
        assert_eq(file_offset, 0x100000004UL)
        assert_eq(column_index, 3)
      }
      other => fail("unexpected binary JSON error: \{Repr(other)}")
    } noraise {
      _ => fail("malformed binary JSON accepted")
    }
  }
}

///|
fn json_nested(depth : Int32) -> Bytes {
  let mut payload = b"\x02\x00\x00\x04\x00"
  for _ in 1..<depth {
    let size = payload.length() + 6
    let header : Bytes = [
      2,
      1,
      0,
      (size & 255).to_byte(),
      (size >> 8).to_byte(),
      2,
      7,
      0,
    ]
    payload = header + payload[1:].to_owned()
  }
  payload
}

///|
test "binary JSON enforces node depth byte budgets and invalid configurations" {
  let column = json_table().columns[3]
  column.decode_json(
    json_field(json_nested(3)),
    file_offset=0,
    column_index=3,
    max_depth=3,
  )
  |> ignore
  let three = json_field(b"\x02\x02\x00\x0a\x00\x04\x01\x00\x04\x02\x00")
  column.decode_json(three, file_offset=0, column_index=3, max_nodes=3)
  |> ignore
  for
    (field, depth, nodes, bytes) in [
      (json_field(json_nested(4)), 3, 65536, 1000),
      (three, 64, 2, 1000),
      (json_field(b"\x04\x00"), 64, 65536, 1),
    ] {
    try
      column.decode_json(
        field,
        file_offset=0,
        column_index=3,
        max_depth=depth,
        max_nodes=nodes,
        max_value_bytes=bytes,
      )
    catch {
      JsonLimitExceeded(..) => ()
      other => fail("unexpected JSON budget error: \{Repr(other)}")
    } noraise {
      _ => fail("JSON budget ignored")
    }
  }
  for
    (depth, nodes, bytes) in [
      (0, 1, 100),
      (129, 1, 100),
      (1, 0, 100),
      (1, 1, -1),
    ] {
    try
      column.decode_json(
        b"",
        file_offset=0,
        column_index=3,
        max_depth=depth,
        max_nodes=nodes,
        max_value_bytes=bytes,
      )
    catch {
      InvalidJsonLimits(..) => ()
      other => fail("unexpected JSON limits error: \{Repr(other)}")
    } noraise {
      _ => fail("invalid JSON configuration accepted")
    }
  }
}

///|
test "binary JSON boundary offsets and maximum supported recursion stay checked" {
  let column = json_table().columns[3]
  column.decode_json(
    json_field(json_nested(128)),
    file_offset=0,
    column_index=3,
    max_depth=128,
  )
  |> ignore
  try
    column.decode_json(
      json_field(b"\x04\x00"),
      file_offset=0xffffffffffffffff,
      column_index=3,
    )
  catch {
    InvalidJsonValue(..) => ()
    other => fail("unexpected physical offset error: \{Repr(other)}")
  } noraise {
    _ => fail("offset range overflow accepted")
  }
}

///|
test "binary JSON byte mutations return checked errors or valid serializable trees" {
  for (payload, _) in json_valid_cases {
    for index in 0..<payload.length() {
      let changed = Bytes::makei(payload.length(), i => {
        if i == index {
          (payload[i].to_uint() ^ 128).to_byte()
        } else {
          payload[i]
        }
      })
      try json_decode(changed) catch {
        @moonbinlog.DecodeError::InvalidJsonValue(..)
        | @moonbinlog.DecodeError::UnsupportedJsonType(..)
        | @moonbinlog.DecodeError::JsonLimitExceeded(..) => ()
        other => fail("unexpected mutated JSON result: \{Repr(other)}")
      } noraise {
        decoded => @json.parse(decoded.value.to_json_text()) |> ignore
      }
    }
  }
}
