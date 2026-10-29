// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// One integrity-checked event and the format active for it.
/// Views retain the input bytes. `raw` includes header/checksum; `body` excludes
/// both. For FDE, body still includes the checksum-algorithm descriptor.
/// An unknown type has validated framing, not validated body semantics.
pub struct BinlogFileEvent {
  header : EventHeader
  raw : BytesView
  body : BytesView
  format : FormatDescription
} derive(Debug, Eq)

///|
pub extend BinlogFileEvent with Eq::{equal, not_equal}

///|
pub extend BinlogFileEvent with @debug.Debug::{to_repr}

///|
/// Sequential traversal of a complete, in-memory unencrypted binlog file.
/// The first event must be FDE. Later FDEs replace the format context.
/// No OS I/O, transaction assembly or event-body dispatch is performed.
pub struct BinlogFileReader {
  priv data : BytesView
  priv max_event_size : UInt32
  priv mut cursor : Int32
  priv mut context : FormatDescription?
  priv mut failed : Bool
}

///|
/// Validate the signature and configuration. Events are validated lazily.
/// The supplied view must start at the file signature, not a resume offset.
///
/// ```mbt check
/// test {
///   // A valid signature initializes the reader; next() still requires FDE.
///   let reader = @moonbinlog.BinlogFileReader::new([0xfe, 0x62, 0x69, 0x6e])
///   assert_eq(reader.position(), 4UL)
///   assert_eq(reader.format(), None)
/// }
/// ```
pub fn BinlogFileReader::new(
  data : BytesView,
  max_event_size~ : UInt32 = 16_777_216,
) -> BinlogFileReader raise DecodeError {
  guard max_event_size >= 19 else { raise InvalidEventLimit(max_event_size~) }
  validate_file_header(data)
  { data, max_event_size, cursor: 4, context: None, failed: false, }
}

///|
/// Physical offset of the next event, or the failing event after an error.
/// Offsets are relative to the supplied view, independent of next_position.
pub fn BinlogFileReader::position(self : BinlogFileReader) -> UInt64 {
  self.cursor.reinterpret_as_uint().to_uint64()
}

///|
/// Current validated format; absent before FDE or after any traversal error.
pub fn BinlogFileReader::format(self : BinlogFileReader) -> FormatDescription? {
  self.context
}

///|
fn BinlogFileReader::invalidate(self : BinlogFileReader) -> Unit {
  self.failed = true
  self.context = None
}

///|
// Shared by in-memory and event-at-a-time readers. The caller has already
// checked the complete declared event and supplies its physical header.
fn decode_file_event(
  header : EventHeader,
  raw : BytesView,
  context : FormatDescription?,
  max_event_size : UInt32,
) -> BinlogFileEvent raise DecodeError {
  let file_offset = header.file_offset
  let (format, body) = if header.event_type == 15 {
    let format = FormatDescription::parse(raw, file_offset~, max_event_size~)
    (format, raw[19:raw.length() - 4])
  } else {
    guard context is Some(format) else {
      raise MissingFormatDescription(file_offset~)
    }
    (format, format.payload(raw, file_offset~, max_event_size~))
  }
  { header, raw, body, format, }
}

///|
/// Return exactly one event, or None at a clean event-boundary EOF after FDE.
/// Any error permanently stops this reader and clears its format. Already
/// returned events remain valid, but do not imply a complete file/transaction.
/// Consume until None to validate the entire supplied input.
pub fn BinlogFileReader::next(
  self : BinlogFileReader,
) -> BinlogFileEvent? raise DecodeError {
  let file_offset = self.position()
  guard !self.failed else { raise FileReaderFailed(file_offset~) }
  errdefer self.invalidate()
  if self.cursor == self.data.length() {
    guard self.context is Some(_) else {
      raise MissingFormatDescription(file_offset~)
    }
    return None
  }
  let remaining = self.data[self.cursor:]
  let (header, raw) = complete_event(
    remaining,
    file_offset~,
    max_event_size=self.max_event_size,
  )
  let event = decode_file_event(header, raw, self.context, self.max_event_size)
  // complete_event proves raw fits in remaining; this sum cannot exceed length.
  self.cursor += raw.length()
  self.context = Some(event.format)
  Some(event)
}
