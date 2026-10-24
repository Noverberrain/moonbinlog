// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// One record per completed explicit span; no row values or pending data.
pub fn transaction_line(outcome : @moonbinlog.TransactionOutcome) -> String {
  Json::object(transaction_fields(outcome)).stringify()
}

///|
fn transaction_fields(
  outcome : @moonbinlog.TransactionOutcome,
) -> Map[String, Json] {
  let fields : Map[String, Json] = {
    "schema_version": 1,
    "kind": "transaction",
  }
  match outcome {
    Committed(transaction) => {
      fields["status"] = "committed"
      fields["start_offset"] = Json::string(
        transaction.start_offset.to_string(),
      )
      fields["end_offset"] = Json::string(transaction.end_offset.to_string())
      fields["xid"] = match transaction.xid {
        Some(xid) => Json::string(xid.to_string())
        None => Json::null()
      }
      fields["events"] = @json.to_json(transaction.event_count)
      fields["row_events"] = @json.to_json(transaction.events.length())
      fields["changes"] = @json.to_json(transaction.change_count)
      fields["event_bytes"] = Json::string(transaction.wire_bytes.to_string())
      let counts : Map[(String, String), (Int32, Int32)] = Map([])
      let order = []
      for event in transaction.events {
        let key = (event.table.database, event.table.table)
        if !counts.contains(key) {
          order.push(key)
        }
        let (events, changes) = counts.get(key).unwrap_or((0, 0))
        counts[key] = (events + 1, changes + event.changes.length())
      }
      let tables = []
      for (database, table) in order {
        let (events, changes) = counts[(database, table)]
        tables.push(
          Json::object({
            "database": Json::string(database),
            "table": Json::string(table),
            "row_events": @json.to_json(events),
            "changes": @json.to_json(changes),
          }),
        )
      }
      fields["tables"] = Json::array(tables)
    }
    RolledBack(start_offset~, end_offset~, discarded_changes~) => {
      fields["status"] = "rolled_back"
      fields["start_offset"] = Json::string(start_offset.to_string())
      fields["end_offset"] = Json::string(end_offset.to_string())
      fields["discarded_changes"] = @json.to_json(discarded_changes)
    }
  }
  fields
}

///|
/// Render the entire completed transaction before returning any text. Bind each
/// saved TABLE_MAP snapshot, never a live table_id cache from a later statement.
pub fn transaction_rows_line(
  outcome : @moonbinlog.TransactionOutcome,
  schema : @moonbinlog.SchemaConfig,
) -> String raise {
  let fields = transaction_fields(outcome)
  if outcome is Committed(transaction) {
    let changes = []
    for event in transaction.events {
      let bound = schema.bind(event.table)
      for i in 0..<event.changes.length() {
        let row = row_change_fields(event, bound, i)
        row["transaction_status"] = "committed"
        changes.push(Json::object(row))
      }
    }
    fields["row_changes"] = Json::array(changes)
  }
  Json::object(fields).stringify()
}

///|
pub struct TransactionStats {
  priv mut committed : Int32
  priv mut rolled_back : Int32
  priv mut row_events : Int32
  priv mut changes : Int32
  priv mut discarded_changes : Int32
}

///|
pub fn TransactionStats::new() -> TransactionStats {
  {
    committed: 0,
    rolled_back: 0,
    row_events: 0,
    changes: 0,
    discarded_changes: 0,
  }
}

///|
pub fn TransactionStats::record(
  self : TransactionStats,
  outcome : @moonbinlog.TransactionOutcome,
) -> Unit {
  match outcome {
    Committed(transaction) => {
      self.committed += 1
      self.row_events += transaction.events.length()
      self.changes += transaction.change_count
    }
    RolledBack(discarded_changes~, ..) => {
      self.rolled_back += 1
      self.discarded_changes += discarded_changes
    }
  }
}

///|
pub fn TransactionStats::json_line(
  self : TransactionStats,
  stats : Stats,
  file_bytes : Int32,
) -> String {
  let fields = stats.summary_fields(file_bytes)
  fields["kind"] = "transaction_summary"
  fields["committed_transactions"] = @json.to_json(self.committed)
  fields["rolled_back_transactions"] = @json.to_json(self.rolled_back)
  fields["committed_row_events"] = @json.to_json(self.row_events)
  fields["committed_changes"] = @json.to_json(self.changes)
  fields["discarded_changes"] = @json.to_json(self.discarded_changes)
  Json::object(fields).stringify()
}
