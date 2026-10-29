// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
suberror InputError {
  InvalidFile(String)
  ChainFileFailure(file_index~ : Int32, path~ : String, reason~ : String)
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
  if config.stream {
    inspect_stream(config)
    return
  }
  if config.chain {
    inspect_chain(config)
    return
  }
  if config.schema_template {
    let data = read_input(config.path, config.max_file_bytes)
    let reader = @binlog.BinlogFileReader::new(
      data,
      max_event_size=config.max_event_bytes,
    )
    let template = @cli.SchemaTemplate::new(
      max_event_size=config.max_event_bytes,
      use_table_metadata=config.use_table_metadata,
    )
    while reader.next() is Some(event) {
      template.feed(event)
    }
    @stdio.stdout.write(template.render() + "\n")
    return
  }
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
        (
          None,
          Some(
            @cli.TransactionScanner::new(
              schema,
              filter=config.filter,
              with_gtid=config.with_gtid,
            ),
          ),
        )
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
  let selected_transactions = @cli.TransactionStats::new()
  let mut row_events = 0
  let mut changes = 0
  let mut selected_row_events = 0
  let mut selected_changes = 0
  if !config.summary_only && !config.json_output {
    @stdio.stdout.write(@cli.event_columns() + "\n")
  }
  while reader.next() is Some(event) {
    // Decode even in --summary mode: suppressing output must not skip validation.
    let rotation = if config.decode_rotate && event.header.event_type == 4 {
      Some(
        @binlog.RotateEvent::parse(
          event.format,
          event.raw,
          file_offset=event.header.file_offset,
          max_event_size=config.max_event_bytes,
        ),
      )
    } else {
      None
    }
    let previous_gtids = if config.decode_previous_gtids &&
      event.header.event_type == 35 {
      Some(
        @binlog.PreviousGtidsEvent::parse(
          event.format,
          event.raw,
          file_offset=event.header.file_offset,
          max_event_size=config.max_event_bytes,
        ),
      )
    } else {
      None
    }
    let gtid = if config.decode_gtid &&
      (event.header.event_type == 33 || event.header.event_type == 34) {
      Some(
        @binlog.GtidEvent::parse(
          event.format,
          event.raw,
          file_offset=event.header.file_offset,
          max_event_size=config.max_event_bytes,
        ),
      )
    } else {
      None
    }
    stats.record(event.header)
    if transactions is Some(transactions) {
      if transactions.feed(event) is Some(outcome) {
        transaction_stats.record(outcome)
        if transactions.outcome_selected() {
          selected_transactions.record(outcome)
        }
        if !config.summary_only && transactions.outcome_selected() {
          let line = if config.with_gtid {
            guard transactions.gtid_outcome() is Some(value) else {
              raise InvalidFile("bound transaction metadata missing")
            }
            @cli.gtid_transaction_line(
              value,
              schema=if config.include_rows { schema } else { None },
            )
          } else if config.include_rows {
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
        if config.filter.matches(rows.table.database, rows.table.table) {
          selected_row_events += 1
          selected_changes += rows.changes.length()
          if !config.summary_only {
            for i in 0..<rows.changes.length() {
              @stdio.stdout.write(@cli.row_change_line(rows, bound, i) + "\n")
            }
          }
        }
      }
    } else if !config.summary_only {
      let line = if rotation is Some(rotation) {
        @cli.rotate_json_line(rotation, event.format.checksum_algorithm)
      } else if previous_gtids is Some(previous) {
        @cli.previous_gtids_json_line(previous, event.format.checksum_algorithm)
      } else if gtid is Some(gtid) {
        @cli.gtid_json_line(gtid, event.format.checksum_algorithm)
      } else if config.json_output {
        @cli.event_json_line(event.header, event.format.checksum_algorithm)
      } else {
        @cli.event_line(event.header, event.format.checksum_algorithm)
      }
      @stdio.stdout.write(line + "\n")
    }
  }
  if transactions is Some(transactions) {
    transactions.finish()
    let summary = if config.filter.is_active() {
      transaction_stats.filtered_json_line(
        stats,
        data.length(),
        config.filter,
        selected_transactions,
      )
    } else {
      transaction_stats.json_line(stats, data.length())
    }
    @stdio.stdout.write(summary + "\n")
  } else if scanner is Some(_) {
    let summary = if config.filter.is_active() {
      stats.filtered_row_json_line(
        data.length(),
        row_events,
        changes,
        config.filter,
        selected_row_events,
        selected_changes,
      )
    } else {
      stats.row_json_line(data.length(), row_events, changes)
    }
    @stdio.stdout.write(summary + "\n")
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
