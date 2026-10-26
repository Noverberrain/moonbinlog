// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn metadata_template(
  events : Array[@moonbinlog.BinlogFileEvent],
) -> String raise {
  let draft = @cli.SchemaTemplate::new(use_table_metadata=true)
  for event in events {
    draft.feed(event)
  }
  draft.render()
}

///|
test "schema metadata creates usable schemas for six real captures without manual signedness" {
  for
    data in [
      mysql_crc32_full, mysql_crc32_minimal, mysql_off_full, mysql_json_crc32_full,
      mysql_json_crc32_minimal, mysql_json_off_full,
    ] {
    let events = mysql_events(data)
    let text = metadata_template(events)
    let schema = @moonbinlog.SchemaConfig::parse(text)
    let table_event = events[4]
    let table = @moonbinlog.TableMap::parse(
      table_event.format,
      table_event.raw,
      file_offset=table_event.header.file_offset,
    )
    let bound = schema.bind(table)
    assert_eq(bound.schema.columns[0].name, "id")
    assert_eq(bound.integer_unsigned[0], Some(false))
    if table.columns.length() == 20 {
      assert_eq(bound.integer_unsigned, mysql_signs)
      assert_eq(bound.schema.columns[4].name, "big_value")
    } else {
      assert_eq(bound.schema.columns[1].name, "text_value")
      assert_eq(bound.integer_unsigned[1], None)
    }
    let outcomes = cli_tx_run(@cli.TransactionScanner::new(schema), events)
    guard outcomes[0] is Committed(transaction) else {
      fail("missing transaction")
    }
    assert_eq(
      transaction.change_count,
      if table.columns.length() == 20 {
        4
      } else {
        6
      },
    )
  }
}

///|
test "schema metadata fills missing hints in either discovery order and keeps independent fallback" {
  let complete = metadata_template(cli_synthetic_events(tm_optional))
  for
    raw in [
      tm_basic + tm_optional,
      tm_optional + tm_basic,
      tm_basic + tm_optional + tm_optional,
    ] {
    assert_eq(metadata_template(cli_synthetic_events(raw)), complete)
  }
  let registry = @moonbinlog.SchemaConfig::parse(complete)
  guard registry.get("shop", "orders") is Some(table) else {
    fail("missing table")
  }
  assert_eq(table.columns[0].name, "id")
  assert_eq(table.columns[0].unsigned, Some(true))
  // DECIMAL occupies the second numeric slot; the next INT receives bit 2.
  assert_eq(table.columns[5].unsigned, Some(true))
  assert_eq(table.columns[6].unsigned, Some(false))
  let fallback = metadata_template(cli_synthetic_events(tm_basic))
  assert_eq(
    @json.parse(fallback),
    @json.parse(cli_template(file_magic + fde_crc32 + tm_basic)),
  )
}

///|
test "schema metadata ignores unknown optional fields and respects enrichment budget" {
  assert_eq(
    metadata_template(cli_synthetic_events(tm_max_tlv)),
    metadata_template(cli_synthetic_events(tm_basic)),
  )
  let events = cli_synthetic_events(tm_basic + tm_optional)
  let initial = metadata_template([events[1]])
  let draft = @cli.SchemaTemplate::new(
    use_table_metadata=true,
    max_output_units=initial.length() + 1,
  )
  draft.feed(events[1])
  // This fixture's real names are shorter overall than column_N placeholders.
  draft.feed(events[2])
  assert_eq(draft.render(), metadata_template(events))
}

///|
test "schema metadata retains ordinary mode behavior for all optional hints" {
  let events = cli_synthetic_events(tm_basic + tm_optional)
  let ordinary = @cli.SchemaTemplate::new()
  for event in events {
    ordinary.feed(event)
  }
  assert_eq(ordinary.render(), cli_template(file_magic + fde_crc32 + tm_basic))
}
