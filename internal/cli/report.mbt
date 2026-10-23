// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// Names are descriptive labels, not a declaration of body-decoding support.
pub fn event_name(event_type : Byte) -> String {
  match event_type {
    2 => "QUERY_EVENT"
    3 => "STOP_EVENT"
    4 => "ROTATE_EVENT"
    15 => "FORMAT_DESCRIPTION_EVENT"
    16 => "XID_EVENT"
    19 => "TABLE_MAP_EVENT"
    27 => "HEARTBEAT_LOG_EVENT"
    30 => "WRITE_ROWS_EVENT_V2"
    31 => "UPDATE_ROWS_EVENT_V2"
    32 => "DELETE_ROWS_EVENT_V2"
    33 => "GTID_LOG_EVENT"
    34 => "ANONYMOUS_GTID_LOG_EVENT"
    35 => "PREVIOUS_GTIDS_LOG_EVENT"
    _ => "UNKNOWN"
  }
}

///|
pub fn event_columns() -> String {
  "offset\ttype\tname\tbytes\tnext_position\ttimestamp\tserver_id\tflags\tchecksum"
}

///|
pub fn event_line(
  header : @moonbinlog.EventHeader,
  algorithm : @moonbinlog.ChecksumAlgorithm,
) -> String {
  let checksum = if header.event_type == 15 {
    "CRC32"
  } else {
    match algorithm {
      Crc32 => "CRC32"
      Off => "OFF"
    }
  }
  "\{header.file_offset}\t\{header.event_type.to_int()}\t\{event_name(header.event_type)}\t\{header.event_size}\t\{header.next_position}\t\{header.timestamp}\t\{header.server_id}\t\{header.flags.to_uint()}\t\{checksum}"
}

///|
pub struct Stats {
  priv counts : FixedArray[Int32]
  priv mut events : Int32
  priv mut event_bytes : UInt64
}

///|
pub fn Stats::new() -> Stats {
  { counts: FixedArray::make(256, 0), events: 0, event_bytes: 0, }
}

///|
/// Called once for each fully validated event in the file.
pub fn Stats::record(self : Stats, header : @moonbinlog.EventHeader) -> Unit {
  self.counts[header.event_type.to_int()] += 1
  self.events += 1
  self.event_bytes += header.event_size.to_uint64()
}

///|
/// Counts include every type; output order is ascending numeric type.
pub fn Stats::lines(self : Stats, file_bytes : Int32) -> Array[String] {
  let lines = [
    "summary\tevents=\{self.events}\tevent_bytes=\{self.event_bytes}\tfile_bytes=\{file_bytes}",
  ]
  for i in 0..<256 {
    if self.counts[i] > 0 {
      lines.push("type\t\{i}\t\{event_name(i.to_byte())}\t\{self.counts[i]}")
    }
  }
  lines
}
