// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
test "CLI schema template mode selects JSON and accepts byte limits and terminator" {
  guard @cli.parse_args([
      "--schema-template", "--json", "--max-event-bytes", "512", "--max-file-bytes",
      "4096", "--", "--file",
    ])
    is Inspect(config) else {
    fail("expected inspect")
  }
  assert_true(config.schema_template)
  assert_true(config.json_output)
  assert_false(config.rows)
  assert_false(config.transactions)
  assert_eq(config.path, "--file")
  assert_eq(config.max_event_bytes, 512U)
  assert_eq(config.max_file_bytes, 4096)
  guard @cli.parse_args(["--", "--schema-template"]) is Inspect(config) else {
    fail("expected path")
  }
  assert_false(config.schema_template)
}

///|
test "CLI schema template rejects conflicting or duplicate mode options" {
  for
    args in [
      ["--schema-template", "--schema-template", "file"],
      ["--schema-template", "--summary", "file"],
      ["--schema-template", "--rows", "--schema", "a", "file"],
      ["--schema-template", "--transactions", "--schema", "a", "file"],
      ["--schema-template", "--include-rows", "file"],
      ["--schema-template", "--schema", "a", "file"],
      ["--schema-template", "--database", "shop", "file"],
      ["--schema-template", "--table", "orders", "file"],
      ["--schema-template"],
    ] {
    invalid_args(args[:])
  }
}
