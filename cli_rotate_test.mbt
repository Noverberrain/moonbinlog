// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
test "CLI rotation JSON preserves UInt64 decimal precision and existing event fields" {
  let rotation = rotate_decode(rotate_max)
  guard @json.parse(@cli.rotate_json_line(rotation, Crc32)) is Object(fields) else {
    fail("missing event")
  }
  assert_eq(
    fields.get("rotate"),
    Some({
      "position": "18446744073709551615",
      "next_binlog_hex": "6d7973716c2d62696e2e303030303032",
      "next_binlog_utf8": "mysql-bin.000002",
    }),
  )
  fields.remove("rotate") |> ignore
  assert_eq(
    Json::object(fields),
    @json.parse(@cli.event_json_line(rotation.header, Crc32)),
  )
}

///|
test "CLI rotation JSON distinguishes invalid UTF8 from raw NUL data" {
  guard @json.parse(
      @cli.rotate_json_line(rotate_decode(rotate_raw_name), Crc32),
    )
    is {
      "rotate": { "next_binlog_utf8": Null, "next_binlog_hex": String(hex), .. },
      ..
    } else {
    fail("invalid UTF8 converted")
  }
  assert_eq(hex, @hex.encode(rotate_decode(rotate_raw_name).next_binlog))
  guard @json.parse(
      @cli.rotate_json_line(rotate_decode(rotate_one_byte_name), Crc32),
    )
    is {
      "rotate": { "next_binlog_utf8": "\u0000", "next_binlog_hex": "00", .. },
      ..
    } else {
    fail("NUL stripped")
  }
}

///|
test "CLI rotation JSON matches six official targets and current format checksum mode" {
  for (data, position, next_binlog) in rotate_real_oracles {
    for event in mysql_events(data) {
      if event.header.event_type == 4 {
        let rotation = @moonbinlog.RotateEvent::parse(
          event.format,
          event.raw,
          file_offset=event.header.file_offset,
        )
        guard @json.parse(
            @cli.rotate_json_line(rotation, event.format.checksum_algorithm),
          )
          is {
            "kind": "event",
            "type": 4,
            "rotate": Object(payload),
            "checksum": String(checksum),
            ..
          } else {
          fail("missing real rotation details")
        }
        assert_eq(
          payload.get("position"),
          Some(Json::string(position.to_string())),
        )
        assert_eq(
          payload.get("next_binlog_hex"),
          Some(Json::string(@hex.encode(next_binlog))),
        )
        assert_eq(
          checksum,
          if event.format.checksum_algorithm == Crc32 {
            "CRC32"
          } else {
            "OFF"
          },
        )
      }
    }
  }
}
