// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// Validates a signature and then one complete event at a time. The caller
/// provides I/O and retains each returned event's underlying Bytes as needed.
/// Processing errors clear the FDE and permanently stop the reader. A feed
/// after successful finish is rejected without changing its final context.
/// No transaction or cross-file continuity is inferred.
pub struct BinlogEventStream {
  priv max_event_size : UInt32
  priv mut offset : UInt64
  priv mut context : FormatDescription?
  priv mut failed : Bool
  priv mut finished : Bool
}

///|
/// Signature must start at the beginning of an unencrypted v4 binlog file.
pub fn BinlogEventStream::new(
  signature : BytesView,
  max_event_size~ : UInt32 = 16_777_216,
) -> BinlogEventStream raise DecodeError {
  guard max_event_size >= 19 else { raise InvalidEventLimit(max_event_size~) }
  validate_file_header(signature)
  { max_event_size, offset: 4, context: None, failed: false, finished: false, }
}

///|
/// Physical offset of the next event, or the failing event after an error.
pub fn BinlogEventStream::position(self : BinlogEventStream) -> UInt64 {
  self.offset
}

///|
pub fn BinlogEventStream::format(
  self : BinlogEventStream,
) -> FormatDescription? {
  self.context
}

///|
/// Feed a complete event. Bytes after its declared size are not consumed.
/// The returned views retain their input, including after later calls.
pub fn BinlogEventStream::feed(
  self : BinlogEventStream,
  data : BytesView,
) -> BinlogFileEvent raise DecodeError {
  let file_offset = self.offset
  guard !self.failed else { raise FileReaderFailed(file_offset~) }
  guard !self.finished else { raise StreamAlreadyFinished(file_offset~) }
  errdefer {
    self.failed = true
    self.context = None
  }
  let (header, raw) = complete_event(
    data,
    file_offset~,
    max_event_size=self.max_event_size,
  )
  guard file_offset <= 0xffffffffffffffffUL - header.event_size.to_uint64() else {
    raise InvalidStreamOffset(file_offset~)
  }
  let event = decode_file_event(header, raw, self.context, self.max_event_size)
  self.offset += header.event_size.to_uint64()
  self.context = Some(event.format)
  event
}

///|
/// Mark clean EOF after at least one valid FDE. Successful finish is idempotent;
/// no further events can be fed. An unfinished transaction is outside scope.
pub fn BinlogEventStream::finish(
  self : BinlogEventStream,
) -> Unit raise DecodeError {
  let file_offset = self.offset
  guard !self.failed else { raise FileReaderFailed(file_offset~) }
  if self.finished {
    return
  }
  errdefer {
    self.failed = true
    self.context = None
  }
  guard self.context is Some(_) else {
    raise MissingFormatDescription(file_offset~)
  }
  self.finished = true
}
