// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// Input comes from parsers that guarantee exactly 16 SID bytes.
fn sid_uuid(sid : Bytes) -> String {
  let hex = @hex.encode(sid)
  "\{hex[0:8]}-\{hex[8:12]}-\{hex[12:16]}-\{hex[16:20]}-\{hex[20:32]}"
}

///|
/// UInt64 values use decimal strings; absent extensions and anonymous identity
/// use JSON null. The raw SID/GNO are retained even for anonymous events.
pub fn gtid_json_line(
  gtid : @moonbinlog.GtidEvent,
  algorithm : @moonbinlog.ChecksumAlgorithm,
) -> String {
  Json::object(gtid_json_fields(gtid, algorithm)).stringify()
}

///|
fn gtid_json_fields(
  gtid : @moonbinlog.GtidEvent,
  algorithm : @moonbinlog.ChecksumAlgorithm,
) -> Map[String, Json] {
  let fields = event_json_fields(gtid.header, algorithm)
  fields["gtid"] = gtid_payload(gtid)
  fields
}

///|
fn gtid_payload(gtid : @moonbinlog.GtidEvent) -> Json {
  let sid = sid_uuid(gtid.sid)
  {
    "anonymous": @json.to_json(gtid.is_anonymous()),
    "identity": if gtid.is_anonymous() {
      Json::null()
    } else {
      Json::string("\{sid}:\{gtid.gno}")
    },
    "sid": Json::string(sid),
    "gno": Json::string(gtid.gno.to_string()),
    "flags": @json.to_json(gtid.flags.to_int()),
    "may_have_sbr_statements": @json.to_json(gtid.may_have_sbr_statements()),
    "last_committed": Json::string(gtid.last_committed.to_string()),
    "sequence_number": Json::string(gtid.sequence_number.to_string()),
    "commit_timestamps": match gtid.commit_timestamps {
      Some(pair) =>
        {
          "immediate": Json::string(pair.immediate.to_string()),
          "original": Json::string(pair.original.to_string()),
        }
      None => Json::null()
    },
    "transaction_length": match gtid.transaction_length {
      Some(value) => Json::string(value.to_string())
      None => Json::null()
    },
    "server_versions": match gtid.server_versions {
      Some(pair) =>
        {
          "immediate": @json.to_json(pair.immediate),
          "original": @json.to_json(pair.original),
        }
      None => Json::null()
    },
    "commit_group_ticket": match gtid.commit_group_ticket {
      Some(value) => Json::string(value.to_string())
      None => Json::null()
    },
  }
}
