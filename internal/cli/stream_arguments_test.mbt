// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
test "CLI stream accepts event details summary and literal filename" {
  guard @cli.parse_args([
      "--stream", "--decode-gtid", "--decode-previous-gtids", "--decode-rotate",
      "--summary", "--max-file-bytes", "200", "f",
    ])
    is Inspect(config) else {
    fail("missing config")
  }
  assert_true(config.stream)
  assert_true(config.json_output)
  assert_true(config.summary_only)
  assert_true(
    config.decode_gtid && config.decode_previous_gtids && config.decode_rotate,
  )
  guard @cli.parse_args(["--", "--stream"]) is Inspect(config) else {
    fail("missing literal path")
  }
  assert_false(config.stream)
  assert_eq(config.path, "--stream")
}

///|
test "CLI stream rejects repeated flag and non-event or multi-file modes" {
  for
    args in [
      ["--stream"],
      ["--stream", "--stream", "f"],
      ["--stream", "--chain", "a", "b"],
      ["--stream", "--rows", "--schema", "s", "f"],
      ["--stream", "--transactions", "--schema", "s", "f"],
      ["--stream", "--schema-template", "f"],
      ["--stream", "--include-rows", "f"],
      ["--stream", "--with-gtid", "f"],
      ["--stream", "--table", "t", "f"],
    ] {
    invalid_args(args[:])
  }
}
