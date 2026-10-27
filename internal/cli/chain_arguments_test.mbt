// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
test "CLI chain accepts ordered explicit paths summary and bounded total bytes" {
  guard @cli.parse_args([
      "first", "--chain", "--decode-rotate", "--summary", "--max-total-bytes", "1000",
      "--", "--second",
    ])
    is Inspect(config) else {
    fail("missing chain config")
  }
  assert_true(config.chain)
  assert_true(config.json_output)
  assert_true(config.decode_rotate)
  assert_eq(config.paths, ["first", "--second"])
  assert_eq(config.path, "first")
  assert_eq(config.max_total_bytes, 1000)
  guard @cli.parse_args(["single"]) is Inspect(config) else {
    fail("missing single config")
  }
  assert_false(config.chain)
  assert_eq(config.paths, ["single"])
  assert_eq(config.max_total_bytes, 268435456)
  let args = ["--chain"]
  for i in 0..<128 {
    args.push("file\{i}")
  }
  @cli.parse_args(args[:]) |> ignore
  args.push("too-many")
  invalid_args(args[:])
}

///|
test "CLI chain rejects too few files limits and incompatible modes" {
  for
    args in [
      ["--chain"],
      ["--chain", "a"],
      ["a", "b"],
      ["--chain", "--chain", "a", "b"],
      ["--max-total-bytes", "100", "a"],
      ["--chain", "--max-total-bytes", "0", "a", "b"],
      ["--chain", "--max-total-bytes", "2147483648", "a", "b"],
      ["--chain", "--max-total-bytes", "1", "--max-total-bytes", "2", "a", "b"],
      ["--chain", "--rows", "--schema", "s", "a", "b"],
      ["--chain", "--transactions", "--schema", "s", "a", "b"],
      ["--chain", "--schema-template", "a", "b"],
      ["--chain", "--use-table-metadata", "a", "b"],
      ["--chain", "--table", "sample", "a", "b"],
      ["--chain", "--include-rows", "a", "b"],
    ] {
    invalid_args(args[:])
  }
}
