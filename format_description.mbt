// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
/// The policy for events following FORMAT_DESCRIPTION_EVENT.
/// The format-description event itself always carries CRC32 in MySQL 8.0.
pub(all) enum ChecksumAlgorithm {
  Off
  Crc32
} derive(Debug, Eq)

///|
pub extend ChecksumAlgorithm with Eq::{equal, not_equal}

///|
pub extend ChecksumAlgorithm with @debug.Debug::{to_repr}

///|
/// Immutable, validated MySQL 8.0 format context.
/// Entry i in `post_header_lengths` describes event type i + 1.
pub struct FormatDescription {
  header : EventHeader
  binlog_version : UInt16
  server_version : String
  created_timestamp : UInt32
  common_header_length : Byte
  post_header_lengths : Bytes
  checksum_algorithm : ChecksumAlgorithm
} derive(Debug, Eq)

///|
pub extend FormatDescription with Eq::{equal, not_equal}

///|
pub extend FormatDescription with @debug.Debug::{to_repr}

///|
/// Parse and checksum one complete FORMAT_DESCRIPTION_EVENT (type 15).
/// Requires binlog v4, a MySQL 8.0.x version and a 19-byte common header.
/// Trailing bytes from the next event are not consumed or checksummed.
pub fn FormatDescription::parse(
  data : BytesView,
  file_offset~ : UInt64,
  max_event_size~ : UInt32 = 16_777_216,
) -> FormatDescription raise DecodeError {
  let (header, event) = complete_event(data, file_offset~, max_event_size~)
  guard header.event_type == 15 else {
    raise UnexpectedEventType(
      file_offset~,
      expected=15,
      actual=header.event_type,
    )
  }
  // 19 common + 57 fixed FDE + at least 15 table entries + 1 alg + 4 CRC.
  guard event.length() >= 96 else {
    raise InvalidFormatDescription(
      file_offset~,
      reason="format description is too short",
    )
  }
  let algorithm = event[event.length() - 5]
  let checksum_algorithm = match algorithm {
    0 => Off
    1 => Crc32
    _ => raise UnsupportedChecksumAlgorithm(file_offset~, algorithm~)
  }
  verify_crc32(event, file_offset~, format_description=true)
  let binlog_version = read_u16_le(event, 19)
  guard binlog_version == 4 else {
    raise UnsupportedBinlogVersion(file_offset~, version=binlog_version)
  }
  let server_version = read_server_version(event[21:71], file_offset~)
  let common_header_length = event[75]
  guard common_header_length == 19 else {
    raise UnsupportedHeaderLength(file_offset~, length=common_header_length)
  }
  let table_end = event.length() - 5
  let table = event[76:table_end]
  // The FDE's own post-header length covers its 57 fixed bytes and type table.
  guard table.length() <= 198 && table[14].to_int() == 57 + table.length() else {
    raise InvalidFormatDescription(
      file_offset~,
      reason="inconsistent post-header table length",
    )
  }
  {
    header,
    binlog_version,
    server_version,
    created_timestamp: read_u32_le(event, 71),
    common_header_length,
    post_header_lengths: table.to_owned(),
    checksum_algorithm,
  }
}

///|
/// Check one subsequent complete event and return its body without header/CRC.
/// With Off, bytes after the header are retained in full, without CRC checking.
/// A new FDE must be parsed separately to establish a fresh context.
/// This checks framing/integrity, not the semantics of the event's body.
pub fn FormatDescription::payload(
  self : FormatDescription,
  data : BytesView,
  file_offset~ : UInt64,
  max_event_size~ : UInt32 = 16_777_216,
) -> BytesView raise DecodeError {
  let (header, event) = complete_event(data, file_offset~, max_event_size~)
  guard header.event_type != 15 else {
    raise FormatContextResetRequired(file_offset~)
  }
  match self.checksum_algorithm {
    Off => event[19:]
    Crc32 => {
      guard event.length() >= 23 else {
        raise InvalidEventLength(file_offset~, event_size=header.event_size)
      }
      verify_crc32(event, file_offset~)
      event[19:event.length() - 4]
    }
  }
}

///|
fn read_server_version(
  data : BytesView,
  file_offset~ : UInt64,
) -> String raise DecodeError {
  let mut length = 0
  while length < data.length() && data[length] != 0 {
    guard data[length] >= 0x21 && data[length] <= 0x7e else {
      raise InvalidFormatDescription(
        file_offset~,
        reason="server version is not printable ASCII",
      )
    }
    length += 1
  }
  guard length < data.length() else {
    raise InvalidFormatDescription(
      file_offset~,
      reason="unterminated server version",
    )
  }
  let version = @utf8.decode(data[:length]) catch {
    _ =>
      raise InvalidFormatDescription(
        file_offset~,
        reason="invalid server version encoding",
      )
  }
  guard length >= 5 && version.has_prefix("8.0.") else {
    raise UnsupportedServerVersion(file_offset~, server_version=version)
  }
  let mut patch_end = 4
  while patch_end < length && data[patch_end] >= 0x30 && data[patch_end] <= 0x39 {
    patch_end += 1
  }
  guard patch_end > 4 &&
    (patch_end == length || (data[patch_end] == 0x2d && patch_end + 1 < length)) else {
    raise UnsupportedServerVersion(file_offset~, server_version=version)
  }
  version
}
