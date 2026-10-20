// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// Errors from file signatures, event framing, format descriptions and checksums.
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
} derive(Debug, Eq)

///|
pub extend DecodeError with Eq::{equal, not_equal}

///|
pub extend DecodeError with @debug.Debug::{to_repr}
