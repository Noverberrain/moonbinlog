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
test "CLI stream rejects repeated flag and unsupported or multi-file modes" {
  for
    args in [
      ["--stream"],
      ["--stream", "--stream", "f"],
      ["--stream", "--chain", "a", "b"],
      ["--stream", "--rows", "f"],
      ["--stream", "--transactions", "--schema", "s", "f"],
      ["--stream", "--schema-template", "f"],
      ["--stream", "--include-rows", "f"],
      ["--stream", "--with-gtid", "f"],
      ["--stream", "--table", "t", "f"],
    ] {
    invalid_args(args[:])
  }
}

///|
test "CLI stream accepts rows schema filters summary and byte budgets" {
  guard @cli.parse_args([
      "--stream", "--rows", "--schema", "s", "--database", "db", "--table", "t",
      "--summary", "--max-event-bytes", "1024", "--max-file-bytes", "4096", "f",
    ])
    is Inspect(config) else {
    fail("missing row config")
  }
  assert_true(
    config.stream && config.rows && config.json_output && config.summary_only,
  )
  assert_eq(config.schema_path, Some("s"))
  assert_true(config.filter.matches("db", "t"))
  assert_false(config.filter.matches("db", "other"))
  assert_eq(config.max_event_bytes, 1024U)
  assert_eq(config.max_file_bytes, 4096)
  for
    args in [
      ["--stream", "--rows", "--schema", "s", "--decode-gtid", "f"],
      ["--stream", "--rows", "--schema", "s", "--decode-rotate", "f"],
      ["--stream", "--rows", "--schema", "s", "--decode-previous-gtids", "f"],
      ["--stream", "--rows", "--schema", "s", "--include-rows", "f"],
      ["--stream", "--rows", "--schema", "s", "--with-gtid", "f"],
      ["--stream", "--rows", "--schema", "s", "--use-table-metadata", "f"],
    ] {
    invalid_args(args[:])
  }
}
