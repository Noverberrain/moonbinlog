// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
test "CLI previous GTIDs JSON retains existing fields UUID bytes and half open intervals" {
  let parsed = pg_decode(pg_multiple_crc32)
  guard @json.parse(@cli.previous_gtids_json_line(parsed, Crc32))
    is Object(fields) else {
    fail("missing event fields")
  }
  assert_eq(
    fields.get("previous_gtids"),
    Some({
      "sids": [
        {
          "sid": "00112233-4455-6677-8899-aabbccddeeff",
          "intervals": [
            { "start": "1", "end_exclusive": "5" },
            { "start": "8", "end_exclusive": "10" },
          ],
        },
        {
          "sid": "ffeeddcc-bbaa-9988-7766-554433221100",
          "intervals": [
            { "start": "4294967296", "end_exclusive": "4294967298" },
          ],
        },
      ],
    }),
  )
  fields.remove("previous_gtids") |> ignore
  assert_eq(
    Json::object(fields),
    @json.parse(@cli.event_json_line(parsed.header, Crc32)),
  )
}

///|
test "CLI previous GTIDs preserves empty repeated entries maximum GNO and OFF policy" {
  guard @json.parse(
      @cli.previous_gtids_json_line(pg_decode(pg_empty_crc32), Crc32),
    )
    is { "previous_gtids": { "sids": [], .. }, .. } else {
    fail("empty set changed")
  }
  guard @json.parse(
      @cli.previous_gtids_json_line(
        pg_decode(pg_boundary_off, format_bytes=fde_off),
        Off,
      ),
    )
    is {
      "checksum": "OFF",
      "previous_gtids": {
        "sids": [
          {
            "sid": "00000000-0000-0000-0000-000000000000",
            "intervals": [
              {
                "start": "9223372036854775806",
                "end_exclusive": "9223372036854775807",
                ..
              },
            ],
            ..
          },
        ],
        ..
      },
      ..
    } else {
    fail("GNO precision lost")
  }
  guard @json.parse(
      @cli.previous_gtids_json_line(pg_decode(pg_wire_order_crc32), Crc32),
    )
    is {
      "previous_gtids": {
        "sids": [
          { "sid": String(first), "intervals": [], .. },
          { "sid": String(second), .. },
          { "sid": String(third), .. },
        ],
        ..
      },
      ..
    } else {
    fail("wire order lost")
  }
  assert_eq(second, third)
  assert_true(first > second)
}

///|
test "CLI previous GTIDs chain records preserve source and six real empty sets" {
  for data in pg_real_empty() {
    let events = mysql_events(data)
    for event in events {
      if event.header.event_type == 35 {
        let previous = @moonbinlog.PreviousGtidsEvent::parse(
          event.format,
          event.raw,
          file_offset=event.header.file_offset,
        )
        guard @json.parse(
            @cli.chain_event_line(
              event,
              None,
              2,
              "目录/文件\n",
              previous_gtids=Some(previous),
            ),
          )
          is Object(fields) else {
          fail("missing chain fields")
        }
        assert_eq(
          fields.get("source"),
          Some({ "index": 2, "path": "目录/文件\n" }),
        )
        fields.remove("source") |> ignore
        assert_eq(
          Json::object(fields),
          @json.parse(
            @cli.previous_gtids_json_line(
              previous,
              event.format.checksum_algorithm,
            ),
          ),
        )
        assert_eq(fields.get("previous_gtids"), Some({ "sids": [] }))
        guard @json.parse(@cli.chain_event_line(event, None, 2, "file"))
          is Object(plain) else {
          fail("missing plain event")
        }
        assert_false(plain.contains("previous_gtids"))
      }
    }
  }
}
