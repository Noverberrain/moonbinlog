// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
test "table-map context resolves ids and replaces a reused id at capacity" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  let context = @moonbinlog.TableMapContext::new(format, max_tables=1)
  assert_eq(context.length(), 0)
  assert_true(context.get(1) is None)
  let initial = context.apply(tm_basic, file_offset=126)
  assert_eq(context.length(), 1)
  assert_eq(context.get(initial.table_id), Some(initial))
  let replaced = context.apply(tm_renamed, file_offset=300)
  assert_eq(context.length(), 1)
  assert_eq(replaced.table, "orders_archive")
  assert_eq(initial.table, "orders")
  assert_eq(context.get(initial.table_id), Some(replaced))
}

///|
test "context clears maps at explicit statement boundaries" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  let context = @moonbinlog.TableMapContext::new(format)
  let first = context.apply(tm_basic, file_offset=126)
  let second = context.apply(tm_second_id, file_offset=300)
  assert_eq(context.length(), 2)
  context.clear()
  assert_eq(context.length(), 0)
  assert_true(context.get(first.table_id) is None)
  assert_true(context.get(second.table_id) is None)
}

///|
test "failed remapping invalidates existing maps rather than leaving stale definitions" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  let context = @moonbinlog.TableMapContext::new(format)
  let initial = context.apply(tm_basic, file_offset=126)
  try context.apply(tm_bad_terminator, file_offset=300) catch {
    InvalidTableMap(..) => ()
    other => fail("unexpected error: \{Repr(other)}")
  } noraise {
    _ => fail("bad remapping was installed")
  }
  assert_eq(context.length(), 0)
  assert_true(context.get(initial.table_id) is None)
  let recovered = context.apply(tm_basic, file_offset=400)
  assert_eq(context.get(recovered.table_id), Some(recovered))
}

///|
test "context resets its format and cache for another file or format event" {
  let crc = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  let off = @moonbinlog.FormatDescription::parse(fde_off, file_offset=4)
  let context = @moonbinlog.TableMapContext::new(crc)
  ignore(context.apply(tm_basic, file_offset=126))
  context.reset(off)
  assert_eq(context.length(), 0)
  let table = context.apply(tm_off, file_offset=126)
  assert_eq(table.table, "orders")
  assert_eq(context.length(), 1)
}

///|
test "context table-count quota fails explicitly and invalidates the old scope" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  let context = @moonbinlog.TableMapContext::new(format, max_tables=1)
  ignore(context.apply(tm_basic, file_offset=126))
  try context.apply(tm_second_id, file_offset=300) catch {
    TableContextLimitExceeded(file_offset=300, ..) => ()
    other => fail("unexpected error: \{Repr(other)}")
  } noraise {
    _ => fail("table quota was ignored")
  }
  assert_eq(context.length(), 0)
}

///|
test "context byte budget accounts for replacement instead of double counting" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  let budget = (tm_basic.length() * 2).reinterpret_as_uint().to_uint64()
  let context = @moonbinlog.TableMapContext::new(format, max_bytes=budget)
  ignore(context.apply(tm_renamed, file_offset=126))
  ignore(context.apply(tm_basic, file_offset=300))
  ignore(context.apply(tm_basic, file_offset=400))
  ignore(context.apply(tm_second_id, file_offset=500))
  assert_eq(context.length(), 2)
}

///|
test "context rejects events exceeding its retained-byte budget" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  let budget = tm_basic.length().reinterpret_as_uint().to_uint64()
  let context = @moonbinlog.TableMapContext::new(format, max_bytes=budget)
  ignore(context.apply(tm_basic, file_offset=126))
  try context.apply(tm_renamed, file_offset=300) catch {
    TableContextLimitExceeded(..) => ()
    other => fail("unexpected error: \{Repr(other)}")
  } noraise {
    _ => fail("byte budget was ignored")
  }
  assert_eq(context.length(), 0)
}

///|
test "context rejects zero capacity settings" {
  let format = @moonbinlog.FormatDescription::parse(fde_crc32, file_offset=4)
  try @moonbinlog.TableMapContext::new(format, max_tables=0) catch {
    InvalidTableContextLimit(..) => ()
    other => fail("unexpected error: \{Repr(other)}")
  } noraise {
    _ => fail("zero table capacity was accepted")
  }
  try @moonbinlog.TableMapContext::new(format, max_bytes=0) catch {
    InvalidTableContextLimit(..) => ()
    other => fail("unexpected error: \{Repr(other)}")
  } noraise {
    _ => fail("zero byte capacity was accepted")
  }
}
