///|
/// Validate the first four bytes of an unencrypted binlog file.
/// Bytes after the signature are ignored. This does not establish the binlog
/// version: that requires decoding FORMAT_DESCRIPTION_EVENT in a later step.
///
/// ```mbt check
/// test {
///   @moonbinlog.validate_file_header([0xfe, 0x62, 0x69, 0x6e])
/// }
/// ```
pub fn validate_file_header(data : BytesView) -> Unit raise DecodeError {
  guard data.length() >= 4 else {
    raise TruncatedInput(file_offset=0, expected=4, actual=data.length())
  }
  guard data is [0xfe, 0x62, 0x69, 0x6e, ..] else {
    raise InvalidMagic(actual=data[:4].to_owned())
  }
}
