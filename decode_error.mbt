// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// Errors from file signatures, events, table maps and column values.
/// Offsets are physical file positions, not the header's next-position field.
pub(all) suberror DecodeError {
  InvalidMagic(actual~ : Bytes)
  TruncatedInput(file_offset~ : UInt64, expected~ : Int32, actual~ : Int32)
  InvalidEventLength(file_offset~ : UInt64, event_size~ : UInt32)
  EventTooLarge(
    file_offset~ : UInt64,
    event_size~ : UInt32,
    max_event_size~ : UInt32
  )
  InvalidEventLimit(max_event_size~ : UInt32)
  TruncatedEvent(file_offset~ : UInt64, expected~ : UInt32, actual~ : UInt32)
  UnexpectedEventType(file_offset~ : UInt64, expected~ : Byte, actual~ : Byte)
  UnsupportedBinlogVersion(file_offset~ : UInt64, version~ : UInt16)
  UnsupportedServerVersion(file_offset~ : UInt64, server_version~ : String)
  UnsupportedHeaderLength(file_offset~ : UInt64, length~ : Byte)
  InvalidFormatDescription(file_offset~ : UInt64, reason~ : String)
  UnsupportedChecksumAlgorithm(file_offset~ : UInt64, algorithm~ : Byte)
  ChecksumMismatch(file_offset~ : UInt64, expected~ : UInt32, actual~ : UInt32)
  FormatContextResetRequired(file_offset~ : UInt64)
  InvalidTableMap(file_offset~ : UInt64, body_offset~ : Int32, reason~ : String)
  UnsupportedColumnType(
    file_offset~ : UInt64,
    column_index~ : Int32,
    wire_type~ : Byte
  )
  InvalidColumnLimit(max_columns~ : Int32)
  ColumnLimitExceeded(
    file_offset~ : UInt64,
    count~ : UInt64,
    max_columns~ : Int32
  )
  InvalidTableContextLimit(max_tables~ : Int32, max_bytes~ : UInt64)
  TableContextLimitExceeded(file_offset~ : UInt64, reason~ : String)
  UnsupportedIntegerColumn(
    file_offset~ : UInt64,
    column_index~ : Int32,
    wire_type~ : Byte
  )
  TruncatedColumnValue(
    file_offset~ : UInt64,
    column_index~ : Int32,
    expected~ : Int32,
    actual~ : Int32
  )
  UnsupportedStringColumn(
    file_offset~ : UInt64,
    column_index~ : Int32,
    wire_type~ : Byte
  )
  InvalidStringMetadata(
    file_offset~ : UInt64,
    column_index~ : Int32,
    reason~ : String
  )
  StringLengthExceeded(
    file_offset~ : UInt64,
    column_index~ : Int32,
    length~ : Int32,
    max_length~ : Int32
  )
  UnsupportedBlobColumn(
    file_offset~ : UInt64,
    column_index~ : Int32,
    wire_type~ : Byte
  )
  InvalidBlobMetadata(
    file_offset~ : UInt64,
    column_index~ : Int32,
    reason~ : String
  )
  InvalidBlobLimit(max_value_bytes~ : Int32)
  BlobTooLarge(
    file_offset~ : UInt64,
    column_index~ : Int32,
    length~ : UInt64,
    max_value_bytes~ : Int32
  )
  UnsupportedDecimalColumn(
    file_offset~ : UInt64,
    column_index~ : Int32,
    wire_type~ : Byte
  )
  InvalidDecimalMetadata(
    file_offset~ : UInt64,
    column_index~ : Int32,
    reason~ : String
  )
  InvalidDecimalValue(
    file_offset~ : UInt64,
    column_index~ : Int32,
    value_offset~ : Int32
  )
  UnsupportedTemporalColumn(
    file_offset~ : UInt64,
    column_index~ : Int32,
    wire_type~ : Byte
  )
  InvalidTemporalMetadata(
    file_offset~ : UInt64,
    column_index~ : Int32,
    reason~ : String
  )
  InvalidTemporalValue(
    file_offset~ : UInt64,
    column_index~ : Int32,
    reason~ : String
  )
  UnsupportedFloatingColumn(
    file_offset~ : UInt64,
    column_index~ : Int32,
    wire_type~ : Byte
  )
  InvalidFloatingMetadata(
    file_offset~ : UInt64,
    column_index~ : Int32,
    expected_width~ : Int32
  )
  NonFiniteFloatingValue(
    file_offset~ : UInt64,
    column_index~ : Int32,
    wire_type~ : Byte,
    bits~ : UInt64
  )
  UnsupportedBitColumn(
    file_offset~ : UInt64,
    column_index~ : Int32,
    wire_type~ : Byte
  )
  InvalidBitMetadata(
    file_offset~ : UInt64,
    column_index~ : Int32,
    reason~ : String
  )
  UnsupportedEnumSetColumn(
    file_offset~ : UInt64,
    column_index~ : Int32,
    wire_type~ : Byte
  )
  InvalidEnumSetMetadata(
    file_offset~ : UInt64,
    column_index~ : Int32,
    reason~ : String
  )
  InvalidRowImage(file_offset~ : UInt64, reason~ : String)
  InvalidRowImageLimit(max_bytes~ : Int32)
  RowImageLimitExceeded(file_offset~ : UInt64, max_bytes~ : Int32)
  UnexpectedRowNull(file_offset~ : UInt64, column_index~ : Int32)
  MissingIntegerSignedness(file_offset~ : UInt64, column_index~ : Int32)
  UnsupportedRowColumn(
    file_offset~ : UInt64,
    column_index~ : Int32,
    wire_type~ : Byte
  )
} derive(Debug, Eq)

///|
pub extend DecodeError with Eq::{equal, not_equal}

///|
pub extend DecodeError with @debug.Debug::{to_repr}
