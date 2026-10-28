// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
test "CLI bound transactions accepts schema rows summary filters and literal paths" {
  guard @cli.parse_args([
      "--with-gtid", "--transactions", "--schema", "s", "--include-rows", "--summary",
      "--database", "db", "--table", "t", "f",
    ])
    is Inspect(config) else {
    fail("missing config")
  }
  assert_true(config.with_gtid)
  assert_true(config.transactions)
  assert_true(config.include_rows)
  assert_true(config.summary_only)
  assert_true(config.json_output)
  guard @cli.parse_args(["--", "--with-gtid"]) is Inspect(config) else {
    fail("missing literal path")
  }
  assert_false(config.with_gtid)
}

///|
test "CLI bound transactions rejects incompatible modes and duplicate flag" {
  for
    args in [
      ["--with-gtid", "f"],
      ["--with-gtid", "--summary", "f"],
      ["--with-gtid", "--transactions", "f"],
      ["--with-gtid", "--with-gtid", "--transactions", "--schema", "s", "f"],
      ["--with-gtid", "--rows", "--schema", "s", "f"],
      ["--with-gtid", "--schema-template", "f"],
      ["--with-gtid", "--transactions", "--schema", "s", "--decode-gtid", "f"],
      ["--with-gtid", "--transactions", "--schema", "s", "--decode-rotate", "f"],
      [
        "--with-gtid", "--transactions", "--schema", "s", "--decode-previous-gtids",
        "f",
      ],
      ["--with-gtid", "--chain", "a", "b"],
    ] {
    invalid_args(args[:])
  }
}
