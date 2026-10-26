// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
test "CLI filters parse exact names once and require a decoding mode" {
  guard @cli.parse_args([
      "--rows", "--schema", "a", "--database", "库.名", "file", "--table", "表 *",
    ])
    is Inspect(config) else {
    fail("expected inspect")
  }
  assert_eq(config.filter, { database: Some("库.名"), table: Some("表 *"), })
  for
    args in [
      ["--database", "shop", "file"],
      ["--table", "orders", "--json", "file"],
      ["--rows", "--schema", "a", "--database"],
      ["--rows", "--schema", "a", "--table", "", "file"],
      ["--rows", "--schema", "a", "--database", "a\u0000b", "file"],
      ["--rows", "--schema", "a", "--database", "a", "--database", "b", "file"],
      [
        "--transactions", "--schema", "a", "--table", "a", "--table", "b", "file",
      ],
    ] {
    invalid_args(args[:])
  }
  let mut name = ""
  for _ in 0..<256 {
    name += "x"
  }
  @cli.parse_args(["--transactions", "--schema", "a", "--table", name, "file"])
  |> ignore
  invalid_args([
    "--transactions",
    "--schema",
    "a",
    "--table",
    name + "x",
    "file",
  ])
  guard @cli.parse_args(["--", "--database"]) is Inspect(path) else {
    fail("expected path")
  }
  assert_false(path.filter.is_active())
}

///|
test "CLI filters use case sensitive database table pairs and literal punctuation" {
  assert_true(@cli.TableFilter::all().matches("any", "any"))
  let database = @cli.TableFilter::{ database: Some("库.名"), table: None, }
  assert_true(database.matches("库.名", "anything"))
  assert_false(database.matches("库", "名.anything"))
  let table = @cli.TableFilter::{ database: None, table: Some("orders"), }
  assert_true(table.matches("shop", "orders"))
  assert_true(table.matches("other", "orders"))
  assert_false(table.matches("shop", "Orders"))
  let both = @cli.TableFilter::{ database: Some("a.b"), table: Some("c*"), }
  assert_true(both.matches("a.b", "c*"))
  assert_false(both.matches("a", "b.c*"))
  assert_false(both.matches("a.b", "customer"))
}

///|
test "CLI filtered summaries distinguish scanned totals from selected output" {
  let stats = @cli.Stats::new()
  let filter = @cli.TableFilter::{ database: None, table: Some("orders"), }
  guard @json.parse(stats.filtered_row_json_line(4, 5, 7, filter, 2, 3))
    is {
      "row_events": 5,
      "changes": 7,
      "selected_row_events": 2,
      "selected_changes": 3,
      "filter": {
        "database": Null,
        "table": "orders",
        "scope": "row_events",
        ..
      },
      ..
    } else {
    fail("row selection summary differs")
  }
  let all = @cli.TransactionStats::new()
  let selected = @cli.TransactionStats::new()
  all.record(RolledBack(start_offset=4, end_offset=50, discarded_changes=5))
  guard @json.parse(all.filtered_json_line(stats, 50, filter, selected))
    is {
      "rolled_back_transactions": 1,
      "discarded_changes": 5,
      "selected_rolled_back_transactions": 0,
      "selected_discarded_changes": 0,
      "filter": {
        "database": Null,
        "table": "orders",
        "scope": "whole_transactions",
        ..
      },
      ..
    } else {
    fail("transaction selection summary differs")
  }
}
