// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
pub struct Config {
  path : String
  summary_only : Bool
  json_output : Bool
  rows : Bool
  transactions : Bool
  include_rows : Bool
  schema_template : Bool
  filter : TableFilter
  schema_path : String?
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
    #|Usage: moonbinlog [--json] [--summary] [--schema-template | --rows | --transactions [--include-rows]] [--schema PATH] [--database NAME] [--table NAME] [--max-event-bytes N] [--max-file-bytes N] [--] FILE
    #|
    #|Inspect an unencrypted MySQL 8.0 binlog file; TSV output by default.
    #|  --json                Output JSON Lines: event objects, then one summary.
    #|  --summary             Show counts only; still validate the entire file.
    #|  --rows                Decode unconfirmed row changes as JSON Lines.
    #|  --transactions        Summarize explicit transactional RBR commits/rollbacks.
    #|  --include-rows        Include committed row values; requires --transactions.
    #|  --schema PATH         Schema v1 UTF-8 JSON file; required by either mode.
    #|  --schema-template     Emit a schema draft from TABLE_MAP after clean EOF.
    #|                        Review column_N names and replace integer unsigned:null.
    #|  --database NAME       Exact database name; requires --rows/--transactions.
    #|  --table NAME          Exact table name; combine with --database if needed.
    #|  --max-event-bytes N   Event limit, including header/checksum (default 16777216).
    #|  --max-file-bytes N    In-memory file limit (default 67108864, max 2147483647).
    #|  --                    Treat the remaining argument as a filename.
    #|  -h, --help            Show this help (use as the only argument).
    #|
    #|Exit codes: 0 success/help, 1 file/decoding/output failure, 2 invalid arguments.
    #|--rows and --transactions are mutually exclusive and require --schema.
    #|--rows does not confirm commits. --transactions requires transactional tables.
    #|Filters select row events or whole transactions; all input is still decoded.
    #|--schema-template accepts --json and byte limits; no rows/schema/summary/filters.
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
  let mut json_output = false
  let mut rows = false
  let mut transactions = false
  let mut include_rows = false
  let mut schema_template = false
  let mut schema_path = None
  let mut database = None
  let mut table = None
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
    } else if !positional && arg == "--json" {
      guard !json_output else { raise InvalidArguments("duplicate --json") }
      json_output = true
    } else if !positional && arg == "--rows" {
      guard !rows else { raise InvalidArguments("duplicate --rows") }
      rows = true
    } else if !positional && arg == "--transactions" {
      guard !transactions else {
        raise InvalidArguments("duplicate --transactions")
      }
      transactions = true
    } else if !positional && arg == "--schema-template" {
      guard !schema_template else {
        raise InvalidArguments("duplicate --schema-template")
      }
      schema_template = true
    } else if !positional && arg == "--include-rows" {
      guard !include_rows else {
        raise InvalidArguments("duplicate --include-rows")
      }
      include_rows = true
    } else if !positional && (arg == "--database" || arg == "--table") {
      guard cursor + 1 < argv.length() else {
        raise InvalidArguments("\{arg} requires a name")
      }
      cursor += 1
      let name = argv[cursor]
      guard name.length() > 0 &&
        name.length() <= 256 &&
        !name.contains("\u0000") else {
        raise InvalidArguments(
          "\{arg} requires 1..256 UTF-16 units without NUL",
        )
      }
      if arg == "--database" {
        guard database is None else {
          raise InvalidArguments("duplicate --database")
        }
        database = Some(name)
      } else {
        guard table is None else { raise InvalidArguments("duplicate --table") }
        table = Some(name)
      }
    } else if !positional && arg == "--schema" {
      guard schema_path is None else {
        raise InvalidArguments("duplicate --schema")
      }
      guard cursor + 1 < argv.length() && !argv[cursor + 1].is_empty() else {
        raise InvalidArguments("--schema requires a nonempty path")
      }
      cursor += 1
      schema_path = Some(argv[cursor])
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
  guard !(rows && transactions) else {
    raise InvalidArguments("--rows and --transactions are mutually exclusive")
  }
  guard !include_rows || transactions else {
    raise InvalidArguments("--include-rows requires --transactions")
  }
  guard (rows || transactions) == (schema_path is Some(_)) else {
    raise InvalidArguments(
      "--rows or --transactions requires --schema, and vice versa",
    )
  }
  let filter = TableFilter::{ database, table, }
  guard !schema_template ||
    !(rows ||
    transactions ||
    include_rows ||
    summary_only ||
    schema_path is Some(_) ||
    filter.is_active()) else {
    raise InvalidArguments(
      "--schema-template cannot combine with rows/transactions/schema/summary/filters",
    )
  }
  guard !filter.is_active() || rows || transactions else {
    raise InvalidArguments(
      "--database/--table requires --rows or --transactions",
    )
  }
  Inspect({
    path,
    summary_only,
    json_output: json_output || rows || transactions || schema_template,
    rows,
    transactions,
    include_rows,
    schema_template,
    filter,
    schema_path,
    max_event_bytes: event_limit.unwrap_or(16_777_216),
    max_file_bytes: file_limit.unwrap_or(67_108_864),
  })
}
