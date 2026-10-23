// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
test "CLI JSON flag composes with summary and preserves option terminator" {
  for argv in [["--json", "--summary", "file"], ["file", "--summary", "--json"]] {
    guard @cli.parse_args(argv[:]) is Inspect(config) else {
      fail("expected inspect")
    }
    assert_true(config.json_output)
    assert_true(config.summary_only)
    assert_eq(config.path, "file")
  }
  guard @cli.parse_args(["--json", "file"]) is Inspect(config) else {
    fail("expected inspect")
  }
  assert_true(config.json_output)
  assert_false(config.summary_only)
  guard @cli.parse_args(["--", "--json"]) is Inspect(config) else {
    fail("expected filename")
  }
  assert_false(config.json_output)
  assert_eq(config.path, "--json")
  invalid_args(["--json", "--json", "file"])
  invalid_args(["--json"])
  invalid_args(["--json=true", "file"])
}

///|
test "CLI JSON event keeps UInt64 maximum as string and UInt32 fields as numbers" {
  let header = @moonbinlog.EventHeader::parse(
    Bytes::make(19, 255),
    file_offset=0xffffffffffffffff,
    max_event_size=0xffffffff,
  )
  let line = @cli.event_json_line(header, Off)
  assert_eq(@json.parse(line), {
    "schema_version": 1,
    "kind": "event",
    "offset": "18446744073709551615",
    "type": 255,
    "name": "UNKNOWN",
    "bytes": 4294967295,
    "next_position": 4294967295,
    "timestamp": 4294967295,
    "server_id": 4294967295,
    "flags": 65535,
    "checksum": "OFF",
  })
  assert_false(line.contains("\n"))
}

///|
test "CLI JSON checksum distinguishes OFF events from FDE protection" {
  for algorithm in [@moonbinlog.Crc32, Off] {
    let value = @json.parse(@cli.event_json_line(report_header(15), algorithm))
    guard value is { "checksum": "CRC32", "type": 15, .. } else {
      fail("FDE JSON checksum is wrong")
    }
  }
  let value = @json.parse(@cli.event_json_line(report_header(2), Off))
  guard value is { "checksum": "OFF", "type": 2, .. } else {
    fail("ordinary OFF event JSON checksum is wrong")
  }
}

///|
test "CLI JSON summary uses typed counts sorted by numeric event type" {
  let stats = @cli.Stats::new()
  stats.record(report_header(255))
  stats.record(report_header(2))
  stats.record(report_header(255))
  let line = stats.json_line(61)
  assert_eq(@json.parse(line), {
    "schema_version": 1,
    "kind": "summary",
    "events": 3,
    "event_bytes": "57",
    "file_bytes": 61,
    "types": [
      { "type": 2, "name": "QUERY_EVENT", "count": 1 },
      { "type": 255, "name": "UNKNOWN", "count": 2 },
    ],
  })
  assert_false(line.contains("\n"))
}

///|
test "CLI JSON zero and wide byte counts retain a consistent string schema" {
  let stats = @cli.Stats::new()
  assert_eq(@json.parse(stats.json_line(4)), {
    "schema_version": 1,
    "kind": "summary",
    "events": 0,
    "event_bytes": "0",
    "file_bytes": 4,
    "types": [],
  })
  let header = @moonbinlog.EventHeader::parse(
    Bytes::make(19, 255),
    file_offset=4,
    max_event_size=0xffffffff,
  )
  stats.record(header)
  stats.record(header)
  let value = @json.parse(stats.json_line(2147483647))
  guard value
    is {
      "event_bytes": "8589934590",
      "file_bytes": 2147483647,
      "events": 2,
      ..
    } else {
    fail("JSON byte count was narrowed to Int32")
  }
}
