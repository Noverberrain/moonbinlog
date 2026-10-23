// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
// Lexical preflight, not a JSON parser: bound nesting before core parsing.
// For VALID JSON each colon outside strings denotes one raw object member.
// Core JSON collapses duplicate keys, so compare this count with the parsed
// tree only AFTER parsing succeeds to reject duplicates (even escaped keys).
fn schema_member_tokens(text : StringView) -> Int32 raise SchemaError {
  let mut in_string = false
  let mut escaped = false
  let mut members = 0
  let mut depth = 0
  for ch in text {
    if in_string {
      if escaped {
        escaped = false
      } else if ch == '\\' {
        escaped = true
      } else if ch == '"' {
        in_string = false
      }
    } else if ch == '"' {
      in_string = true
    } else if ch == ':' {
      members += 1
    } else if ch == '{' || ch == '[' {
      depth += 1
      guard depth <= 16 else {
        raise SchemaLimitExceeded(path="$", reason="JSON nesting exceeds 16")
      }
    } else if ch == '}' || ch == ']' {
      depth -= 1
    }
  }
  members
}

///|
// Preflight already bounded nesting depth to 16; core parsing succeeded.
fn schema_member_count(value : Json) -> Int32 {
  match value {
    Object(object) => {
      let mut count = object.length()
      for _, child in object {
        count += schema_member_count(child)
      }
      count
    }
    Array(array) => {
      let mut count = 0
      for child in array {
        count += schema_member_count(child)
      }
      count
    }
    _ => 0
  }
}
