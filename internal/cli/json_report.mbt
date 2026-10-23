// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// One compact JSON object per line; caller supplies the newline.
/// UInt64 fields use decimal strings to preserve precision in JSON consumers.
pub fn event_json_line(
  header : @moonbinlog.EventHeader,
  algorithm : @moonbinlog.ChecksumAlgorithm,
) -> String {
  Json::object({
    "schema_version": @json.to_json(1),
    "kind": Json::string("event"),
    "offset": Json::string(header.file_offset.to_string()),
    "type": @json.to_json(header.event_type.to_int()),
    "name": Json::string(event_name(header.event_type)),
    "bytes": @json.to_json(header.event_size),
    "next_position": @json.to_json(header.next_position),
    "timestamp": @json.to_json(header.timestamp),
    "server_id": @json.to_json(header.server_id),
    "flags": @json.to_json(header.flags.to_uint()),
    "checksum": Json::string(event_checksum(header, algorithm)),
  }).stringify()
}

///|
/// Emit only after clean EOF. Type counts are sorted by numeric type code.
pub fn Stats::json_line(self : Stats, file_bytes : Int32) -> String {
  let types = []
  for i in 0..<256 {
    if self.counts[i] > 0 {
      types.push(
        Json::object({
          "type": @json.to_json(i),
          "name": Json::string(event_name(i.to_byte())),
          "count": @json.to_json(self.counts[i]),
        }),
      )
    }
  }
  Json::object({
    "schema_version": @json.to_json(1),
    "kind": Json::string("summary"),
    "events": @json.to_json(self.events),
    "event_bytes": Json::string(self.event_bytes.to_string()),
    "file_bytes": @json.to_json(file_bytes),
    "types": Json::array(types),
  }).stringify()
}
