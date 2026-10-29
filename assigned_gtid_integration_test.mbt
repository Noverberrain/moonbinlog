// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
priv struct AssignedGtidOracle {
  offset : UInt64
  begin_offset : UInt64
  end_offset : UInt64
  xid : UInt64
  events : Int32
  changes : Int32
  gtid : GtidExpected
}

///|
test "real assigned GTID histories and nine event identities match official and server snapshots" {
  for (data, history_end, expected, _) in assigned_gtid_profiles() {
    let events = mysql_events(data)
    assert_eq(events.length(), 18)
    let history = @moonbinlog.PreviousGtidsEvent::parse(
      events[1].format,
      events[1].raw,
      file_offset=events[1].header.file_offset,
    )
    assert_eq(history.sids.length(), 1)
    assert_eq(history.sids[0].sid, expected[0].gtid.sid)
    assert_eq(history.sids[0].intervals.length(), 1)
    assert_eq(history.sids[0].intervals[0].start, 1UL)
    assert_eq(history.sids[0].intervals[0].end_exclusive, history_end)
    let mut count = 0
    for event in events {
      assert_true(event.header.event_type != 34)
      if event.header.event_type == 33 {
        let value = @moonbinlog.GtidEvent::parse(
          event.format,
          event.raw,
          file_offset=event.header.file_offset,
        )
        gtid_assert(value, expected[count].gtid)
        assert_false(value.is_anonymous())
        assert_eq(value.header.file_offset, expected[count].offset)
        assert_eq(
          value.gno,
          history_end + count.reinterpret_as_uint().to_uint64(),
        )
        count += 1
      }
    }
    assert_eq(count, 3)
  }
}

///|
test "real assigned GTID bindings match XIDs ranges exact row images and rollback absence" {
  for (data, _, expected, oracle) in assigned_gtid_profiles() {
    let events = mysql_events(data)
    let decoder = @moonbinlog.GtidTransactionDecoder::new(events[0].format)
    let images = []
    let mut count = 0
    for event in events {
      if event.header.event_type == 33 || decoder.is_active() {
        let step = decoder.feed(
          event.raw,
          file_offset=event.header.file_offset,
          integer_unsigned=[Some(false), None],
        )
        if step.outcome is Some(value) {
          let expected = expected[count]
          gtid_assert(value.gtid, expected.gtid)
          assert_eq(value.start_offset, expected.offset)
          assert_eq(value.end_offset, expected.end_offset)
          assert_eq(value.event_count, expected.events)
          assert_eq(value.wire_bytes, expected.end_offset - expected.offset)
          assert_eq(value.gtid.transaction_length, Some(value.wire_bytes))
          guard value.transaction is Committed(transaction) else {
            fail("rolled-back insert leaked into log")
          }
          assert_eq(transaction.start_offset, expected.begin_offset)
          assert_eq(transaction.end_offset, expected.end_offset)
          assert_eq(transaction.xid, Some(expected.xid))
          assert_eq(transaction.change_count, expected.changes)
          assert_eq(transaction.events.length(), 1)
          assert_eq(transaction.event_count + 1, value.event_count)
          for rows in transaction.events {
            for change in rows.changes {
              match change {
                Insert(row) | Delete(row) => images.push(row)
                Update(before~, after~) => {
                  images.push(before)
                  images.push(after)
                }
              }
            }
          }
          count += 1
        }
      }
    }
    decoder.finish()
    assert_eq(count, 3)
    assert_eq(images.length(), oracle.length())
    for i, row in images {
      assert_eq(row.columns.length(), 2)
      for j, cell in row.columns {
        assert_eq(mysql_cell_text(cell), oracle[i][j])
      }
    }
  }
}

///|
test "real assigned GTID metadata schema feeds CLI binding and committed row reports" {
  for (data, _, expected, _) in assigned_gtid_profiles() {
    let events = mysql_events(data)
    let template = @cli.SchemaTemplate::new(use_table_metadata=true)
    for event in events {
      template.feed(event)
    }
    let schema = @moonbinlog.SchemaConfig::parse(template.render())
    let scanner = @cli.TransactionScanner::new(schema, with_gtid=true, filter={
      database: Some("moonbinlog_fixture"),
      table: Some("sample"),
    })
    let mut count = 0
    for event in events {
      if scanner.feed(event) is Some(outcome) {
        assert_true(scanner.outcome_selected())
        guard scanner.gtid_outcome() is Some(value) else {
          fail("missing assigned GTID association")
        }
        assert_eq(value.gtid.gno, expected[count].gtid.gno)
        guard @json.parse(
            @cli.gtid_transaction_line(value, schema=Some(schema)),
          )
          is Object(fields) else {
          fail("missing bound report")
        }
        assert_true(fields.contains("gtid"))
        assert_true(fields.contains("gtid_span"))
        assert_true(fields.contains("row_changes"))
        fields.remove("gtid") |> ignore
        fields.remove("gtid_span") |> ignore
        assert_eq(
          Json::object(fields),
          @json.parse(@cli.transaction_rows_line(outcome, schema)),
        )
        count += 1
      }
    }
    scanner.finish()
    assert_eq(count, 3)
    assert_eq(scanner.gtid_outcome(), None)
  }
}
