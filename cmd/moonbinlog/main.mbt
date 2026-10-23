// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
suberror InputError {
  InvalidFile(String)
} derive(Debug)

///|
async fn inspect(config : @cli.Config) -> Unit {
  let file = @fs.open(config.path, mode=ReadOnly)
  defer file.close()
  guard file.kind() == Regular else {
    raise InvalidFile("input must be a regular file")
  }
  let size = file.size()
  guard size >= 0 && size <= config.max_file_bytes.to_int64() else {
    raise InvalidFile(
      "file size \{size} exceeds limit \{config.max_file_bytes}",
    )
  }
  // Bound allocation first. Shrinking files raise EOF; detect growth after read.
  let data = file.read_exactly(size.to_int())
  guard file.read_some(max_len=1) is None else {
    raise InvalidFile("file grew while reading; use a closed binlog file")
  }
  let reader = @binlog.BinlogFileReader::new(
    data,
    max_event_size=config.max_event_bytes,
  )
  let stats = @cli.Stats::new()
  if !config.summary_only {
    @stdio.stdout.write(@cli.event_columns() + "\n")
  }
  while reader.next() is Some(event) {
    stats.record(event.header)
    if !config.summary_only {
      @stdio.stdout.write(
        @cli.event_line(event.header, event.format.checksum_algorithm) + "\n",
      )
    }
  }
  for line in stats.lines(data.length()) {
    @stdio.stdout.write(line + "\n")
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
