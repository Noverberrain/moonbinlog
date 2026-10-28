// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
test "CLI GTID details accepts other event details chain summary limits and literal path" {
  guard @cli.parse_args([
      "--decode-gtid", "--decode-previous-gtids", "--decode-rotate", "--summary",
      "--chain", "--max-event-bytes", "1000", "a", "b",
    ])
    is Inspect(config) else {
    fail("missing config")
  }
  assert_true(config.decode_gtid)
  assert_true(config.decode_previous_gtids)
  assert_true(config.decode_rotate)
  assert_true(config.json_output)
  assert_true(config.chain)
  assert_true(config.summary_only)
  assert_eq(config.max_event_bytes, 1000U)
  guard @cli.parse_args(["--", "--decode-gtid"]) is Inspect(config) else {
    fail("missing literal path")
  }
  assert_false(config.decode_gtid)
  assert_false(config.json_output)
  assert_eq(config.path, "--decode-gtid")
}

///|
test "CLI GTID details rejects duplicate flag missing file and incompatible modes" {
  for
    args in [
      ["--decode-gtid"],
      ["--decode-gtid", "--decode-gtid", "f"],
      ["--decode-gtid", "--rows", "--schema", "s", "f"],
      ["--decode-gtid", "--transactions", "--schema", "s", "f"],
      ["--decode-gtid", "--schema-template", "f"],
      ["--decode-gtid", "--use-table-metadata", "f"],
      ["--decode-gtid", "--include-rows", "f"],
      ["--decode-gtid", "--schema", "s", "f"],
      ["--decode-gtid", "--database", "d", "f"],
      ["--decode-gtid", "--table", "t", "f"],
    ] {
    invalid_args(args[:])
  }
}
