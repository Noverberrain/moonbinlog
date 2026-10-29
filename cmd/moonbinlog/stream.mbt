// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
// Read a bounded, closed regular file event by event. The snapshot bounds every
// allocation; reading past the snapshot detects growth before success output.
async fn inspect_stream(config : @cli.Config) -> Unit {
  let file = @fs.open(config.path, mode=ReadOnly)
  defer file.close()
  guard file.kind() == Regular else {
    raise InvalidFile("input must be a regular file")
  }
  let size = file.size()
  guard size >= 0 && size <= config.max_file_bytes.to_int64() else {
    raise InvalidFile(
      "file size \{size} exceeds limit \{config.max_file_bytes}: \{config.path}",
    )
  }
  let length = size.to_int()
  let signature = if length == 0 {
    b""
  } else {
    file.read_exactly(if length < 4 { length } else { 4 })
  }
  let reader = @binlog.BinlogEventStream::new(
    signature,
    max_event_size=config.max_event_bytes,
  )
  let stats = @cli.Stats::new()
  if !config.summary_only && !config.json_output {
    @stdio.stdout.write(@cli.event_columns() + "\n")
  }
  let mut position = 4
  while position < length {
    let remaining = length - position
    let head = file.read_exactly(if remaining < 19 { remaining } else { 19 })
    let header = @binlog.EventHeader::parse(
      head,
      file_offset=reader.position(),
      max_event_size=config.max_event_bytes,
    )
    // Reject truncation before allocating from the event's declared size.
    guard header.event_size.to_uint64() <=
      remaining.reinterpret_as_uint().to_uint64() else {
      raise @binlog.TruncatedEvent(
        file_offset=reader.position(),
        expected=header.event_size,
        actual=remaining.reinterpret_as_uint(),
      )
    }
    let body_size = header.event_size.reinterpret_as_int() - 19
    let body = if body_size == 0 { b"" } else { file.read_exactly(body_size) }
    let event = reader.feed(head + body)
    position += event.header.event_size.reinterpret_as_int()
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
    let previous = if config.decode_previous_gtids &&
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
    if !config.summary_only {
      let line = if rotation is Some(rotation) {
        @cli.rotate_json_line(rotation, event.format.checksum_algorithm)
      } else if previous is Some(previous) {
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
  guard file.read_some(max_len=1) is None else {
    raise InvalidFile("file grew while reading; use a closed binlog file")
  }
  reader.finish()
  if config.json_output {
    @stdio.stdout.write(stats.json_line(length) + "\n")
  } else {
    for line in stats.lines(length) {
      @stdio.stdout.write(line + "\n")
    }
  }
}
