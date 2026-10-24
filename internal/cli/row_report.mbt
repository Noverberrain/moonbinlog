// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
pub fn row_cell_json(
  cell : @moonbinlog.RowCell,
  index : Int32,
  name : String,
) -> Json {
  let fields : Map[String, Json] = {
    "index": @json.to_json(index),
    "name": Json::string(name),
  }
  fields["state"] = Json::string(
    match cell {
      Absent => "absent"
      Null => "null"
      _ => "value"
    },
  )
  match cell {
    Absent | Null => ()
    Integer(value) => {
      fields["type"] = "integer"
      match value {
        Signed(value) => {
          fields["unsigned"] = false
          fields["value"] = Json::string(value.to_string())
        }
        Unsigned(value) => {
          fields["unsigned"] = true
          fields["value"] = Json::string(value.to_string())
        }
      }
    }
    StringBytes(value) | BlobBytes(value) => {
      fields["type"] = Json::string(
        if cell is StringBytes(_) {
          "string_bytes"
        } else {
          "blob_bytes"
        },
      )
      fields["encoding"] = "hex"
      fields["value"] = Json::string(@hex.encode(value))
    }
    Decimal(value) => {
      fields["type"] = "decimal"
      fields["value"] = Json::string(value.value)
      fields["precision"] = @json.to_json(value.precision)
      fields["scale"] = @json.to_json(value.scale)
    }
    Floating(value) => {
      match value.value {
        Single(number) => {
          fields["type"] = "float32"
          fields["value"] = @json.to_json(number)
        }
        DoublePrecision(number) => {
          fields["type"] = "float64"
          fields["value"] = @json.to_json(number)
        }
      }
      fields["bits"] = Json::string(value.bits.to_string())
    }
    Bit(value) => {
      fields["type"] = "bit"
      fields["value"] = Json::string(value.value.to_string())
      fields["bit_length"] = @json.to_json(value.bit_length)
    }
    EnumSet(value) =>
      match value {
        EnumIndex(index) => {
          fields["type"] = "enum"
          fields["value"] = Json::string(index.to_string())
        }
        SetMask(mask) => {
          fields["type"] = "set"
          fields["value"] = Json::string(mask.to_string())
        }
      }
    Temporal(value) => {
      let (kind, components) = temporal_components(value.value)
      fields["type"] = Json::string(kind)
      fields["value"] = components
      fields["fractional_precision"] = @json.to_json(value.fractional_precision)
    }
  }
  Json::object(fields)
}

///|
fn temporal_components(value : @moonbinlog.TemporalValue) -> (String, Json) {
  match value {
    Year(year) => ("year", { "year": @json.to_json(year) })
    Date(year~, month~, day~) =>
      (
        "date",
        {
          "year": @json.to_json(year),
          "month": @json.to_json(month),
          "day": @json.to_json(day),
        },
      )
    DateTime(year~, month~, day~, hour~, minute~, second~, microsecond~) =>
      (
        "datetime",
        {
          "year": @json.to_json(year),
          "month": @json.to_json(month),
          "day": @json.to_json(day),
          "hour": @json.to_json(hour),
          "minute": @json.to_json(minute),
          "second": @json.to_json(second),
          "microsecond": @json.to_json(microsecond),
        },
      )
    Time(negative~, hour~, minute~, second~, microsecond~) =>
      (
        "time",
        {
          "negative": @json.to_json(negative),
          "hour": @json.to_json(hour),
          "minute": @json.to_json(minute),
          "second": @json.to_json(second),
          "microsecond": @json.to_json(microsecond),
        },
      )
    Timestamp(seconds~, microsecond~) =>
      (
        "timestamp",
        {
          "seconds": @json.to_json(seconds),
          "microsecond": @json.to_json(microsecond),
        },
      )
  }
}

///|
fn row_image_json(
  row : @moonbinlog.RowImage,
  schema : @moonbinlog.TableSchema,
) -> Json {
  let cells = []
  for i, cell in row.columns {
    cells.push(row_cell_json(cell, i, schema.columns[i].name))
  }
  Json::array(cells)
}

///|
pub fn row_change_line(
  event : @moonbinlog.RowsEvent,
  bound : @moonbinlog.BoundTableSchema,
  index : Int32,
) -> String raise RowScanError {
  let fields = row_change_fields(event, bound, index)
  fields["transaction_status"] = "unconfirmed"
  Json::object(fields).stringify()
}

///|
fn row_change_fields(
  event : @moonbinlog.RowsEvent,
  bound : @moonbinlog.BoundTableSchema,
  index : Int32,
) -> Map[String, Json] raise RowScanError {
  guard event.table == bound.table_map &&
    index >= 0 &&
    index < event.changes.length() else {
    raise InvalidOutput("row event/schema snapshot or change index differs")
  }
  let (operation, before, after) = match event.changes[index] {
    Insert(row) => ("insert", Json::null(), row_image_json(row, bound.schema))
    Delete(row) => ("delete", row_image_json(row, bound.schema), Json::null())
    Update(before~, after~) =>
      (
        "update",
        row_image_json(before, bound.schema),
        row_image_json(after, bound.schema),
      )
  }
  {
    "schema_version": @json.to_json(1),
    "kind": "row_change",
    "offset": Json::string(event.header.file_offset.to_string()),
    "type": @json.to_json(event.header.event_type.to_int()),
    "database": Json::string(event.table.database),
    "table": Json::string(event.table.table),
    "table_id": Json::string(event.table.table_id.to_string()),
    "change_index": @json.to_json(index),
    "operation": Json::string(operation),
    "before": before,
    "after": after,
  }
}
