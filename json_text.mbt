// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// Compact JSON text with exact decimal integer spelling. JSON consumers must
/// still use an integer-preserving parser. Parsed documents are depth-bounded.
///
/// ```mbt check
/// test {
///   let value = @moonbinlog.BinaryJsonValue::Integer(
///     Unsigned(18446744073709551615UL),
///   )
///   assert_eq(value.to_json_text(), "18446744073709551615")
/// }
/// ```
pub fn BinaryJsonValue::to_json_text(self : BinaryJsonValue) -> String {
  let out = StringBuilder()
  self.write_text(out)
  out.to_string()
}

///|
fn BinaryJsonValue::write_text(
  self : BinaryJsonValue,
  out : StringBuilder,
) -> Unit {
  match self {
    Null => out.write_string("null")
    Boolean(flag) => out.write_string(if flag { "true" } else { "false" })
    Integer(Signed(number)) => out.write_string(number.to_string())
    Integer(Unsigned(number)) => out.write_string(number.to_string())
    DoubleNumber(value~, bits~) =>
      out.write_string(
        if bits == 0x8000000000000000UL {
          "-0.0"
        } else {
          Json::number(value).stringify()
        },
      )
    Text(text) => out.write_string(Json::string(text).stringify())
    Array(elements) => {
      out.write_char('[')
      for i, element in elements {
        if i > 0 {
          out.write_char(',')
        }
        element.write_text(out)
      }
      out.write_char(']')
    }
    Object(members) => {
      out.write_char('{')
      for i, (key, value) in members {
        if i > 0 {
          out.write_char(',')
        }
        out.write_string(Json::string(key).stringify())
        out.write_char(':')
        value.write_text(out)
      }
      out.write_char('}')
    }
  }
}
