// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
pub(all) suberror TemplateError {
  InvalidTemplate(String)
  ConflictingTable(
    database~ : String,
    table~ : String,
    first_offset~ : UInt64,
    file_offset~ : UInt64
  )
  TemplateLimit(String)
  TemplateAborted
} derive(Debug)

///|
pub extend TemplateError with @debug.Debug::{to_repr}

///|
/// A CLI draft, not inferred historical DDL. Feed framed/checksummed file events;
/// only TABLE_MAP bodies are decoded. Render only after the reader's clean EOF.
pub struct SchemaTemplate {
  priv tables : Array[@moonbinlog.TableMap]
  priv indices : Map[(String, String), Int32]
  priv documents : Array[Json]
  priv max_tables : Int32
  priv max_output_units : Int32
  priv max_event_size : UInt32
  priv mut output_units : Int32
  priv mut failed : Bool
}

///|
/// ```mbt check
/// test {
///   let draft = @cli.SchemaTemplate::new()
///   assert_true(draft.render().contains("\"tables\":[]"))
/// }
/// ```
pub fn SchemaTemplate::new(
  max_tables~ : Int32 = 1024,
  max_output_units~ : Int32 = 1048576,
  max_event_size~ : UInt32 = 16777216,
) -> SchemaTemplate raise TemplateError {
  guard max_tables > 0 && max_output_units >= 32 && max_event_size >= 19 else {
    raise InvalidTemplate("invalid template limits")
  }
  {
    tables: [],
    indices: {},
    documents: [],
    max_tables,
    max_output_units,
    max_event_size,
    output_units: 32,
    failed: false,
  }
}

///|
fn SchemaTemplate::abort(self : SchemaTemplate) -> Unit {
  self.failed = true
  self.tables.clear()
  self.indices.clear()
  self.documents.clear()
}

///|
pub fn SchemaTemplate::feed(
  self : SchemaTemplate,
  event : @moonbinlog.BinlogFileEvent,
) -> Unit raise {
  guard !self.failed else { raise TemplateAborted }
  errdefer self.abort()
  if event.header.event_type != 19 {
    return
  }
  let table = @moonbinlog.TableMap::parse(
    event.format,
    event.raw,
    file_offset=event.header.file_offset,
    max_event_size=self.max_event_size,
  )
  let key = (table.database, table.table)
  if self.indices.get(key) is Some(index) {
    let first = self.tables[index]
    guard first.columns == table.columns else {
      raise ConflictingTable(
        database=table.database,
        table=table.table,
        first_offset=first.header.file_offset,
        file_offset=table.header.file_offset,
      )
    }
    return
  }
  guard self.tables.length() < self.max_tables else {
    raise TemplateLimit("too many distinct tables")
  }
  let columns = []
  for i, column in table.columns {
    let fields : Map[String, Json] = {
      "name": Json::string("column_\{i + 1}"),
      "wire_type": @json.to_json(column.wire_type.to_int()),
      "metadata": Json::string(@hex.encode(column.metadata)),
      "nullable": @json.to_json(column.nullable),
    }
    match column.wire_type {
      1 | 2 | 3 | 8 | 9 => fields["unsigned"] = Json::null()
      _ => ()
    }
    columns.push(Json::object(fields))
  }
  let document : Json = {
    "database": Json::string(table.database),
    "table": Json::string(table.table),
    "columns": Json::array(columns),
  }
  let units = document.stringify().length()
  // Compact wrapper + one separator per table is a conservative upper bound.
  guard units < self.max_output_units - self.output_units else {
    raise TemplateLimit("template exceeds UTF-16 output budget")
  }
  self.output_units += units + 1
  self.indices[key] = self.tables.length()
  self.tables.push(table)
  self.documents.push(document)
}

///|
/// Integer unsigned:null deliberately fails SchemaConfig::parse until reviewed.
/// Column labels are placeholders even when optional TABLE_MAP metadata exists.
pub fn SchemaTemplate::render(
  self : SchemaTemplate,
) -> String raise TemplateError {
  guard !self.failed else { raise TemplateAborted }
  Json::object({ "schema_version": 1, "tables": Json::array(self.documents) }).stringify()
}
