// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn cli_named_gtid(name : String) -> @moonbinlog.GtidEvent raise {
  for (label, raw, _, _) in gtid_valid() {
    if label == name {
      return gtid_decode(raw)
    }
  }
  fail("missing GTID vector: \{name}")
}

///|
test "CLI GTID details reports exact identity logical clocks timestamps versions and ticket" {
  let value = cli_named_gtid("full")
  guard @json.parse(@cli.gtid_json_line(value, Crc32)) is Object(fields) else {
    fail("missing event fields")
  }
  assert_eq(
    fields.get("gtid"),
    Some({
      "anonymous": false,
      "identity": "00112233-4455-6677-8899-aabbccddeeff:4294967297",
      "sid": "00112233-4455-6677-8899-aabbccddeeff",
      "gno": "4294967297",
      "flags": 1,
      "may_have_sbr_statements": true,
      "last_committed": "5",
      "sequence_number": "6",
      "commit_timestamps": {
        "immediate": "1793013538890013",
        "original": "1793013538890000",
      },
      "transaction_length": "65536",
      "server_versions": { "immediate": 80043, "original": 80036 },
      "commit_group_ticket": "31",
    }),
  )
  fields.remove("gtid") |> ignore
  assert_eq(
    Json::object(fields),
    @json.parse(@cli.event_json_line(value.header, Crc32)),
  )
}

///|
test "CLI GTID details preserves null zero precision and anonymous raw fields without identity" {
  guard @json.parse(@cli.gtid_json_line(cli_named_gtid("base"), Crc32))
    is {
      "gtid": {
        "commit_timestamps": Null,
        "transaction_length": Null,
        "server_versions": Null,
        "commit_group_ticket": Null,
        ..
      },
      ..
    } else {
    fail("absent extensions changed")
  }
  guard @json.parse(@cli.gtid_json_line(cli_named_gtid("ticket_zero"), Crc32))
    is {
      "gtid": {
        "commit_timestamps": { "immediate": "0", "original": "0", .. },
        "transaction_length": "0",
        "server_versions": { "immediate": 0, "original": 0, .. },
        "commit_group_ticket": "0",
        ..
      },
      ..
    } else {
    fail("encoded zero lost")
  }
  guard @json.parse(@cli.gtid_json_line(cli_named_gtid("max_gno"), Crc32))
    is {
      "gtid": {
        "identity": "00112233-4455-6677-8899-aabbccddeeff:9223372036854775806",
        "gno": "9223372036854775806",
        "flags": 129,
        "last_committed": "18446744073709551615",
        "sequence_number": "18446744073709551615",
        ..
      },
      ..
    } else {
    fail("64-bit precision lost")
  }
  guard @json.parse(@cli.gtid_json_line(cli_named_gtid("ticket_max"), Crc32))
    is { "gtid": { "commit_group_ticket": "18446744073709551615", .. }, .. } else {
    fail("ticket precision lost")
  }
  guard @json.parse(
      @cli.gtid_json_line(cli_named_gtid("anonymous_raw_sid"), Crc32),
    )
    is {
      "gtid": {
        "anonymous": true,
        "identity": Null,
        "gno": "0",
        "flags": 255,
        "sid": "00112233-4455-6677-8899-aabbccddeeff",
        ..
      },
      ..
    } else {
    fail("anonymous identity fabricated or raw fields lost")
  }
}

///|
test "CLI GTID details chain source and six official anonymous events retain event fields" {
  for (data, _, expected) in gtid_real_oracles() {
    for event in mysql_events(data) {
      if event.header.event_type == 34 {
        let gtid = @moonbinlog.GtidEvent::parse(
          event.format,
          event.raw,
          file_offset=event.header.file_offset,
        )
        guard @json.parse(
            @cli.chain_event_line(
              event,
              None,
              1,
              "目录/文件\n",
              gtid=Some(gtid),
            ),
          )
          is Object(fields) else {
          fail("missing chain fields")
        }
        assert_eq(
          fields.get("source"),
          Some({ "index": 1, "path": "目录/文件\n" }),
        )
        fields.remove("source") |> ignore
        assert_eq(
          Json::object(fields),
          @json.parse(
            @cli.gtid_json_line(gtid, event.format.checksum_algorithm),
          ),
        )
        guard fields.get("gtid") is Some(Object(payload)) else {
          fail("missing details")
        }
        assert_eq(payload.get("anonymous"), Some(Json::boolean(true)))
        assert_eq(payload.get("identity"), Some(Json::null()))
        assert_eq(
          payload.get("transaction_length"),
          expected.length.map(value => Json::string(value.to_string())),
        )
        guard @json.parse(@cli.chain_event_line(event, None, 1, "file"))
          is Object(plain) else {
          fail("missing plain event")
        }
        assert_false(plain.contains("gtid"))
      }
    }
  }
}
