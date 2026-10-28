// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// Preserve raw SID entry order and half-open bounds, including empty entries.
/// Decimal strings retain precision beyond JSON Number's exact integer range.
pub fn previous_gtids_json_line(
  previous : @moonbinlog.PreviousGtidsEvent,
  algorithm : @moonbinlog.ChecksumAlgorithm,
) -> String {
  Json::object(previous_gtids_json_fields(previous, algorithm)).stringify()
}

///|
fn previous_gtids_json_fields(
  previous : @moonbinlog.PreviousGtidsEvent,
  algorithm : @moonbinlog.ChecksumAlgorithm,
) -> Map[String, Json] {
  let fields = event_json_fields(previous.header, algorithm)
  let sids = previous.sids
    .iter()
    .map(entry => {
      let sid = sid_uuid(entry.sid)
      let intervals = entry.intervals
        .iter()
        .map(interval => {
          Json::object({
            "start": Json::string(interval.start.to_string()),
            "end_exclusive": Json::string(interval.end_exclusive.to_string()),
          })
        })
      Json::object({
        "sid": Json::string(sid),
        "intervals": Json::array(Array::from_iter(intervals)),
      })
    })
  fields["previous_gtids"] = { "sids": Json::array(Array::from_iter(sids)) }
  fields
}
