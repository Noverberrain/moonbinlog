// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn invalid_args(argv : ArrayView[String]) -> Unit raise {
  try @cli.parse_args(argv) catch {
    InvalidArguments(_) => ()
  } noraise {
    _ => fail("invalid CLI arguments accepted")
  }
}

///|
fn report_header(kind : Byte) -> @moonbinlog.EventHeader raise {
  let bytes : Bytes = [
    0xff, 0xff, 0xff, 0xff, kind, 1, 0, 0, 0, 19, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff,
  ]
  @moonbinlog.EventHeader::parse(bytes, file_offset=0x100000004)
}

///|
test "CLI defaults and a Unicode filename" {
  guard @cli.parse_args(["日志 01.binlog"]) is Inspect(config) else {
    fail("expected inspect")
  }
  assert_eq(config.path, "日志 01.binlog")
  assert_false(config.summary_only)
  assert_false(config.json_output)
  assert_eq(config.max_event_bytes, 16_777_216U)
  assert_eq(config.max_file_bytes, 67_108_864)
}

///|
test "CLI accepts options around filename and explicit decimal limits" {
  guard @cli.parse_args([
      "--summary", "file", "--max-event-bytes", "00019", "--max-file-bytes", "1",
    ])
    is Inspect(config) else {
    fail("expected inspect")
  }
  assert_true(config.summary_only)
  assert_eq(config.max_event_bytes, 19U)
  assert_eq(config.max_file_bytes, 1)
  guard @cli.parse_args([
      "--max-event-bytes", "4294967295", "--max-file-bytes", "2147483647", "file",
    ])
    is Inspect(config) else {
    fail("expected inspect")
  }
  assert_eq(config.max_event_bytes, 0xffffffffU)
  assert_eq(config.max_file_bytes, 2147483647)
}

///|
test "CLI help and option terminator have unambiguous meanings" {
  assert_eq(@cli.parse_args(["--help"]), Help)
  assert_eq(@cli.parse_args(["-h"]), Help)
  guard @cli.parse_args(["--", "--help"]) is Inspect(config) else {
    fail("expected filename")
  }
  assert_eq(config.path, "--help")
  invalid_args(["file", "--help"])
  invalid_args(["--help", "file"])
  invalid_args(["--"])
  invalid_args(["--", "a", "b"])
}

///|
test "CLI rejects unknown duplicate and missing arguments" {
  for
    argv in [
      [],
      [""],
      ["a", "b"],
      ["--unknown"],
      ["--summary", "--summary", "file"],
      ["--max-event-bytes"],
      ["--max-file-bytes"],
      ["--max-event-bytes=19", "file"],
      ["--max-event-bytes", "19", "--max-event-bytes", "20", "file"],
      ["--max-file-bytes", "1", "--max-file-bytes", "2", "file"],
    ] {
    invalid_args(argv[:])
  }
}

///|
test "CLI rejects nondecimal overflowing and invalid resource limits" {
  for option in ["--max-event-bytes", "--max-file-bytes"] {
    for
      value in [
        "", "-1", "+19", "0x20", "1.5", "1_000", " 19", "19 ", "１９", "4294967296",
      ] {
      invalid_args([option, value, "file"])
    }
  }
  for value in ["0", "18"] {
    invalid_args(["--max-event-bytes", value, "file"])
  }
  for value in ["0", "2147483648"] {
    invalid_args(["--max-file-bytes", value, "file"])
  }
}

///|
test "CLI event labels retain unknown codes without claiming semantic support" {
  assert_eq(@cli.event_name(255), "UNKNOWN")
  assert_eq(@cli.event_name(0), "UNKNOWN")
  assert_eq(@cli.event_name(34), "ANONYMOUS_GTID_LOG_EVENT")
  assert_eq(@cli.event_name(30), "WRITE_ROWS_EVENT_V2")
}

///|
test "CLI TSV preserves unsigned fields and FDE always reports its own CRC" {
  let header = report_header(15)
  assert_eq(
    @cli.event_line(header, Off),
    "4294967300\t15\tFORMAT_DESCRIPTION_EVENT\t19\t0\t4294967295\t1\t65535\tCRC32",
  )
  assert_eq(
    @cli.event_line(report_header(255), Off),
    "4294967300\t255\tUNKNOWN\t19\t0\t4294967295\t1\t65535\tOFF",
  )
}

///|
test "CLI summary counts every event and orders types numerically" {
  let stats = @cli.Stats::new()
  assert_eq(stats.lines(4), ["summary\tevents=0\tevent_bytes=0\tfile_bytes=4"])
  stats.record(report_header(255))
  stats.record(report_header(2))
  stats.record(report_header(255))
  assert_eq(stats.lines(61), [
    "summary\tevents=3\tevent_bytes=57\tfile_bytes=61", "type\t2\tQUERY_EVENT\t1",
    "type\t255\tUNKNOWN\t2",
  ])
}
