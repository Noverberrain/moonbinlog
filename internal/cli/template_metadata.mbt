// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
priv struct TemplateHints {
  names : ReadOnlyArray[String]?
  signs : ReadOnlyArray[Bool?]?
} derive(Eq)

///|
fn metadata_error(
  table : @moonbinlog.TableMap,
  field_type : Byte,
  reason : String,
) -> TemplateError {
  InvalidTemplateMetadata(
    file_offset=table.header.file_offset,
    field_type~,
    reason~,
  )
}

///|
// MySQL's numeric bitmap also counts legacy DECIMAL, YEAR, FLOAT and DOUBLE.
fn template_numeric(kind : Byte) -> Bool {
  match kind {
    0..<=5 | 8 | 9 | 13 | 246 => true
    _ => false
  }
}

///|
fn template_names(
  data : BytesView,
  table : @moonbinlog.TableMap,
) -> ReadOnlyArray[String] raise TemplateError {
  let names = []
  let seen : Map[String, Bool] = Map([])
  let mut pos = 0
  for _ in table.columns {
    guard pos < data.length() else {
      raise metadata_error(table, 4, "missing column name")
    }
    let marker = data[pos].to_int()
    pos += 1
    let length = if marker <= 250 {
      marker.to_uint64()
    } else {
      let width = match marker {
        252 => 2
        253 => 3
        254 => 8
        _ => raise metadata_error(table, 4, "invalid packed name length")
      }
      guard width <= data.length() - pos else {
        raise metadata_error(table, 4, "truncated name length")
      }
      let mut length = 0UL
      for i in 0..<width {
        length = length | (data[pos + i].to_uint().to_uint64() << (8 * i))
      }
      pos += width
      length
    }
    guard length > 0 &&
      length <= (data.length() - pos).reinterpret_as_uint().to_uint64() else {
      raise metadata_error(table, 4, "empty or truncated name")
    }
    // A valid schema name of at most 256 UTF-16 units needs at most 1024 UTF-8 bytes.
    guard length <= 1024 else {
      raise metadata_error(table, 4, "column name too long")
    }
    let name = @utf8.decode(data[pos:pos + length.to_int()], ignore_bom=false) catch {
      _ => raise metadata_error(table, 4, "column name is not UTF-8")
    }
    guard name.length() <= 256 &&
      !name.contains("\u0000") &&
      !seen.contains(name) else {
      raise metadata_error(table, 4, "invalid or duplicate schema column name")
    }
    pos += length.to_int()
    seen[name] = true
    names.push(name)
  }
  guard pos == data.length() else {
    raise metadata_error(table, 4, "extra column names or trailing bytes")
  }
  ReadOnlyArray::from_array(names)
}

///|
fn template_signs(
  data : BytesView,
  table : @moonbinlog.TableMap,
) -> ReadOnlyArray[Bool?] raise TemplateError {
  let mut count = 0
  for column in table.columns {
    if template_numeric(column.wire_type) {
      count += 1
    }
  }
  guard data.length() == (count + 7) / 8 else {
    raise metadata_error(table, 1, "signedness bitmap length mismatch")
  }
  let signs = []
  let mut numeric_index = 0
  for column in table.columns {
    let sign = if template_numeric(column.wire_type) {
      let flag = (
          data[numeric_index / 8].to_uint() & (0x80U >> (numeric_index % 8))
        ) !=
        0
      numeric_index += 1
      match column.wire_type {
        1 | 2 | 3 | 8 | 9 => Some(flag)
        _ => None
      }
    } else {
      None
    }
    signs.push(sign)
  }
  ReadOnlyArray::from_array(signs)
}

///|
fn template_hints(
  table : @moonbinlog.TableMap,
) -> TemplateHints raise TemplateError {
  let mut names = None
  let mut signs = None
  for field in table.optional_metadata {
    match field.field_type {
      1 => {
        guard signs is None else {
          raise metadata_error(table, 1, "duplicate SIGNEDNESS field")
        }
        signs = Some(template_signs(field.value, table))
      }
      4 => {
        guard names is None else {
          raise metadata_error(table, 4, "duplicate COLUMN_NAME field")
        }
        names = Some(template_names(field.value, table))
      }
      _ => ()
    }
  }
  { names, signs, }
}

///|
fn[T : Eq] merge_template_hint(
  before : T?,
  after : T?,
  first : @moonbinlog.TableMap,
  table : @moonbinlog.TableMap,
) -> T? raise TemplateError {
  match (before, after) {
    (Some(old), Some(new)) if old != new =>
      raise ConflictingTable(
        database=table.database,
        table=table.table,
        first_offset=first.header.file_offset,
        file_offset=table.header.file_offset,
      )
    (Some(_), _) => before
    (None, _) => after
  }
}
