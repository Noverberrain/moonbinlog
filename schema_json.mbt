// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// Parse schema_version=1 JSON. Unknown fields and duplicate object members,
/// table identities and column names are rejected. Limits are checked before
/// building the registry; max_input_units counts UTF-16 code units, not bytes.
///
/// ```mbt check
/// test {
///   let config = @moonbinlog.SchemaConfig::parse(
///     "{\"schema_version\":1,\"tables\":[]}",
///   )
///   assert_eq(config.length(), 0)
///   assert_eq(config.get("shop", "orders"), None)
/// }
/// ```
pub fn SchemaConfig::parse(
  text : StringView,
  max_tables~ : Int32 = 1024,
  max_columns~ : Int32 = 1024,
  max_input_units~ : Int32 = 1_048_576,
) -> SchemaConfig raise SchemaError {
  guard max_tables > 0 && max_columns > 0 && max_input_units > 0 else {
    raise InvalidSchemaLimits(max_tables~, max_columns~, max_input_units~)
  }
  guard text.length() <= max_input_units else {
    raise SchemaLimitExceeded(
      path="$",
      reason="input exceeds UTF-16 unit limit",
    )
  }
  let members = schema_member_tokens(text)
  let value = @json.parse(text) catch {
    error => raise InvalidSchema(path="$", reason=error.to_string())
  }
  guard members == schema_member_count(value) else {
    raise InvalidSchema(path="$", reason="duplicate JSON object members")
  }
  let root = schema_object(value, "$")
  schema_keys(root, ["schema_version", "tables"], "$")
  guard root.get("schema_version") is Some(1) else {
    raise InvalidSchema(path="$.schema_version", reason="expected version 1")
  }
  guard root.get("tables") is Some(Array(entries)) else {
    raise InvalidSchema(path="$.tables", reason="expected an array")
  }
  guard entries.length() <= max_tables else {
    raise SchemaLimitExceeded(path="$.tables", reason="table limit exceeded")
  }
  let tables = Map([])
  for index, entry in entries {
    let path = "$.tables[\{index}]"
    let object = schema_object(entry, path)
    schema_keys(object, ["database", "table", "columns"], path)
    let database = schema_name(object, "database", path)
    let table = schema_name(object, "table", path)
    guard tables.get((database, table)) is None else {
      raise InvalidSchema(path~, reason="duplicate database/table pair")
    }
    guard object.get("columns") is Some(Array(columns)) && columns.length() > 0 else {
      raise InvalidSchema(
        path="\{path}.columns",
        reason="expected a nonempty array",
      )
    }
    guard columns.length() <= max_columns else {
      raise SchemaLimitExceeded(
        path="\{path}.columns",
        reason="column limit exceeded",
      )
    }
    let parsed = []
    let names = Map([])
    for i, column in columns {
      let column_path = "\{path}.columns[\{i}]"
      let column = schema_parse_column(column, column_path, i)
      guard names.get(column.name) is None else {
        raise InvalidSchema(
          path="\{column_path}.name",
          reason="duplicate column name",
        )
      }
      names[column.name] = true
      parsed.push(column)
    }
    tables[(database, table)] = TableSchema::{
      database,
      table,
      columns: ReadOnlyArray::from_array(parsed),
    }
  }
  { tables, }
}

///|
fn schema_object(
  value : Json,
  path : String,
) -> Map[String, Json] raise SchemaError {
  guard value is Object(object) else {
    raise InvalidSchema(path~, reason="expected an object")
  }
  object
}

///|
fn schema_keys(
  object : Map[String, Json],
  allowed : ArrayView[String],
  path : String,
) -> Unit raise SchemaError {
  for key, _ in object {
    guard allowed.contains(key) else {
      raise InvalidSchema(path="\{path}.\{key}", reason="unknown field")
    }
  }
}

///|
fn schema_name(
  object : Map[String, Json],
  key : String,
  path : String,
) -> String raise SchemaError {
  guard object.get(key) is Some(String(name)) &&
    !name.is_empty() &&
    name.length() <= 256 &&
    !name.contains("\u0000") else {
    raise InvalidSchema(
      path="\{path}.\{key}",
      reason="expected 1..256 UTF-16 units without NUL",
    )
  }
  name
}

///|
fn schema_parse_column(
  value : Json,
  path : String,
  index : Int32,
) -> SchemaColumn raise SchemaError {
  let object = schema_object(value, path)
  schema_keys(
    object,
    ["name", "wire_type", "metadata", "nullable", "unsigned"],
    path,
  )
  let name = schema_name(object, "name", path)
  guard object.get("wire_type") is Some(Number(code, ..)) &&
    code >= 0.0 &&
    code <= 255.0 &&
    code.to_int().to_double() == code else {
    raise InvalidSchema(
      path="\{path}.wire_type",
      reason="expected integer 0..255",
    )
  }
  let wire_type = code.to_int().to_byte()
  let width = column_metadata_length(
    wire_type,
    file_offset=0,
    column_index=index,
  ) catch {
    _ =>
      raise InvalidSchema(
        path="\{path}.wire_type",
        reason="unsupported TABLE_MAP wire type",
      )
  }
  guard object.get("metadata") is Some(String(hex)) && hex.length() == width * 2 else {
    raise InvalidSchema(
      path="\{path}.metadata",
      reason="hex length differs from wire metadata width",
    )
  }
  let metadata = @hex.decode(hex) catch {
    _ =>
      raise InvalidSchema(
        path="\{path}.metadata",
        reason="invalid hexadecimal bytes",
      )
  }
  let nullable = match object.get("nullable") {
    Some(True) => true
    Some(False) => false
    _ =>
      raise InvalidSchema(path="\{path}.nullable", reason="expected a boolean")
  }
  let unsigned = match wire_type {
    1 | 2 | 3 | 8 | 9 =>
      match object.get("unsigned") {
        Some(True) => Some(true)
        Some(False) => Some(false)
        _ =>
          raise InvalidSchema(
            path="\{path}.unsigned",
            reason="integer signedness is required",
          )
      }
    _ => {
      guard object.get("unsigned") is None else {
        raise InvalidSchema(
          path="\{path}.unsigned",
          reason="only integer columns accept unsigned",
        )
      }
      None
    }
  }
  { name, wire_type, metadata, nullable, unsigned, }
}
