// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
pub fn chain_event_line(
  event : @moonbinlog.BinlogFileEvent,
  rotation : @moonbinlog.RotateEvent?,
  index : Int32,
  path : String,
  previous_gtids~ : @moonbinlog.PreviousGtidsEvent? = None,
  gtid~ : @moonbinlog.GtidEvent? = None,
) -> String {
  let fields = if rotation is Some(rotation) {
    rotate_json_fields(rotation, event.format.checksum_algorithm)
  } else if previous_gtids is Some(previous) {
    previous_gtids_json_fields(previous, event.format.checksum_algorithm)
  } else if gtid is Some(gtid) {
    gtid_json_fields(gtid, event.format.checksum_algorithm)
  } else {
    event_json_fields(event.header, event.format.checksum_algorithm)
  }
  fields["source"] = {
    "index": @json.to_json(index),
    "path": Json::string(path),
  }
  Json::object(fields).stringify()
}

///|
pub fn Stats::chain_file_json(
  self : Stats,
  index : Int32,
  path : String,
  file_bytes : Int32,
) -> Json {
  let fields = self.summary_fields(file_bytes)
  fields["kind"] = "file_summary"
  fields["source"] = {
    "index": @json.to_json(index),
    "path": Json::string(path),
  }
  Json::object(fields)
}

///|
pub fn Stats::chain_json_line(
  self : Stats,
  total_bytes : Int32,
  files : Array[Json],
) -> String {
  let fields = self.summary_fields(total_bytes)
  fields["kind"] = "chain_summary"
  fields["file_count"] = @json.to_json(files.length())
  fields["files"] = Json::array(files)
  Json::object(fields).stringify()
}
