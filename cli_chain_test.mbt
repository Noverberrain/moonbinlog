// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
fn feed_chain_file(
  chain : @cli.RotationChain,
  events : Array[@moonbinlog.BinlogFileEvent],
) -> Unit raise {
  for event in events {
    chain.feed(event) |> ignore
  }
}

///|
test "CLI chain accepts real CRC32 and OFF files with fresh offsets and optional final successor" {
  let chain = @cli.RotationChain::new()
  let (first, _, next_name) = rotate_real_oracles[0]
  chain.begin_file(b"first.binlog")
  feed_chain_file(chain, mysql_events(first))
  chain.end_file(first.length(), has_next=true)
  chain.begin_file(next_name)
  feed_chain_file(chain, mysql_events(mysql_json_off_full))
  chain.end_file(mysql_json_off_full.length(), has_next=false)
  chain.finish()
  let terminal = @cli.RotationChain::new()
  terminal.begin_file(b"last")
  feed_chain_file(terminal, mysql_events(file_magic + fde_crc32))
  terminal.end_file(file_magic.length() + fde_crc32.length(), has_next=false)
  terminal.finish()
}

///|
test "CLI chain requires terminal rotation to position four for intermediate files" {
  for raw in [b"", rotate_zero, rotate_max] {
    let data = file_magic + fde_crc32 + raw
    let chain = @cli.RotationChain::new()
    chain.begin_file(b"first")
    feed_chain_file(chain, mysql_events(data))
    try chain.end_file(data.length(), has_next=true) catch {
      InvalidChainLink(file_index=0, ..) => ()
      other => fail("unexpected rotation link error: \{Repr(other)}")
    } noraise {
      _ => fail("missing or unsupported rotation accepted")
    }
    try chain.begin_file(b"next") catch {
      InvalidChainState(_) => ()
      other => fail("unexpected chain recovery: \{Repr(other)}")
    } noraise {
      _ => fail("failed chain recovered")
    }
  }
}

///|
test "CLI chain rejects mismatched target names and cannot resume after failure" {
  let data = file_magic + fde_crc32 + rotate_start
  let chain = @cli.RotationChain::new()
  chain.begin_file(b"first")
  feed_chain_file(chain, mysql_events(data))
  chain.end_file(data.length(), has_next=true)
  try chain.begin_file(b"MYSQL-bin.000002") catch {
    InvalidChainLink(file_index=1, ..) => ()
    other => fail("unexpected filename mismatch: \{Repr(other)}")
  } noraise {
    _ => fail("case-insensitive filename match")
  }
  try chain.begin_file(b"mysql-bin.000002") catch {
    InvalidChainState(_) => ()
    other => fail("unexpected chain recovery: \{Repr(other)}")
  } noraise {
    _ => fail("bad filename state recovered")
  }
  let repeated = @cli.RotationChain::new()
  repeated.begin_file(b"mysql-bin.000002")
  feed_chain_file(repeated, mysql_events(data))
  repeated.end_file(data.length(), has_next=true)
  try repeated.begin_file(b"mysql-bin.000002") catch {
    InvalidChainLink(file_index=1, ..) => ()
    other => fail("unexpected repeated name error: \{Repr(other)}")
  } noraise {
    _ => fail("same filename replayed")
  }
}

///|
test "CLI chain rejects post rotation events incomplete consumption and lifecycle misuse" {
  let events = cli_synthetic_events(rotate_start + tx_begin)
  let late = @cli.RotationChain::new()
  late.begin_file(b"first")
  feed_chain_file(late, events[:2].to_owned())
  try late.feed(events[2]) catch {
    @cli.ChainError::InvalidChainLink(..) => ()
    other => fail("unexpected late event: \{Repr(other)}")
  } noraise {
    _ => fail("event after terminal rotation accepted")
  }
  let offsets = @cli.RotationChain::new()
  offsets.begin_file(b"first")
  try offsets.feed(events[1]) catch {
    @cli.ChainError::InvalidChainState(_) => ()
    other => fail("unexpected missing FDE: \{Repr(other)}")
  } noraise {
    _ => fail("file missing FDE accepted")
  }
  let incomplete = @cli.RotationChain::new()
  incomplete.begin_file(b"first")
  incomplete.feed(events[0]) |> ignore
  try incomplete.end_file(4, has_next=false) catch {
    InvalidChainState(_) => ()
    other => fail("unexpected incomplete file: \{Repr(other)}")
  } noraise {
    _ => fail("unconsumed file accepted")
  }
  let unfinished = @cli.RotationChain::new()
  try unfinished.finish() catch {
    InvalidChainState(_) => ()
    other => fail("unexpected unfinished chain: \{Repr(other)}")
  } noraise {
    _ => fail("unfinished chain succeeded")
  }
  try unfinished.begin_file(b"after-failure") catch {
    InvalidChainState(_) => ()
    other => fail("unexpected recovery: \{Repr(other)}")
  } noraise {
    _ => fail("finish failure recovered")
  }
}

///|
test "CLI chain JSON preserves source labels file snapshots and aggregate counts" {
  let events = cli_synthetic_events(rotate_max)
  let event = events[1]
  let rotation = @moonbinlog.RotateEvent::parse(
    event.format,
    event.raw,
    file_offset=event.header.file_offset,
  )
  guard @json.parse(
      @cli.chain_event_line(event, Some(rotation), 1, "目录/文件\n"),
    )
    is {
      "source": { "index": 1, "path": "目录/文件\n", .. },
      "rotate": { "position": "18446744073709551615", .. },
      ..
    } else {
    fail("chain source or exact target missing")
  }
  guard @json.parse(@cli.chain_event_line(event, None, 0, "a"))
    is Object(fields) else {
    fail("missing event")
  }
  assert_false(fields.contains("rotate"))
  let total = @cli.Stats::new()
  let stats = @cli.Stats::new()
  total.record(event.header)
  stats.record(event.header)
  let snapshot = stats.chain_file_json(0, "a", 100)
  stats.record(event.header)
  guard @json.parse(total.chain_json_line(100, [snapshot]))
    is {
      "kind": "chain_summary",
      "file_count": 1,
      "events": 1,
      "file_bytes": 100,
      "files": [
        {
          "kind": "file_summary",
          "events": 1,
          "source": { "path": "a", .. },
          ..
        },
      ],
      ..
    } else {
    fail("chain totals or snapshot changed")
  }
}
