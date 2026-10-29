# GTID 前缀与显式事务绑定

`GtidTransactionDecoder` 把连续的 `GTID_EVENT / ANONYMOUS_GTID_EVENT → BEGIN → TABLE_MAP / ROWS v2 → XID / COMMIT / ROLLBACK` 作为一个区间处理。只有结束边界出现后，才返回 GTID 信息及原有提交/回滚结果。

这是独立的库接口，复用现有 [TransactionDecoder](transactions.md)；没有改变旧 API、默认 CLI 或未开启 --with-gtid 的事务输出。CLI 可显式选择 [GTID 事务导出](cli-gtid-transactions.md)。它要求调用方已知涉及的表支持事务，不从 TABLE_MAP 推断存储引擎。

## 调用与输入范围

使用已验证的 `FormatDescription` 创建 `GtidTransactionDecoder::new(format)`，逐事件调用 `feed(data, file_offset~, integer_unsigned~)`。返回 `GtidTransactionStep.header` 表示当前事件；outcome 在未结束时为 None。

每份输入的声明事件之后可以跟随后续字节，feed 只消费当前事件。调用方使用 header.event_size 前进，并提供真实物理偏移，不使用公共头 next_position 代替。首个 GTID 与 BEGIN、事务内部所有事件必须严格相邻，拒绝缺口、重叠和重复偏移。

调用示意（data、format、signs_for_event 和 consume 由调用方提供，并处理 DecodeError）：

```moonbit
let decoder = @moonbinlog.GtidTransactionDecoder::new(format)
// 已选择一个从 GTID 开始的连续显式事务区间。
let mut cursor = 0
while cursor < data.length() {
  let step = decoder.feed(
    data[cursor:],
    file_offset=start_offset + cursor.reinterpret_as_uint().to_uint64(),
    integer_unsigned=signs_for_event(cursor),
  )
  if step.outcome is Some(value) {
    consume(value)
  }
  cursor += step.header.event_size.reinterpret_as_int()
}
decoder.finish()
```

整数 signedness 仍须由调用方按表定义提供；其他字段、行镜像、语句级映射清理和变化数规则沿用原事务解码器。SBR 标志只保留为提示，实际出现不支持的语句时仍失败。

这不是整份文件扫描器：空闲时只接受类型 33/34，FDE、PREVIOUS_GTIDS、ROTATE 等包络也不自动跳过。调用方可在无待定区间时另行处理文件级事件，但活动区间内不能跳过任何事件；新文件/FDE 必须先 finish，再创建新实例。空闲的下一份 GTID 可以从另一个起点开始，接口不证明不同已结束区间之间的文件或 GTID 历史连续性。

## 状态与错误

| 当前状态 / 输入 | 行为 |
| --- | --- |
| 空闲 / 合法 GTID 或匿名 GTID | 保存前缀，is_active() 为 true，无 outcome |
| 有前缀 / 紧邻的显式 BEGIN | 启动内层事务，无 outcome |
| 事务内 / 合法表映射和行事件 | 缓冲行变化，STMT_END_F 不提交 |
| 事务内 / XID 或 COMMIT | 返回前缀与 CommittedTransaction，然后清理状态 |
| 事务内 / ROLLBACK | 返回前缀与 RolledBack，只含丢弃计数，不含待定行值 |
| 任意非法顺序、解析错误、配额失败 | 丢弃前缀、待定行与映射，永久失败 |

嵌套 BEGIN、第二份 GTID 抢占未结束区间、缺失 BEGIN、未知事件或普通业务 QUERY 都不能形成结果。匿名前缀仍使用 GtidEvent.is_anonymous() 表示，不生成可用于去重的身份。

EOF 时必须调用 finish()。只有 GTID、尚未 BEGIN，同样属于未完成区间，返回 `IncompleteGtidTransaction(start_offset~)`，起点为 GTID 的物理位置。即使已经缓冲行值，EOF 也不会提交。

新的 `InvalidGtidTransactionState(file_offset~, reason~)` 表达缺失前缀、外层偏移间隙/重叠或 UInt64 位置溢出；GTID、边界、行和配额错误继续沿用已有 DecodeError。任一 feed/finish 错误之后，后续 feed/finish 均返回 `GtidTransactionFailed`，is_active() 为 false，必须创建新实例。成功的空闲 finish 只是边界检查，不封存实例。

## 返回值与计数

`GtidTransactionOutcome` 包含 gtid、transaction、start_offset、end_offset、event_count 和 wire_bytes。其中 transaction 是原有 TransactionOutcome，调用方仍通过 Committed / RolledBack 区分结果。

外层起点为 GTID，终点为结束事件之后，事件数/字节包含 GTID 前缀。嵌套 CommittedTransaction 的起点仍是 BEGIN，保持既有计数与快照语义；两层终点相同，外层事件数比内层多 1，字节数多出 GTID 事件长度。回滚也有完整外层范围/事件/字节计数，但不暴露待定行。

可以依次绑定多个区间，前一个结果的行快照和身份不会被后一个修改。重复的已分配 GTID 仍可独立返回：本接口做关联，不维护 executed 集合，不去重；回滚结果也不会更新历史 GTID 集合。GTID 事件本身、其中的提交时间或 transaction_length 都不是提交证明。

## 资源限制

默认最多 4096 个事件、10000 个行变化、67108864 编码字节，参数必须为正。外层事件/字节预算包括 GTID、BEGIN、映射、行及结束事件；在相加之前检查预算和 UInt64 物理范围。max_changes 沿用内层规则，UPDATE 的 before/after 一对算一次变化。

既有单事件 16 MiB、每个 ROWS 事件 1024 个变化、单镜像和映射缓存上限继续生效。本批没有增加单事件配额参数，也不把 wire_bytes 当作精确堆内存上限。元数据中的 transaction_length 不驱动分配或跳过，也不与实际区间长度比对。

## 验证与范围

新增 10 项独立 MoonBit 测试，复用既有独立 Python GTID / 事务样本：22 种已分配或匿名前缀分别绑定 CRC32/OFF 行事务；覆盖提交/回滚/空事务/多语句/重复身份、返回快照、未结束输入、前缀和嵌套边界、偏移与 UInt64 边界、94 个坏 GTID body、CRC/坏行/缺失 signedness、精确事件/字节配额及行变化超限、失败后禁止复用。

六组既有真实 MySQL 8.0.43 匿名前缀的元数据仍与官方 mysqlbinlog 预期核对，其绑定后的内层结果与原 TransactionDecoder 的行/提交结果完全一致。原有合成边界测试保留；另有三组 [真实 GTID=ON 日志](../fixtures/gtid-real/README.md)覆盖 9 笔 assigned 绑定和官方行值，原六组捕获保持原样。

GTID 与事务布局依据见 [GTID 事件](gtid-events.md)和 [原事务接口](transactions.md)，生命周期背景见 [MySQL 8.0 GTID Life Cycle](https://dev.mysql.com/doc/refman/8.0/en/replication-gtids-lifecycle.html)。本接口仅支持上述显式事务子集，CLI 另有可选绑定导出，仍没有自动提交/DDL/XA/隐式边界推断、跨文件事务续接、历史连续性验证、exactly-once 投递或实时复制。
