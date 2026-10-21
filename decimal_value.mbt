// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// An exact decimal string retaining schema scale, without floating conversion.
pub struct DecodedDecimal {
  value : String
  precision : Int32
  scale : Int32
  bytes_read : Int32
} derive(Debug, Eq)

///|
pub extend DecodedDecimal with Eq::{equal, not_equal}

///|
pub extend DecodedDecimal with @debug.Debug::{to_repr}

///|
/// Decode a present, non-NULL NEWDECIMAL (246) for MySQL 8.0.
/// Metadata must contain precision (1..65) and scale (0..30, <= precision).
/// Return normalized integer digits and exactly `scale` fractional digits.
/// Negative zero is normalized to zero; no unsigned schema rule is inferred.
/// `file_offset` is this field's first byte; `column_index` is zero-based.
/// Trailing fields are not consumed. The caller handles presence/NULL bitmaps.
pub fn TableColumn::decode_decimal(
  self : TableColumn,
  data : BytesView,
  file_offset~ : UInt64,
  column_index~ : Int32,
) -> DecodedDecimal raise DecodeError {
  guard self.wire_type == 246 else {
    raise UnsupportedDecimalColumn(
      file_offset~,
      column_index~,
      wire_type=self.wire_type,
    )
  }
  guard self.metadata.length() == 2 else {
    raise InvalidDecimalMetadata(
      file_offset~,
      column_index~,
      reason="expected precision and scale bytes",
    )
  }
  let precision = self.metadata[0].to_int()
  let scale = self.metadata[1].to_int()
  guard precision >= 1 && precision <= 65 && scale <= 30 && scale <= precision else {
    raise InvalidDecimalMetadata(
      file_offset~,
      column_index~,
      reason="invalid MySQL 8.0 precision/scale",
    )
  }
  let integer_digits = precision - scale
  let bytes_read = (integer_digits / 9 + scale / 9) * 4 +
    decimal_group_width(integer_digits % 9) +
    decimal_group_width(scale % 9)
  guard data.length() >= bytes_read else {
    raise TruncatedColumnValue(
      file_offset~,
      column_index~,
      expected=bytes_read,
      actual=data.length(),
    )
  }
  let negative = (data[0].to_int() & 0x80) == 0
  let integer = StringBuilder()
  let fraction = StringBuilder()
  let mut position = 0
  let mut started = false
  let mut nonzero = false
  for part in 0..<2 {
    let mut remaining = if part == 0 { integer_digits } else { scale }
    while remaining > 0 {
      let digits = if part == 0 && remaining % 9 != 0 {
        remaining % 9
      } else if remaining >= 9 {
        9
      } else {
        remaining
      }
      let width = decimal_group_width(digits)
      let mut group = 0UL
      let mut bound = 1UL
      for _ in 0..<digits {
        bound *= 10
      }
      for i in 0..<width {
        let mut byte = data[position + i].to_int()
        if position + i == 0 {
          byte = byte ^ 0x80
        }
        if negative {
          byte = byte ^ 0xff
        }
        group = (group << 8) | byte.reinterpret_as_uint().to_uint64()
      }
      guard group < bound else {
        raise InvalidDecimalValue(
          file_offset~,
          column_index~,
          value_offset=position,
        )
      }
      nonzero = nonzero || group != 0
      let text = group.to_string()
      if part == 0 {
        if started || group != 0 {
          if started {
            for _ in 0..<(digits - text.length()) {
              integer.write_char('0')
            }
          }
          integer.write_string(text)
          started = true
        }
      } else {
        for _ in 0..<(digits - text.length()) {
          fraction.write_char('0')
        }
        fraction.write_string(text)
      }
      position += width
      remaining -= digits
    }
  }
  let integral = if started { integer.to_string() } else { "0" }
  let sign = if negative && nonzero { "-" } else { "" }
  let value = if scale == 0 {
    sign + integral
  } else {
    sign + integral + "." + fraction.to_string()
  }
  { value, precision, scale, bytes_read, }
}

///|
// 0..9 decimal digits fit in 0..4 bytes. Callers validate digit counts.
fn decimal_group_width(digits : Int32) -> Int32 {
  match digits {
    0 => 0
    1..<=2 => 1
    3..<=4 => 2
    5..<=6 => 3
    _ => 4
  }
}
