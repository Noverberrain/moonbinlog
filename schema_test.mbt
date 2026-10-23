// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn schema_one_column() -> Json {
  {
    "schema_version": 1,
    "tables": [
      {
        "database": "shop",
        "table": "orders",
        "columns": [
          {
            "name": "id",
            "wire_type": 3,
            "metadata": "",
            "nullable": false,
            "unsigned": false,
          },
        ],
      },
    ],
  }
}

///|
fn schema_table_object(value : Json) -> Map[String, Json] raise {
  guard value is { "tables": [Object(table), ..], .. } else {
    fail("expected table")
  }
  table
}

///|
fn schema_column_object(value : Json) -> Map[String, Json] raise {
  let table = schema_table_object(value)
  guard table.get("columns") is Some([Object(column), ..]) else {
    fail("expected column")
  }
  column
}

///|
fn schema_error(text : StringView) -> @moonbinlog.SchemaError raise {
  try @moonbinlog.SchemaConfig::parse(text) catch {
    error => error
  } noraise {
    _ => fail("invalid schema accepted")
  }
}

///|
fn schema_path(value : Json, expected : String) -> Unit raise {
  match schema_error(value.stringify()) {
    InvalidSchema(path~, ..) => assert_eq(path, expected)
    other => fail("unexpected schema error: \{Repr(other)}")
  }
}

///|
fn schema_map() -> @moonbinlog.TableMap raise {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  @moonbinlog.TableMap::parse(format, tm_basic, file_offset=126)
}

///|
fn schema_for_map(table : @moonbinlog.TableMap) -> Json {
  let columns = []
  for i, column in table.columns {
    let fields : Map[String, Json] = {
      "name": Json::string("c\{i}"),
      "wire_type": @json.to_json(column.wire_type.to_int()),
      "metadata": Json::string(@hex.encode(column.metadata)),
      "nullable": @json.to_json(column.nullable),
    }
    match column.wire_type {
      1 | 2 | 3 | 8 | 9 => fields["unsigned"] = @json.to_json(false)
      _ => ()
    }
    columns.push(Json::object(fields))
  }
  {
    "schema_version": 1,
    "tables": [
      Json::object({
        "database": Json::string(table.database),
        "table": Json::string(table.table),
        "columns": Json::array(columns),
      }),
    ],
  }
}

///|
fn schema_bind_error(
  config : @moonbinlog.SchemaConfig,
  table : @moonbinlog.TableMap,
) -> @moonbinlog.SchemaError raise {
  try config.bind(table) catch {
    error => error
  } noraise {
    _ => fail("mismatched schema bound successfully")
  }
}

///|
test "schema parser retains immutable names descriptors and integer flags" {
  let config = @moonbinlog.SchemaConfig::parse(schema_one_column().stringify())
  assert_eq(config.length(), 1)
  guard config.get("shop", "orders") is Some(table) else {
    fail("missing table")
  }
  assert_eq(table.database, "shop")
  assert_eq(table.table, "orders")
  assert_eq(table.columns[0].name, "id")
  assert_eq(table.columns[0].wire_type, 3)
  assert_eq(table.columns[0].metadata, b"")
  assert_false(table.columns[0].nullable)
  assert_eq(table.columns[0].unsigned, Some(false))
  assert_eq(config.get("SHOP", "orders"), None)
}

///|
test "schema empty registry and input StringView are supported" {
  let text = "prefix{\"schema_version\":1,\"tables\":[]}suffix"
  let config = @moonbinlog.SchemaConfig::parse(text[6:text.length() - 6])
  assert_eq(config.length(), 0)
  assert_eq(config.get("shop", "orders"), None)
}

///|
test "schema rejects malformed JSON root version and missing tables" {
  for
    text in [
      "", "{", "{} trailing", "/*x*/{}", "{\"schema_version\":1,\"tables\":[],}",
    ] {
    match schema_error(text) {
      InvalidSchema(..) => ()
      other => fail("\{Repr(other)}")
    }
  }
  for
    value in [
      Json::null(),
      [],
      "text",
      { "schema_version": 2, "tables": [] },
      { "schema_version": "1", "tables": [] },
      { "schema_version": true, "tables": [] },
      { "tables": [] },
      { "schema_version": 1 },
      { "schema_version": 1, "tables": {} },
    ] {
    match schema_error(value.stringify()) {
      InvalidSchema(..) => ()
      other => fail("\{Repr(other)}")
    }
  }
}

///|
test "schema rejects unknown fields at each structural level" {
  let value = schema_one_column()
  guard value is Object(root) else { fail("expected root") }
  root["extra"] = null
  schema_path(value, "$.extra")
  let value = schema_one_column()
  schema_table_object(value)["extra"] = null
  schema_path(value, "$.tables[0].extra")
  let value = schema_one_column()
  schema_column_object(value)["unsignd"] = true
  schema_path(value, "$.tables[0].columns[0].unsignd")
}

///|
test "schema names reject empty NUL oversized and nonstring values" {
  for
    bad in [
      Json::string(""),
      Json::string("a\u0000b"),
      Json::string("x".repeat(257)),
      Json::number(3.0),
    ] {
    for key in ["database", "table"] {
      let value = schema_one_column()
      schema_table_object(value)[key] = bad
      schema_path(value, "$.tables[0].\{key}")
    }
    let value = schema_one_column()
    schema_column_object(value)["name"] = bad
    schema_path(value, "$.tables[0].columns[0].name")
  }
}

///|
test "schema duplicate table and column definitions are errors" {
  let value = schema_one_column()
  guard value is Object(root) else { fail("expected root") }
  let table = Json::object(schema_table_object(value))
  root["tables"] = Json::array([table, table])
  schema_path(value, "$.tables[1]")
  let value = schema_one_column()
  let table = schema_table_object(value)
  let column = Json::object(schema_column_object(value))
  table["columns"] = Json::array([column, column])
  schema_path(value, "$.tables[0].columns[1].name")
}

///|
test "schema duplicate JSON members cannot silently overwrite signedness or nested values" {
  for
    text in [
      (
        #|{"schema_version":1,"schema_version":1,"tables":[]}
      ),
      (
        #|{"schema_version":1,"schema\u005fversion":1,"tables":[]}
      ),
      (
        #|{"schema_version":1,"tables":[{"x":{"a":1},"x":0}]}
      ),
      (
        #|{"schema_version":1,"tables":[{"x":[{"a":1,"a":2}]}]}
      ),
      (
        #|{"schema_version":1,"tables":[{"database":"s","table":"t","columns":[{"name":"id","wire_type":3,"metadata":"","nullable":false,"unsigned":false,"unsigned":true}]}]}
      ),
    ] {
    match schema_error(text) {
      InvalidSchema(path="$", reason="duplicate JSON object members") => ()
      other => fail("duplicate member detection failed: \{Repr(other)}")
    }
  }
}

///|
test "schema lexical preflight handles colons brackets quotes backslashes and Unicode inside strings" {
  let value = schema_one_column()
  let name = "列:[]{}\"\\\u{1f430}"
  schema_column_object(value)["name"] = Json::string(name)
  let table = schema_table_object(value)
  table["database"] = Json::string("a.b")
  table["table"] = Json::string("c")
  let other : Json = {
    "database": "a",
    "table": "b.c",
    "columns": [
      {
        "name": "id",
        "wire_type": 3,
        "metadata": "",
        "nullable": false,
        "unsigned": true,
      },
    ],
  }
  guard value is Object(root) else { fail("expected root") }
  root["tables"] = Json::array([Json::object(table), other])
  let config = @moonbinlog.SchemaConfig::parse(value.stringify())
  assert_eq(config.length(), 2)
  guard config.get("a.b", "c") is Some(first) else {
    fail("missing dotted identity")
  }
  assert_eq(first.columns[0].name, name)
  guard config.get("a", "b.c") is Some(second) else {
    fail("tuple key collision")
  }
  assert_eq(second.columns[0].unsigned, Some(true))
}

///|
test "schema requires nonempty columns objects and all mandatory fields" {
  for
    columns in [
      Json::null(),
      Json::array([]),
      Json::array([null]),
      Json::object({}),
    ] {
    let value = schema_one_column()
    schema_table_object(value)["columns"] = columns
    match schema_error(value.stringify()) {
      InvalidSchema(..) => ()
      other => fail("\{Repr(other)}")
    }
  }
  for field in ["name", "wire_type", "metadata", "nullable", "unsigned"] {
    let value = schema_one_column()
    schema_column_object(value).remove(field) |> ignore
    schema_path(value, "$.tables[0].columns[0].\{field}")
  }
}

///|
test "schema wire codes are integral bytes and metadata must have the exact supported width" {
  for
    code in [
      Json::number(-1.0),
      Json::number(256.0),
      Json::number(3.5),
      Json::string("3"),
      Json::number(20.0),
    ] {
    let value = schema_one_column()
    schema_column_object(value)["wire_type"] = code
    schema_path(value, "$.tables[0].columns[0].wire_type")
  }
  for metadata in [Json::string("0"), Json::string("0000"), Json::number(0.0)] {
    let value = schema_one_column()
    schema_column_object(value)["metadata"] = metadata
    schema_path(value, "$.tables[0].columns[0].metadata")
  }
  let value = schema_one_column()
  let column = schema_column_object(value)
  column["wire_type"] = 15
  column.remove("unsigned") |> ignore
  for metadata in ["GG00", "0x00", "000"] {
    column["metadata"] = Json::string(metadata)
    schema_path(value, "$.tables[0].columns[0].metadata")
  }
  column["metadata"] = "Ff00"
  let config = @moonbinlog.SchemaConfig::parse(value.stringify())
  guard config.get("shop", "orders") is Some(table) else {
    fail("missing table")
  }
  assert_eq(table.columns[0].metadata, b"\xff\x00")
}

///|
test "schema signedness is explicit for all integer widths and forbidden on other types" {
  for code in [1, 2, 3, 8, 9] {
    for flag in [Json::null(), Json::number(1.0), Json::string("false")] {
      let value = schema_one_column()
      let column = schema_column_object(value)
      column["wire_type"] = @json.to_json(code)
      column["unsigned"] = flag
      schema_path(value, "$.tables[0].columns[0].unsigned")
    }
  }
  for flag in [Json::null(), Json::boolean(false), Json::boolean(true)] {
    let value = schema_one_column()
    let column = schema_column_object(value)
    column["wire_type"] = 10
    column["unsigned"] = flag
    schema_path(value, "$.tables[0].columns[0].unsigned")
  }
  for nullable in [Json::null(), Json::number(0.0), Json::string("false")] {
    let value = schema_one_column()
    schema_column_object(value)["nullable"] = nullable
    schema_path(value, "$.tables[0].columns[0].nullable")
  }
}

///|
test "schema invalid limit configurations and nesting fail before construction" {
  for (tables, columns, units) in [(0, 1, 1), (1, 0, 1), (1, 1, 0), (-1, 1, 1)] {
    try
      @moonbinlog.SchemaConfig::parse(
        "{}",
        max_tables=tables,
        max_columns=columns,
        max_input_units=units,
      )
    catch {
      InvalidSchemaLimits(..) => ()
      other => fail("unexpected limit error: \{Repr(other)}")
    } noraise {
      _ => fail("invalid schema limits accepted")
    }
  }
  let deep = "[".repeat(17) + "0" + "]".repeat(17)
  match schema_error(deep) {
    SchemaLimitExceeded(path="$", ..) => ()
    other => fail("\{Repr(other)}")
  }
}

///|
test "schema table column and UTF16 input budgets accept exact bounds" {
  let value = schema_one_column()
  schema_column_object(value)["name"] = Json::string("\u{1f430}")
  let text = value.stringify()
  let config = @moonbinlog.SchemaConfig::parse(
    text,
    max_tables=1,
    max_columns=1,
    max_input_units=text.length(),
  )
  assert_eq(config.length(), 1)
  try
    @moonbinlog.SchemaConfig::parse(text, max_input_units=text.length() - 1)
  catch {
    SchemaLimitExceeded(path="$", ..) => ()
    other => fail("\{Repr(other)}")
  } noraise {
    _ => fail("input budget bypassed")
  }
  guard value is Object(root) else { fail("expected root") }
  let table = Json::object(schema_table_object(value))
  root["tables"] = Json::array([table, table])
  try @moonbinlog.SchemaConfig::parse(value.stringify(), max_tables=1) catch {
    SchemaLimitExceeded(path="$.tables", ..) => ()
    other => fail("\{Repr(other)}")
  } noraise {
    _ => fail("table budget bypassed")
  }
  let value = schema_one_column()
  let table = schema_table_object(value)
  let column = Json::object(schema_column_object(value))
  table["columns"] = Json::array([column, column])
  try @moonbinlog.SchemaConfig::parse(value.stringify(), max_columns=1) catch {
    SchemaLimitExceeded(path="$.tables[0].columns", ..) => ()
    other => fail("\{Repr(other)}")
  } noraise {
    _ => fail("column budget bypassed")
  }
}

///|
test "schema binding produces ordered labels signs and a stable table snapshot" {
  let table = schema_map()
  let value = schema_for_map(table)
  schema_column_object(value)["unsigned"] = true
  let config = @moonbinlog.SchemaConfig::parse(value.stringify())
  let bound = config.bind(table)
  assert_eq(bound.table_map, table)
  assert_eq(bound.schema.columns[0].name, "c0")
  assert_eq(bound.integer_unsigned, [
    Some(true),
    None,
    None,
    None,
    None,
    Some(false),
    Some(false),
    Some(false),
    Some(false),
    None,
  ])
  assert_eq(config.bind(table), bound)
  schema_column_object(value)["unsigned"] = false
  assert_eq(bound.integer_unsigned[0], Some(true))
}

///|
test "schema binding reports missing tables count differences and column descriptor mismatches" {
  let table = schema_map()
  let empty = @moonbinlog.SchemaConfig::parse(
    "{\"schema_version\":1,\"tables\":[]}",
  )
  assert_eq(
    schema_bind_error(empty, table),
    MissingTableSchema(file_offset=126, database="shop", table="orders"),
  )
  let value = schema_for_map(table)
  guard schema_table_object(value).get("columns") is Some(Array(columns)) else {
    fail("expected columns")
  }
  columns.pop() |> ignore
  let config = @moonbinlog.SchemaConfig::parse(value.stringify())
  match schema_bind_error(config, table) {
    SchemaMismatch(column_index=None, file_offset=126, ..) => ()
    other => fail("\{Repr(other)}")
  }
  for
    (field, replacement) in [
      ("wire_type", Json::number(3.0)),
      ("nullable", Json::boolean(false)),
    ] {
    let value = schema_for_map(table)
    schema_column_object(value)[field] = replacement
    let config = @moonbinlog.SchemaConfig::parse(value.stringify())
    match schema_bind_error(config, table) {
      SchemaMismatch(column_index=Some(0), ..) => ()
      other => fail("\{Repr(other)}")
    }
  }
  let value = schema_for_map(table)
  guard schema_table_object(value).get("columns")
    is Some([_, Object(second), ..]) else {
    fail("expected second column")
  }
  second["metadata"] = "5902"
  let config = @moonbinlog.SchemaConfig::parse(value.stringify())
  match schema_bind_error(config, table) {
    SchemaMismatch(column_index=Some(1), ..) => ()
    other => fail("\{Repr(other)}")
  }
}

///|
test "schema binding rejects changed order and table-id reuse with another identity" {
  let table = schema_map()
  let config = @moonbinlog.SchemaConfig::parse(
    schema_for_map(table).stringify(),
  )
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  let renamed = @moonbinlog.TableMap::parse(format, tm_renamed, file_offset=500)
  assert_eq(renamed.table_id, table.table_id)
  match schema_bind_error(config, renamed) {
    MissingTableSchema(file_offset=500, ..) => ()
    other => fail("\{Repr(other)}")
  }
  let value = schema_for_map(table)
  guard schema_table_object(value).get("columns") is Some(Array(columns)) else {
    fail("expected columns")
  }
  let first = columns[0]
  columns[0] = columns[1]
  columns[1] = first
  let changed = @moonbinlog.SchemaConfig::parse(value.stringify())
  match schema_bind_error(changed, table) {
    SchemaMismatch(column_index=Some(0), ..) => ()
    other => fail("\{Repr(other)}")
  }
}

///|
test "schema bindings feed existing row decoder for real MySQL FULL MINIMAL and OFF captures" {
  for data in [mysql_crc32_full, mysql_crc32_minimal, mysql_off_full] {
    let events = mysql_events(data)
    let table_event = events[4]
    let table = @moonbinlog.TableMap::parse(
      table_event.format,
      table_event.raw,
      file_offset=table_event.header.file_offset,
    )
    let value = schema_for_map(table)
    guard schema_table_object(value).get("columns")
      is Some([_, _, _, _, Object(big), ..]) else {
      fail("expected BIGINT column")
    }
    big["unsigned"] = true
    let config = @moonbinlog.SchemaConfig::parse(value.stringify())
    let bound = config.bind(table)
    assert_eq(bound.integer_unsigned, mysql_signs)
    let context = @moonbinlog.TableMapContext::new(table_event.format)
    context.apply(table_event.raw, file_offset=table_event.header.file_offset)
    |> ignore
    let row_event = events[5]
    let rows = context.decode_rows(
      row_event.raw,
      file_offset=row_event.header.file_offset,
      integer_unsigned=bound.integer_unsigned,
    )
    guard rows.changes[0] is Insert(row) else { fail("expected real insert") }
    assert_eq(row.columns[4], Integer(Unsigned(18446744073709551615)))
    assert_eq(bound.schema.columns[4].name, "c4")
    assert_eq(context.length(), 0)
  }
}
