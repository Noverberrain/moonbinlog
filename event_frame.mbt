// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
// Validate availability before converting a wire UInt32 length into an Int32.
// Returning only this event prevents following bytes from entering its CRC.
fn complete_event(
  data : BytesView,
  file_offset~ : UInt64,
  max_event_size~ : UInt32,
) -> (EventHeader, BytesView) raise DecodeError {
  let header = EventHeader::parse(data, file_offset~, max_event_size~)
  let actual = data.length().reinterpret_as_uint()
  guard header.event_size <= actual else {
    raise TruncatedEvent(file_offset~, expected=header.event_size, actual~)
  }
  (header, data[:header.event_size.reinterpret_as_int()])
}
