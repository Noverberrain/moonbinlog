// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
test "CLI metadata hints require template mode and reject duplicates" {
  for
    args in [
      ["--use-table-metadata", "file"],
      ["--rows", "--schema", "a", "--use-table-metadata", "file"],
      [
        "--schema-template", "--use-table-metadata", "--use-table-metadata", "file",
      ],
    ] {
    invalid_args(args[:])
  }
  guard @cli.parse_args(["--use-table-metadata", "--schema-template", "file"])
    is Inspect(config) else {
    fail("missing config")
  }
  assert_true(config.use_table_metadata)
  assert_true(config.schema_template)
}

///|
test "CLI metadata hints stay opt in and terminator preserves filename" {
  guard @cli.parse_args(["--schema-template", "file"]) is Inspect(config) else {
    fail("missing config")
  }
  assert_false(config.use_table_metadata)
  guard @cli.parse_args(["--", "--use-table-metadata"]) is Inspect(config) else {
    fail("missing config")
  }
  assert_eq(config.path, "--use-table-metadata")
  assert_false(config.use_table_metadata)
}
