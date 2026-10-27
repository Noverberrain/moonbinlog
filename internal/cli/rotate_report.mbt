// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// Add a rotation payload to the ordinary event object. Text is present only
/// when the whole raw filename is valid UTF-8; BOM and NUL remain data.
pub fn rotate_json_line(
  rotation : @moonbinlog.RotateEvent,
  algorithm : @moonbinlog.ChecksumAlgorithm,
) -> String {
  let fields = event_json_fields(rotation.header, algorithm)
  let text = try @utf8.decode(rotation.next_binlog, ignore_bom=false) catch {
    _ => None
  } noraise {
    value => Some(value)
  }
  fields["rotate"] = {
    "position": Json::string(rotation.position.to_string()),
    "next_binlog_hex": Json::string(@hex.encode(rotation.next_binlog)),
    "next_binlog_utf8": match text {
      Some(value) => Json::string(value)
      None => Json::null()
    },
  }
  Json::object(fields).stringify()
}
