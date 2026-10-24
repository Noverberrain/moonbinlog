// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
test "CLI rows require schema and select JSON Lines automatically" {
  for
    args in [
      ["--rows", "--schema", "配置.json", "file"],
      ["file", "--schema", "配置.json", "--summary", "--rows", "--json"],
    ] {
    guard @cli.parse_args(args[:]) is Inspect(config) else {
      fail("expected inspect")
    }
    assert_true(config.rows)
    assert_true(config.json_output)
    assert_eq(config.schema_path, Some("配置.json"))
  }
  for
    args in [
      ["--rows", "file"],
      ["--schema", "a", "file"],
      ["--schema"],
      ["--rows", "--schema", "", "file"],
      ["--rows", "--rows", "--schema", "a", "file"],
      ["--rows", "--schema", "a", "--schema", "b", "file"],
    ] {
    invalid_args(args[:])
  }
  guard @cli.parse_args(["--", "--rows"]) is Inspect(config) else {
    fail("expected path")
  }
  assert_false(config.rows)
}

///|
test "CLI row summary has explicit unconfirmed status and preserves event totals" {
  let stats = @cli.Stats::new()
  stats.record(report_header(30))
  let value = @json.parse(stats.row_json_line(23, 1, 2))
  assert_eq(value, {
    "schema_version": 1,
    "kind": "row_summary",
    "transaction_status": "unconfirmed",
    "events": 1,
    "event_bytes": "19",
    "file_bytes": 23,
    "row_events": 1,
    "changes": 2,
    "types": [{ "type": 30, "name": "WRITE_ROWS_EVENT_V2", "count": 1 }],
  })
}
