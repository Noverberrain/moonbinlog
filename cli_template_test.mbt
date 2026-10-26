// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn cli_template(data : BytesView) -> String raise {
  let template = @cli.SchemaTemplate::new()
  let reader = @moonbinlog.BinlogFileReader::new(data)
  while reader.next() is Some(event) {
    template.feed(event)
  }
  template.render()
}

///|
test "schema template matches six real captures and requires integer review" {
  for
    data in [
      mysql_crc32_full, mysql_crc32_minimal, mysql_off_full, mysql_json_crc32_full,
      mysql_json_crc32_minimal, mysql_json_off_full,
    ] {
    let text = cli_template(data)
    let value = @json.parse(text)
    guard value is { "schema_version": 1, "tables": [Object(fields)], .. } else {
      fail("expected one table")
    }
    guard fields.get("columns") is Some(Array(columns)) else {
      fail("missing columns")
    }
    let event = mysql_events(data)[4]
    let table = @moonbinlog.TableMap::parse(
      event.format,
      event.raw,
      file_offset=event.header.file_offset,
    )
    assert_eq(columns.length(), table.columns.length())
    for i, column in columns {
      guard column is Object(fields) else { fail("missing column") }
      assert_eq(fields.get("name"), Some(Json::string("column_\{i + 1}")))
      assert_eq(
        fields.get("wire_type"),
        Some(@json.to_json(table.columns[i].wire_type.to_int())),
      )
      assert_eq(
        fields.get("metadata"),
        Some(Json::string(@hex.encode(table.columns[i].metadata))),
      )
      assert_eq(
        fields.get("nullable"),
        Some(@json.to_json(table.columns[i].nullable)),
      )
      match table.columns[i].wire_type {
        1 | 2 | 3 | 8 | 9 => {
          assert_eq(fields.get("unsigned"), Some(Json::null()))
          fields["unsigned"] = false // Explicit review in this test; not inferred by template.
        }
        _ => assert_eq(fields.get("unsigned"), None)
      }
    }
    try @moonbinlog.SchemaConfig::parse(text) catch {
      InvalidSchema(..) => ()
      other => fail("unexpected unreviewed error: \{Repr(other)}")
    } noraise {
      _ => fail("integer null silently became signed")
    }
    let reviewed = @moonbinlog.SchemaConfig::parse(value.stringify())
    let bound = reviewed.bind(table)
    assert_eq(bound.schema.columns.length(), table.columns.length())
  }
}

///|
test "schema template deduplicates descriptors ignoring id flags padding and optional metadata" {
  let events = cli_synthetic_events(
    tm_basic +
    tm_second_id +
    tm_optional +
    tm_padding_bits +
    tm_count_fc +
    tm_renamed +
    tm_unicode,
  )
  let template = @cli.SchemaTemplate::new()
  for event in events {
    template.feed(event)
  }
  guard @json.parse(template.render()) is { "tables": Array(tables), .. } else {
    fail("missing tables")
  }
  assert_eq(tables.length(), 3)
  guard tables[0]
    is { "database": "shop", "table": "orders", "columns": Array(columns), .. } else {
    fail("wrong first table")
  }
  assert_eq(columns[0], {
    "name": "column_1",
    "wire_type": 8,
    "metadata": "",
    "nullable": true,
    "unsigned": Json::null(),
  })
  guard tables[1] is { "table": "orders_archive", .. } else {
    fail("wrong discovery order")
  }
  guard tables[2] is { "database": "商店", "table": "订单", .. } else {
    fail("wrong unicode names")
  }
  assert_eq(template.render(), template.render())
}

///|
test "schema template conflict carries both physical offsets and permanently aborts" {
  let events = cli_synthetic_events(tm_basic + tm_strings)
  let template = @cli.SchemaTemplate::new()
  template.feed(events[1])
  try template.feed(events[2]) catch {
    @cli.TemplateError::ConflictingTable(
      database~,
      table~,
      first_offset~,
      file_offset~
    ) => {
      assert_eq(database, "shop")
      assert_eq(table, "orders")
      assert_eq(first_offset, events[1].header.file_offset)
      assert_eq(file_offset, events[2].header.file_offset)
    }
    other => fail("unexpected conflict: \{Repr(other)}")
  } noraise {
    _ => fail("different descriptors overwritten")
  }
  try template.render() catch {
    TemplateAborted => ()
    other => fail("unexpected render error: \{Repr(other)}")
  } noraise {
    _ => fail("partial draft escaped")
  }
  try template.feed(events[1]) catch {
    @cli.TemplateError::TemplateAborted => ()
    other => fail("unexpected recovery: \{Repr(other)}")
  } noraise {
    _ => fail("aborted collector recovered")
  }
}

///|
test "schema template caps table count output and rejects invalid limits" {
  let events = cli_synthetic_events(tm_basic + tm_renamed)
  let template = @cli.SchemaTemplate::new(max_tables=1)
  template.feed(events[1])
  try template.feed(events[2]) catch {
    @cli.TemplateError::TemplateLimit(_) => ()
    other => fail("unexpected table budget error: \{Repr(other)}")
  } noraise {
    _ => fail("table limit ignored")
  }
  let template = @cli.SchemaTemplate::new(max_output_units=32)
  try template.feed(events[1]) catch {
    @cli.TemplateError::TemplateLimit(_) => ()
    other => fail("unexpected output budget error: \{Repr(other)}")
  } noraise {
    _ => fail("output limit ignored")
  }
  try template.render() catch {
    TemplateAborted => ()
    other => fail("unexpected render error: \{Repr(other)}")
  } noraise {
    _ => fail("oversized template escaped")
  }
  for (tables, units, event_size) in [(0, 32, 19U), (1, 31, 19U), (1, 32, 18U)] {
    try
      @cli.SchemaTemplate::new(
        max_tables=tables,
        max_output_units=units,
        max_event_size=event_size,
      )
    catch {
      InvalidTemplate(_) => ()
      other => fail("unexpected configuration error: \{Repr(other)}")
    } noraise {
      _ => fail("invalid template limits accepted")
    }
  }
}

///|
test "schema template returns empty registry and inspects no non table body semantics" {
  let template = @cli.SchemaTemplate::new(max_output_units=32)
  assert_eq(@json.parse(template.render()), {
    "schema_version": 1,
    "tables": [],
  })
  let events = cli_synthetic_events(tx_begin + tx_unknown + rows_json_bad)
  for event in events {
    template.feed(event)
  }
  assert_eq(@json.parse(template.render()), {
    "schema_version": 1,
    "tables": [],
  })
}

///|
test "schema template malformed table map clears an earlier collected draft" {
  for bad in [tm_short_metadata, tm_zero_columns, tm_short_tlv] {
    let events = cli_synthetic_events(tm_basic + bad)
    let template = @cli.SchemaTemplate::new()
    template.feed(events[1])
    try template.feed(events[2]) catch {
      @moonbinlog.DecodeError::InvalidTableMap(..) => ()
      other => fail("unexpected malformed TABLE_MAP error: \{Repr(other)}")
    } noraise {
      _ => fail("invalid map accepted")
    }
    try template.render() catch {
      TemplateAborted => ()
      other => fail("unexpected render error: \{Repr(other)}")
    } noraise {
      _ => fail("invalid template escaped")
    }
  }
}
