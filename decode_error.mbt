// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// Errors from file signature and v4 common event-header decoding.
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
} derive(Debug, Eq)

///|
pub extend DecodeError with Eq::{equal, not_equal}

///|
pub extend DecodeError with @debug.Debug::{to_repr}
