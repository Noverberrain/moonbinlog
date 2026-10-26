// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// Exact, case-sensitive output selection. Never controls decoding or binding.
pub(all) struct TableFilter {
  database : String?
  table : String?
} derive(Debug, Eq)

///|
pub extend TableFilter with Eq::{equal, not_equal}

///|
pub extend TableFilter with @debug.Debug::{to_repr}

///|
pub fn TableFilter::all() -> TableFilter {
  { database: None, table: None, }
}

///|
pub fn TableFilter::is_active(self : TableFilter) -> Bool {
  self.database is Some(_) || self.table is Some(_)
}

///|
pub fn TableFilter::matches(
  self : TableFilter,
  database : String,
  table : String,
) -> Bool {
  (self.database is None || self.database == Some(database)) &&
  (self.table is None || self.table == Some(table))
}

///|
fn TableFilter::json(self : TableFilter, scope : String) -> Json {
  {
    "database": match self.database {
      Some(name) => Json::string(name)
      None => Json::null()
    },
    "table": match self.table {
      Some(name) => Json::string(name)
      None => Json::null()
    },
    "scope": Json::string(scope),
  }
}
