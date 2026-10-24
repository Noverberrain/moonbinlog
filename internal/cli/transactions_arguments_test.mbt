// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
test "CLI transactions select JSON and require an exclusive schema mode" {
  guard @cli.parse_args([
      "--transactions", "--schema", "配置.json", "--summary", "file",
    ])
    is Inspect(config) else {
    fail("expected inspect")
  }
  assert_true(config.transactions)
  assert_true(config.json_output)
  assert_true(config.summary_only)
  assert_false(config.rows)
  for
    args in [
      ["--transactions", "file"],
      ["--transactions", "--transactions", "--schema", "a", "file"],
      ["--rows", "--transactions", "--schema", "a", "file"],
      ["--schema", "a", "file"],
    ] {
    invalid_args(args[:])
  }
  guard @cli.parse_args(["--", "--transactions"]) is Inspect(path) else {
    fail("expected filename")
  }
  assert_false(path.transactions)
}
