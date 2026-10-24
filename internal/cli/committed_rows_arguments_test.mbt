// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
test "CLI committed rows modifier requires transaction mode and accepts summary" {
  for
    args in [
      ["--transactions", "--include-rows", "--schema", "a", "file"],
      [
        "file", "--include-rows", "--schema", "a", "--summary", "--transactions",
        "--json",
      ],
    ] {
    guard @cli.parse_args(args[:]) is Inspect(config) else {
      fail("expected inspect")
    }
    assert_true(config.include_rows)
    assert_true(config.transactions)
    assert_true(config.json_output)
    assert_false(config.rows)
  }
  for
    args in [
      ["--include-rows", "file"],
      ["--include-rows", "--schema", "a", "file"],
      ["--rows", "--include-rows", "--schema", "a", "file"],
      [
        "--transactions", "--include-rows", "--include-rows", "--schema", "a", "file",
      ],
    ] {
    invalid_args(args[:])
  }
  guard @cli.parse_args(["--", "--include-rows"]) is Inspect(config) else {
    fail("expected filename")
  }
  assert_false(config.include_rows)
}
