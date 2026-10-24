// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
suberror InputError {
  InvalidFile(String)
} derive(Debug)

///|
async fn read_input(path : String, max_bytes : Int32) -> Bytes {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  guard file.kind() == Regular else {
    raise InvalidFile("input must be a regular file")
  }
  let size = file.size()
  guard size >= 0 && size <= max_bytes.to_int64() else {
    raise InvalidFile("file size \{size} exceeds limit \{max_bytes}: \{path}")
  }
  // Bound allocation first. Shrinking files raise EOF; detect growth after read.
  let data = file.read_exactly(size.to_int())
  guard file.read_some(max_len=1) is None else {
    raise InvalidFile("file grew while reading; use a closed binlog file")
  }
  data
}

///|
async fn inspect(config : @cli.Config) -> Unit {
  let schema = match config.schema_path {
    Some(path) => {
      let bytes = read_input(path, 4_194_304)
      Some(@binlog.SchemaConfig::parse(@utf8.decode(bytes, ignore_bom=true)))
    }
    None => None
  }
  let (scanner, transactions) = match schema {
    Some(schema) =>
      if config.transactions {
        (None, Some(@cli.TransactionScanner::new(schema)))
      } else {
        (
          Some(
            @cli.RowScanner::new(schema, max_event_size=config.max_event_bytes),
          ),
          None,
        )
      }
    None => (None, None)
  }
  let data = read_input(config.path, config.max_file_bytes)
  let reader = @binlog.BinlogFileReader::new(
    data,
    max_event_size=config.max_event_bytes,
  )
  let stats = @cli.Stats::new()
  let transaction_stats = @cli.TransactionStats::new()
  let mut row_events = 0
  let mut changes = 0
  if !config.summary_only && !config.json_output {
    @stdio.stdout.write(@cli.event_columns() + "\n")
  }
  while reader.next() is Some(event) {
    stats.record(event.header)
    if transactions is Some(transactions) {
      if transactions.feed(event) is Some(outcome) {
        transaction_stats.record(outcome)
        if !config.summary_only {
          let line = if config.include_rows {
            guard schema is Some(schema) else {
              raise InvalidFile("transaction row export requires schema")
            }
            @cli.transaction_rows_line(outcome, schema)
          } else {
            @cli.transaction_line(outcome)
          }
          @stdio.stdout.write(line + "\n")
        }
      }
    } else if scanner is Some(scanner) {
      if scanner.feed(event) is Some((rows, bound)) {
        row_events += 1
        changes += rows.changes.length()
        if !config.summary_only {
          for i in 0..<rows.changes.length() {
            @stdio.stdout.write(@cli.row_change_line(rows, bound, i) + "\n")
          }
        }
      }
    } else if !config.summary_only {
      let line = if config.json_output {
        @cli.event_json_line(event.header, event.format.checksum_algorithm)
      } else {
        @cli.event_line(event.header, event.format.checksum_algorithm)
      }
      @stdio.stdout.write(line + "\n")
    }
  }
  if transactions is Some(transactions) {
    transactions.finish()
    @stdio.stdout.write(
      transaction_stats.json_line(stats, data.length()) + "\n",
    )
  } else if scanner is Some(_) {
    @stdio.stdout.write(
      stats.row_json_line(data.length(), row_events, changes) + "\n",
    )
  } else if config.json_output {
    @stdio.stdout.write(stats.json_line(data.length()) + "\n")
  } else {
    for line in stats.lines(data.length()) {
      @stdio.stdout.write(line + "\n")
    }
  }
}

///|
async fn run(argv : ArrayView[String]) -> Int32 {
  let command = @cli.parse_args(argv) catch {
    InvalidArguments(message) => {
      @stdio.stderr.write("moonbinlog: \{message}\n\{@cli.usage()}\n")
      return 2
    }
  }
  match command {
    Help => @stdio.stdout.write(@cli.usage() + "\n")
    Inspect(config) => inspect(config)
  }
  0
}

///|
async fn main {
  let code = run(@env.args()[1:]) catch {
    error => {
      // Do not turn a reporting failure (e.g. closed stderr) into success.
      @stdio.stderr.write("moonbinlog: \{Repr(error)}\n") catch {
        _ => ()
      }
      1
    }
  }
  if code != 0 {
    @sys.exit(code)
  }
}
