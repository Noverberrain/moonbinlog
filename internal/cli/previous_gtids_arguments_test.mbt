// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
test "CLI previous GTIDs accepts summary limits chain and rotation details" {
  guard @cli.parse_args([
      "--decode-previous-gtids", "--decode-rotate", "--summary", "--json", "--chain",
      "--max-event-bytes", "200", "a", "b",
    ])
    is Inspect(config) else {
    fail("missing config")
  }
  assert_true(config.decode_previous_gtids)
  assert_true(config.decode_rotate)
  assert_true(config.json_output)
  assert_true(config.summary_only)
  assert_true(config.chain)
  assert_eq(config.max_event_bytes, 200U)
  guard @cli.parse_args(["--", "--decode-previous-gtids"]) is Inspect(config) else {
    fail("missing positional config")
  }
  assert_false(config.decode_previous_gtids)
  assert_false(config.json_output)
  assert_eq(config.path, "--decode-previous-gtids")
}

///|
test "CLI previous GTIDs rejects duplicate flag and non event modes" {
  for
    args in [
      ["--decode-previous-gtids"],
      ["--decode-previous-gtids", "--decode-previous-gtids", "file"],
      ["--decode-previous-gtids", "--rows", "--schema", "s", "file"],
      ["--decode-previous-gtids", "--transactions", "--schema", "s", "file"],
      ["--decode-previous-gtids", "--schema-template", "file"],
      ["--decode-previous-gtids", "--use-table-metadata", "file"],
      ["--decode-previous-gtids", "--include-rows", "file"],
      ["--decode-previous-gtids", "--schema", "s", "file"],
      ["--decode-previous-gtids", "--database", "db", "file"],
      ["--decode-previous-gtids", "--table", "t", "file"],
    ] {
    invalid_args(args[:])
  }
}
