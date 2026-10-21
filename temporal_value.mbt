// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// Calendar components retain MySQL zero dates; timestamps retain wire seconds.
/// TIME is a signed duration, not a time of day. No timezone is inferred.
pub(all) enum TemporalValue {
  Year(Int32)
  Date(year~ : Int32, month~ : Int32, day~ : Int32)
  DateTime(
    year~ : Int32,
    month~ : Int32,
    day~ : Int32,
    hour~ : Int32,
    minute~ : Int32,
    second~ : Int32,
    microsecond~ : Int32
  )
  Time(
    negative~ : Bool,
    hour~ : Int32,
    minute~ : Int32,
    second~ : Int32,
    microsecond~ : Int32
  )
  Timestamp(seconds~ : UInt32, microsecond~ : Int32)
} derive(Debug, Eq)

///|
pub extend TemporalValue with Eq::{equal, not_equal}

///|
pub extend TemporalValue with @debug.Debug::{to_repr}

///|
pub struct DecodedTemporal {
  value : TemporalValue
  fractional_precision : Int32
  bytes_read : Int32
} derive(Debug, Eq)

///|
pub extend DecodedTemporal with Eq::{equal, not_equal}

///|
pub extend DecodedTemporal with @debug.Debug::{to_repr}

///|
/// Decode present, non-NULL DATE, YEAR, TIMESTAMP2, DATETIME2 or TIME2.
/// Validate component ranges and fractional precision 0..6. Preserve zero and
/// partial-zero dates and SQL-mode-dependent dates such as February 31.
/// No calendar normalization, SQL-mode check or timestamp timezone conversion.
/// `file_offset` is the field's first byte; `column_index` is zero-based.
/// The caller handles row presence/NULL bitmaps; trailing bytes are untouched.
pub fn TableColumn::decode_temporal(
  self : TableColumn,
  data : BytesView,
  file_offset~ : UInt64,
  column_index~ : Int32,
) -> DecodedTemporal raise DecodeError {
  let base = match self.wire_type {
    10 | 19 => 3
    13 => 1
    17 => 4
    18 => 5
    wire_type =>
      raise UnsupportedTemporalColumn(file_offset~, column_index~, wire_type~)
  }
  let modern = self.wire_type >= 17
  guard self.metadata.length() == (if modern { 1 } else { 0 }) else {
    raise InvalidTemporalMetadata(
      file_offset~,
      column_index~,
      reason="unexpected metadata length",
    )
  }
  let fsp = if modern { self.metadata[0].to_int() } else { 0 }
  guard fsp <= 6 else {
    raise InvalidTemporalMetadata(
      file_offset~,
      column_index~,
      reason="fractional precision must be 0..6",
    )
  }
  let fraction_width = (fsp + 1) / 2
  let bytes_read = base + fraction_width
  guard data.length() >= bytes_read else {
    raise TruncatedColumnValue(
      file_offset~,
      column_index~,
      expected=bytes_read,
      actual=data.length(),
    )
  }
  let value = match self.wire_type {
    13 => {
      let year = data[0].to_int()
      Year(if year == 0 { 0 } else { year + 1900 })
    }
    10 => {
      let raw = data[0].to_int() |
        (data[1].to_int() << 8) |
        (data[2].to_int() << 16)
      let year = raw >> 9
      let month = (raw >> 5) & 15
      let day = raw & 31
      temporal_check(
        year <= 9999 && month <= 12,
        file_offset~,
        column_index~,
        reason="date component out of range",
      )
      Date(year~, month~, day~)
    }
    18 => {
      let raw = temporal_uint_be(data[:5])
      temporal_check(
        raw >= 0x8000000000UL,
        file_offset~,
        column_index~,
        reason="negative DATETIME2 encoding",
      )
      let packed = raw - 0x8000000000UL
      let ym = (packed >> 22).to_int()
      let year = ym / 13
      let month = ym % 13
      let day = ((packed >> 17) & 31).to_int()
      let hour = ((packed >> 12) & 31).to_int()
      let minute = ((packed >> 6) & 63).to_int()
      let second = (packed & 63).to_int()
      temporal_check(
        year <= 9999 && hour <= 23 && minute <= 59 && second <= 59,
        file_offset~,
        column_index~,
        reason="datetime component out of range",
      )
      let microsecond = temporal_fraction(
        temporal_uint_be(data[5:bytes_read]).to_int(),
        fraction_width,
        fsp,
        file_offset~,
        column_index~,
      )
      DateTime(year~, month~, day~, hour~, minute~, second~, microsecond~)
    }
    17 => {
      let seconds = temporal_uint_be(data[:4]).to_uint()
      let microsecond = temporal_fraction(
        temporal_uint_be(data[4:bytes_read]).to_int(),
        fraction_width,
        fsp,
        file_offset~,
        column_index~,
      )
      Timestamp(seconds~, microsecond~)
    }
    _ => {
      // One biased fixed-point integer also handles negative subsecond values.
      let offset = 0x800000UL << (8 * fraction_width)
      let packed = temporal_uint_be(data[:bytes_read]).reinterpret_as_int64() -
        offset.reinterpret_as_int64()
      let negative = packed < 0
      let magnitude = if negative { -packed } else { packed }
      let integer = (magnitude >> (8 * fraction_width)).to_int()
      let raw_fraction = (magnitude & ((1L << (8 * fraction_width)) - 1)).to_int()
      let microsecond = temporal_fraction(
        raw_fraction,
        fraction_width,
        fsp,
        file_offset~,
        column_index~,
      )
      let hour = integer >> 12
      let minute = (integer >> 6) & 63
      let second = integer & 63
      temporal_check(
        hour <= 838 &&
        minute <= 59 &&
        second <= 59 &&
        !(hour == 838 && minute == 59 && second == 59 && microsecond != 0),
        file_offset~,
        column_index~,
        reason="time duration out of range",
      )
      Time(negative~, hour~, minute~, second~, microsecond~)
    }
  }
  { value, fractional_precision: fsp, bytes_read, }
}

///|
fn temporal_uint_be(data : BytesView) -> UInt64 {
  let mut value = 0UL
  for byte in data {
    value = (value << 8) | byte.to_uint().to_uint64()
  }
  value
}

///|
fn temporal_check(
  valid : Bool,
  file_offset~ : UInt64,
  column_index~ : Int32,
  reason~ : String,
) -> Unit raise DecodeError {
  guard valid else {
    raise InvalidTemporalValue(file_offset~, column_index~, reason~)
  }
}

///|
fn temporal_fraction(
  raw : Int32,
  width : Int32,
  fsp : Int32,
  file_offset~ : UInt64,
  column_index~ : Int32,
) -> Int32 raise DecodeError {
  let microsecond = raw *
    (if width == 1 { 10000 } else if width == 2 { 100 } else { 1 })
  let mut resolution = 1
  for _ in 0..<(6 - fsp) {
    resolution *= 10
  }
  temporal_check(
    microsecond <= 999999 && microsecond % resolution == 0,
    file_offset~,
    column_index~,
    reason="invalid fractional seconds or nonzero precision padding",
  )
  microsecond
}
