// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// One table column: absent, SQL NULL, or a typed decoded value.
pub(all) enum RowCell {
  Absent
  Null
  Integer(IntegerValue)
  Floating(DecodedFloating)
  StringBytes(Bytes)
  BlobBytes(Bytes)
  JsonDocument(DecodedJson)
  Decimal(DecodedDecimal)
  Bit(DecodedBit)
  EnumSet(EnumSetValue)
  Temporal(DecodedTemporal)
} derive(Debug, Eq)

///|
pub extend RowCell with Eq::{equal, not_equal}

///|
pub extend RowCell with @debug.Debug::{to_repr}

///|
pub struct RowImage {
  columns : ReadOnlyArray[RowCell]
  bytes_read : Int32
} derive(Debug, Eq)

///|
pub extend RowImage with Eq::{equal, not_equal}

///|
pub extend RowImage with @debug.Debug::{to_repr}

///|
/// Decode one ordinary row image starting at its compact NULL bitmap.
/// columns_present has exactly ceil(table_columns/8) bytes, LSB first.
/// NULL bits enumerate only present columns, including NOT NULL columns.
/// integer_unsigned has one entry per table column; Some(bool) is required
/// only for present, non-NULL integer values. Other entries are ignored.
/// Ignore bitmap padding; reject NULL on a NOT NULL column. No JSON diffs,
/// event headers, transaction handling or automatic table-context clearing.
/// file_offset locates the NULL bitmap. The byte budget includes this bitmap.
/// Empty presence is allowed and consumes zero bytes; event loops must guard
/// against zero progress. Trailing input is left for the next row/image.
pub fn TableMap::decode_row_image(
  self : TableMap,
  data : BytesView,
  columns_present~ : BytesView,
  integer_unsigned~ : ReadOnlyArray[Bool?],
  file_offset~ : UInt64,
  max_bytes~ : Int32 = 16_777_216,
) -> RowImage raise DecodeError {
  guard max_bytes >= 0 && max_bytes <= 2_147_483_643 else {
    raise InvalidRowImageLimit(max_bytes~)
  }
  let count = self.columns.length()
  let bitmap_bytes = count / 8 + (if count % 8 == 0 { 0 } else { 1 })
  guard columns_present.length() == bitmap_bytes else {
    raise InvalidRowImage(
      file_offset~,
      reason="presence bitmap length does not match table columns",
    )
  }
  guard integer_unsigned.length() == count else {
    raise InvalidRowImage(
      file_offset~,
      reason="signedness array length does not match table columns",
    )
  }
  let span = data.length().min(max_bytes).reinterpret_as_uint().to_uint64()
  guard file_offset <= 0xffffffffffffffffUL - span else {
    raise InvalidRowImage(
      file_offset~,
      reason="physical offset range overflows UInt64",
    )
  }
  let mut included = 0
  for i in 0..<count {
    if row_bitmap_bit(columns_present, i) {
      included += 1
    }
  }
  let null_bytes = included / 8 + (if included % 8 == 0 { 0 } else { 1 })
  guard null_bytes <= max_bytes else {
    raise RowImageLimitExceeded(file_offset~, max_bytes~)
  }
  guard data.length() >= null_bytes else {
    raise TruncatedInput(
      file_offset~,
      expected=null_bytes,
      actual=data.length(),
    )
  }
  let columns = []
  let mut ordinal = 0
  let mut position = null_bytes
  for i in 0..<count {
    if !row_bitmap_bit(columns_present, i) {
      columns.push(Absent)
      continue
    }
    let is_null = row_bitmap_bit(data[:null_bytes], ordinal)
    let null_offset = file_offset +
      (ordinal / 8).reinterpret_as_uint().to_uint64()
    ordinal += 1
    let column = self.columns[i]
    if is_null {
      guard column.nullable else {
        raise UnexpectedRowNull(file_offset=null_offset, column_index=i)
      }
      columns.push(Null)
      continue
    }
    let remaining_budget = max_bytes - position
    let available = (data.length() - position).min(remaining_budget)
    let field_offset = file_offset + position.reinterpret_as_uint().to_uint64()
    let (cell, consumed) = decode_row_cell(
      column,
      data[position:position + available],
      integer_unsigned[i],
      file_offset=field_offset,
      column_index=i,
      max_blob_bytes=max_bytes,
    ) catch {
      TruncatedColumnValue(
        file_offset=error_offset,
        column_index=error_column,
        expected~,
        actual~
      ) => {
        if expected > remaining_budget && data.length() - position >= expected {
          raise RowImageLimitExceeded(file_offset~, max_bytes~)
        }
        raise TruncatedColumnValue(
          file_offset=error_offset,
          column_index=error_column,
          expected~,
          actual~,
        )
      }
      err => raise err
    }
    columns.push(cell)
    position += consumed
  }
  { columns: ReadOnlyArray::from_array(columns), bytes_read: position, }
}

///|
fn row_bitmap_bit(bitmap : BytesView, index : Int32) -> Bool {
  ((bitmap[index / 8].to_int() >> (index % 8)) & 1) != 0
}

///|
fn decode_row_cell(
  column : TableColumn,
  data : BytesView,
  unsigned : Bool?,
  file_offset~ : UInt64,
  column_index~ : Int32,
  max_blob_bytes~ : Int32,
) -> (RowCell, Int32) raise DecodeError {
  match column.wire_type {
    1..<=3 | 8 | 9 => {
      guard unsigned is Some(flag) else {
        raise MissingIntegerSignedness(file_offset~, column_index~)
      }
      let decoded = column.decode_integer(
        data,
        unsigned=flag,
        file_offset~,
        column_index~,
      )
      (Integer(decoded.value), decoded.bytes_read)
    }
    4 | 5 => {
      let decoded = column.decode_floating(data, file_offset~, column_index~)
      (Floating(decoded), decoded.bytes_read)
    }
    10 | 13 | 17..<=19 => {
      let decoded = column.decode_temporal(data, file_offset~, column_index~)
      (Temporal(decoded), decoded.bytes_read)
    }
    15 => {
      let decoded = column.decode_string(data, file_offset~, column_index~)
      (StringBytes(decoded.value), decoded.bytes_read)
    }
    16 => {
      let decoded = column.decode_bit(data, file_offset~, column_index~)
      (Bit(decoded), decoded.bytes_read)
    }
    245 => {
      let decoded = column.decode_json(
        data,
        file_offset~,
        column_index~,
        max_value_bytes=max_blob_bytes,
      )
      (JsonDocument(decoded), decoded.bytes_read)
    }
    246 => {
      let decoded = column.decode_decimal(data, file_offset~, column_index~)
      (Decimal(decoded), decoded.bytes_read)
    }
    252 => {
      let decoded = column.decode_blob(
        data,
        file_offset~,
        column_index~,
        max_value_bytes=max_blob_bytes,
      )
      (BlobBytes(decoded.value), decoded.bytes_read)
    }
    254 =>
      if column.metadata.length() == 2 &&
        (column.metadata[0] == 247 || column.metadata[0] == 248) {
        let decoded = column.decode_enum_set(data, file_offset~, column_index~)
        (EnumSet(decoded.value), decoded.bytes_read)
      } else {
        let decoded = column.decode_string(data, file_offset~, column_index~)
        (StringBytes(decoded.value), decoded.bytes_read)
      }
    wire_type =>
      raise UnsupportedRowColumn(file_offset~, column_index~, wire_type~)
  }
}
