// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
pub struct Config {
  path : String
  summary_only : Bool
  max_event_bytes : UInt32
  max_file_bytes : Int32
} derive(Debug, Eq)

///|
pub extend Config with Eq::{equal, not_equal}

///|
pub extend Config with @debug.Debug::{to_repr}

///|
pub(all) enum Command {
  Help
  Inspect(Config)
} derive(Debug, Eq)

///|
pub extend Command with Eq::{equal, not_equal}

///|
pub extend Command with @debug.Debug::{to_repr}

///|
pub(all) suberror ArgumentError {
  InvalidArguments(String)
} derive(Debug, Eq)

///|
pub extend ArgumentError with Eq::{equal, not_equal}

///|
pub extend ArgumentError with @debug.Debug::{to_repr}

///|
pub fn usage() -> String {
  let text =
    #|Usage: moonbinlog [--summary] [--max-event-bytes N] [--max-file-bytes N] [--] FILE
    #|
    #|Inspect an unencrypted MySQL 8.0 binlog file; output TSV events and counts.
    #|  --summary             Show counts only; still validate the entire file.
    #|  --max-event-bytes N   Event limit, including header/checksum (default 16777216).
    #|  --max-file-bytes N    In-memory file limit (default 67108864, max 2147483647).
    #|  --                    Treat the remaining argument as a filename.
    #|  -h, --help            Show this help (use as the only argument).
    #|
    #|Exit codes: 0 success/help, 1 file/decoding/output failure, 2 invalid arguments.
    #|Only event framing/checksums are checked; no row or transaction decoding.
  text
}

///|
fn parse_limit(text : String, option : String) -> UInt32 raise ArgumentError {
  guard !text.is_empty() else {
    raise InvalidArguments("missing value for \{option}")
  }
  for ch in text {
    guard ch >= '0' && ch <= '9' else {
      raise InvalidArguments("\{option} requires unsigned decimal bytes")
    }
  }
  @string.parse_uint(text, base=10) catch {
    _ => raise InvalidArguments("\{option} exceeds UInt32")
  }
}

///|
/// argv excludes the program name. Each option may occur at most once.
pub fn parse_args(argv : ArrayView[String]) -> Command raise ArgumentError {
  if argv is ["--help"] || argv is ["-h"] {
    return Help
  }
  let mut path = None
  let mut summary_only = false
  let mut event_limit = None
  let mut file_limit = None
  let mut positional = false
  let mut cursor = 0
  while cursor < argv.length() {
    let arg = argv[cursor]
    if !positional && arg == "--" {
      positional = true
    } else if !positional && arg == "--summary" {
      guard !summary_only else { raise InvalidArguments("duplicate --summary") }
      summary_only = true
    } else if !positional &&
      (arg == "--max-event-bytes" || arg == "--max-file-bytes") {
      guard cursor + 1 < argv.length() else {
        raise InvalidArguments("missing value for \{arg}")
      }
      cursor += 1
      let value = parse_limit(argv[cursor], arg)
      if arg == "--max-event-bytes" {
        guard event_limit is None else {
          raise InvalidArguments("duplicate \{arg}")
        }
        guard value >= 19 else {
          raise InvalidArguments("\{arg} must be at least 19")
        }
        event_limit = Some(value)
      } else {
        guard file_limit is None else {
          raise InvalidArguments("duplicate \{arg}")
        }
        guard value > 0 && value <= 2147483647 else {
          raise InvalidArguments("\{arg} must be between 1 and 2147483647")
        }
        file_limit = Some(value.reinterpret_as_int())
      }
    } else {
      guard positional || !arg.has_prefix("-") else {
        raise InvalidArguments("unknown or misplaced option: \{arg}")
      }
      guard path is None && !arg.is_empty() else {
        raise InvalidArguments("exactly one nonempty filename is required")
      }
      path = Some(arg)
    }
    cursor += 1
  }
  guard path is Some(path) else {
    raise InvalidArguments("a filename is required")
  }
  Inspect({
    path,
    summary_only,
    max_event_bytes: event_limit.unwrap_or(16_777_216),
    max_file_bytes: file_limit.unwrap_or(67_108_864),
  })
}
