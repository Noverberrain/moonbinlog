// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
test "CLI decoded rotations opt into JSON and accept summary limits and filename terminator" {
  guard @cli.parse_args([
      "--decode-rotate", "--summary", "--json", "--max-event-bytes", "200", "--",
      "--file",
    ])
    is Inspect(config) else {
    fail("missing event config")
  }
  assert_true(config.decode_rotate)
  assert_true(config.json_output)
  assert_true(config.summary_only)
  assert_eq(config.max_event_bytes, 200U)
  assert_eq(config.path, "--file")
  guard @cli.parse_args(["--", "--decode-rotate"]) is Inspect(config) else {
    fail("missing config")
  }
  assert_false(config.decode_rotate)
}

///|
test "CLI decoded rotations reject duplicate options and non event modes" {
  for
    args in [
      ["--decode-rotate", "--decode-rotate", "file"],
      ["--decode-rotate", "--rows", "--schema", "a", "file"],
      ["--decode-rotate", "--transactions", "--schema", "a", "file"],
      ["--decode-rotate", "--schema-template", "file"],
      ["--decode-rotate", "--use-table-metadata", "file"],
      ["--decode-rotate", "--include-rows", "file"],
      ["--decode-rotate", "--schema", "a", "file"],
      ["--decode-rotate", "--table", "a", "file"],
      ["--decode-rotate", "--database", "a", "file"],
    ] {
    invalid_args(args[:])
  }
}
