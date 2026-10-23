// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
pub(all) suberror SchemaError {
  InvalidSchema(path~ : String, reason~ : String)
  InvalidSchemaLimits(
    max_tables~ : Int32,
    max_columns~ : Int32,
    max_input_units~ : Int32
  )
  SchemaLimitExceeded(path~ : String, reason~ : String)
  MissingTableSchema(file_offset~ : UInt64, database~ : String, table~ : String)
  SchemaMismatch(
    file_offset~ : UInt64,
    database~ : String,
    table~ : String,
    column_index~ : Int32?,
    reason~ : String
  )
} derive(Debug, Eq)

///|
pub extend SchemaError with Eq::{equal, not_equal}

///|
pub extend SchemaError with @debug.Debug::{to_repr}

///|
/// A positional column label and a physical TABLE_MAP descriptor.
/// unsigned is required for integer wire types and absent for all others.
pub struct SchemaColumn {
  name : String
  wire_type : Byte
  metadata : Bytes
  nullable : Bool
  unsigned : Bool?
} derive(Debug, Eq)

///|
pub extend SchemaColumn with Eq::{equal, not_equal}

///|
pub extend SchemaColumn with @debug.Debug::{to_repr}

///|
pub struct TableSchema {
  database : String
  table : String
  columns : ReadOnlyArray[SchemaColumn]
} derive(Debug, Eq)

///|
pub extend TableSchema with Eq::{equal, not_equal}

///|
pub extend TableSchema with @debug.Debug::{to_repr}

///|
/// Immutable binding for this exact TABLE_MAP snapshot, not a table-id cache.
pub struct BoundTableSchema {
  table_map : TableMap
  schema : TableSchema
  integer_unsigned : ReadOnlyArray[Bool?]
} derive(Debug, Eq)

///|
pub extend BoundTableSchema with Eq::{equal, not_equal}

///|
pub extend BoundTableSchema with @debug.Debug::{to_repr}

///|
/// Immutable schema registry, keyed by the exact (database, table) pair.
pub struct SchemaConfig {
  priv tables : Map[(String, String), TableSchema]
}

///|
pub fn SchemaConfig::length(self : SchemaConfig) -> Int32 {
  self.tables.length()
}

///|
pub fn SchemaConfig::get(
  self : SchemaConfig,
  database : String,
  table : String,
) -> TableSchema? {
  self.tables.get((database, table))
}

///|
/// Compare count and positional type/raw metadata/nullable before returning
/// labels/signedness. These descriptors cannot prove names, signedness or
/// ordering between columns with otherwise identical physical descriptors.
/// Rebind every new TABLE_MAP; no schema evolution or DDL inference is performed.
pub fn SchemaConfig::bind(
  self : SchemaConfig,
  table_map : TableMap,
) -> BoundTableSchema raise SchemaError {
  let { header, database, table, columns, .. } = table_map
  guard self.get(database, table) is Some(schema) else {
    raise MissingTableSchema(file_offset=header.file_offset, database~, table~)
  }
  guard schema.columns.length() == columns.length() else {
    raise SchemaMismatch(
      file_offset=header.file_offset,
      database~,
      table~,
      column_index=None,
      reason="column count differs",
    )
  }
  let signs = []
  for i, column in columns {
    let expected = schema.columns[i]
    guard column.wire_type == expected.wire_type &&
      column.metadata == expected.metadata &&
      column.nullable == expected.nullable else {
      raise SchemaMismatch(
        file_offset=header.file_offset,
        database~,
        table~,
        column_index=Some(i),
        reason="wire type, metadata or nullable differs",
      )
    }
    signs.push(expected.unsigned)
  }
  { table_map, schema, integer_unsigned: ReadOnlyArray::from_array(signs), }
}
