// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
async fn inspect_chain(config : @cli.Config) -> Unit {
  let chain = @cli.RotationChain::new(max_event_size=config.max_event_bytes)
  let total = @cli.Stats::new()
  let files = []
  let mut total_bytes = 0
  for index, path in config.paths {
    try {
      chain.begin_file(@utf8.encode(@path.Path(path).basename()))
      let remaining = config.max_total_bytes - total_bytes
      let data = read_input(
        path,
        if config.max_file_bytes < remaining {
          config.max_file_bytes
        } else {
          remaining
        },
      )
      total_bytes += data.length()
      let reader = @binlog.BinlogFileReader::new(
        data,
        max_event_size=config.max_event_bytes,
      )
      let stats = @cli.Stats::new()
      while reader.next() is Some(event) {
        let rotation = chain.feed(event)
        stats.record(event.header)
        total.record(event.header)
        if !config.summary_only {
          @stdio.stdout.write(
            @cli.chain_event_line(
              event,
              if config.decode_rotate {
                rotation
              } else {
                None
              },
              index,
              path,
            ) +
            "\n",
          )
        }
      }
      chain.end_file(data.length(), has_next=index + 1 < config.paths.length())
      files.push(stats.chain_file_json(index, path, data.length()))
    } catch {
      error =>
        raise ChainFileFailure(file_index=index, path~, reason="\{Repr(error)}")
    }
  }
  chain.finish()
  @stdio.stdout.write(total.chain_json_line(total_bytes, files) + "\n")
}
