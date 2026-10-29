# CLI 显式事务汇总 JSON Lines v1

`--transactions --schema PATH` 组合文件遍历、外部 schema 绑定和既有 `TransactionDecoder`，汇总显式 BEGIN 到 XID / COMMIT / ROLLBACK 的连续 RBR 区间。调用者必须已知涉及的表是事务型表；当前 TABLE_MAP 无法证明存储引擎及回滚语义。

## 运行

```text
moon run --target native cmd/moonbinlog -- --transactions --schema examples/mysql-8.0-schema.json fixtures/mysql-8.0/crc32-full.binlog
moon run --target native cmd/moonbinlog -- --transactions --include-rows --schema examples/mysql-8.0-schema.json fixtures/mysql-8.0/crc32-full.binlog
moon run --target native cmd/moonbinlog -- --transactions --schema examples/mysql-8.0-schema.json --summary fixtures/mysql-8.0/crc32-minimal.binlog
```

此模式与 `--rows` 互斥，必须指定 `--schema PATH`，自动启用 JSON Lines；可显式添加 `--json`。默认输出计数，增加 `--include-rows` 才在提交对象中附带行值。`--summary` 省略单笔记录和行值，但仍完整绑定、解码和验证，即使同时指定 --include-rows。

--database NAME / --table NAME 按整笔事务选择：任一成功解码的 ROWS 匹配即保留完整区间，包含其他表的计数与导出行；回滚同样按区间中已解码 ROWS 判断。空事务或仅 TABLE_MAP 在启用筛选后不命中；所有输入仍检查，详见[库表筛选](cli-filters.md)。

schema 的 UTF-8/BOM、4 MiB 文件上限和库配额与行模式一致，详见 [schema 配置](schema.md)。每个 TABLE_MAP 都检查配置，整数 signedness 交给行解码器；配置不证明历史列名/符号属性正确，也不推导 DDL。

## 单笔事务记录

每个对象含数字 `schema_version: 1`、字符串 `kind: "transaction"`。只有完整验证提交/回滚边界后才输出，无待定记录。三组固定真实日志都只有一笔提交；CRC32/FULL 的单笔记录是：

```jsonl
{"schema_version":1,"kind":"transaction","status":"committed","start_offset":"236","end_offset":"2454","xid":"26","events":10,"row_events":4,"changes":4,"event_bytes":"2218","tables":[{"database":"moonbinlog_fixture","table":"sample","row_events":4,"changes":4}]}
```

| 字段 | 类型与含义 |
| --- | --- |
| status | 字符串 committed 或 rolled_back |
| start_offset / end_offset | BEGIN 的物理偏移 / 结束事件之后的位置，均为十进制字符串；不使用头中的 next_position 推断范围 |
| xid | 仅提交记录提供：XID 为十进制字符串，QUERY COMMIT 为 null；支持完整 UInt64，不能将其视为 GTID 或全局唯一 ID |
| events | 仅提交记录提供：BEGIN、TABLE_MAP、ROWS 和结束事件的总数，数字 |
| row_events / changes | 仅提交记录提供：ROWS 事件数 / 行变化数，数字；一对 UPDATE 镜像计为一条变化 |
| event_bytes | 仅提交记录提供：区间内所有事件编码字节之和，十进制字符串，包含头与 CRC |
| tables | 仅提交记录提供：按库表名聚合的数组，按该事务首次出现行事件的顺序排列 |
| discarded_changes | 仅回滚记录提供：丢弃的待定变化数，数字，不包含行值或各表信息 |

tables 元素包含字符串 database/table 和数字 row_events/changes。同一库表的新 table_id 或重复 TABLE_MAP 不产生额外表项；没有 ROWS 的表映射不列入，空提交的 tables 为 []。对象键顺序不作为协议保证。

## 导出已提交行变化

`--include-rows` 必须与 `--transactions` 一起使用，重复指定或用于独立 --rows/事件模式均为参数错误。原有不带此选项的输出形状保持不变，schema_version 仍为 1，transaction_summary 也不增加导出字段。

启用后，只有 status=committed 的 transaction 对象增加 row_changes 数组；整个事务仍是一行 JSON，不额外输出顶层 row_change 行。数组按行事件原顺序及事件内变化顺序展开，长度等于 changes；空提交显式提供 []。每个元素沿用[行 JSON 的字段和值类型](cli-rows.md#行记录)，但 transaction_status 固定为 committed：

```json
{
  "schema_version": 1,
  "kind": "row_change",
  "transaction_status": "committed",
  "offset": "400",
  "type": 30,
  "database": "shop",
  "table": "orders",
  "table_id": "108",
  "change_index": 0,
  "operation": "insert",
  "before": null,
  "after": [{"index":0,"name":"id","state":"value","type":"integer","unsigned":true,"value":"18446744073709551615"}]
}
```

此示例只展示 row_changes 元素形状，偏移为示意值。change_index 仍是该 ROWS 事件内从零开始的序号，不是全事务序号；offset 定位原 ROWS，外层 start_offset/end_offset/xid 定位所属事务。UPDATE 的 before/after 保持配对，缺失列/NULL/值、整数与 DECIMAL 精度、hex 字节和浮点 bits 均沿用行模式规则。

渲染逐事件绑定其不可变 TABLE_MAP 快照，不使用提交时已清空或复用的 table_id 缓存。schema 注册表固定为本次读取的配置；同 ID 后续换表不会改写先前输出的库表名或列标签。

ROLLBACK 不附带 row_changes，也不提供被丢弃的行值。未结束、损坏、未知事件、配额或 schema 失败均不导出该笔事务。完整事务对象在内存中渲染成功后才交给 stdout，因此渲染失败也不会输出该笔事务的 JSON 前缀；输出通道失败仍可能导致不完整写入。

回滚只返回范围和丢弃数量，例如以下形状（偏移仅作示意）：

```jsonl
{"schema_version":1,"kind":"transaction","status":"rolled_back","start_offset":"200","end_offset":"600","discarded_changes":2}
```

## 全文件统计

只有正常 EOF 且不存在活动事务时，最后才输出 `kind: "transaction_summary"`、`schema_version: 1` 的对象：

- committed_transactions、rolled_back_transactions：完成的提交 / 回滚笔数。
- committed_row_events、committed_changes：只累计已提交的行事件 / 变化。
- discarded_changes：只累计已完成 ROLLBACK 丢弃的变化。
- events、event_bytes、file_bytes、types：全文件事件统计，含允许的包络；类型和顺序与[事件统计](cli.md)一致。

以上新增计数均为数字。没有事务的有效文件可以成功返回零计数；尚未结束的事务或失败区间不计作回滚，也不会产生最终统计。

## 状态与事件范围

事务内只接受 QUERY（2）、XID（16）、TABLE_MAP（19）和常规 ROWS v2（30/31/32）。QUERY 必须被既有严格边界解析器识别为 BEGIN、COMMIT 或 ROLLBACK，其他 SQL（包括 DDL、SAVEPOINT、COMMIT AND CHAIN）明确失败。缺 BEGIN、嵌套 BEGIN、范围内偏移不连续、行解码错误或 schema 失配均失败。

FDE（15）只允许出现在没有待定事务时，重新创建事务与 schema 映射上下文。活动事务遇到新 FDE 会报未结束事务，不把原状态静默丢弃后继续。

仅在空闲状态，STOP（3）、ROTATE（4）、HEARTBEAT（27）、GTID（33）、ANONYMOUS_GTID（34）、PREVIOUS_GTIDS（35）在默认未开启 --with-gtid 时可作为文件级包络跳过并清空映射。它们的 body 只接受文件层完整性/CRC 检查，不解释语义，也不作为事务身份；活动事务中遇到它们会失败，不能跨包络续接事务。其他未知事件和旧/partial/compressed 行事件立即失败。

语句结束清理两份同作用域映射缓存：事务核心负责行解码，CLI 缓存只提供经过 schema 绑定的 signedness，不重复解码行。每条新语句仍须 TABLE_MAP；提交/回滚清理缓存，任意扫描错误使当前 scanner 失效，不尝试恢复后提交旧数据。

## 配额

使用事务核心固定默认配额：每笔最多 4096 个事件、10000 个变化和 64 MiB 编码字节；事件数及字节包含 BEGIN 和结束事件。每个 ROWS 最多 1024 个变化，默认单镜像/单事件上限 16 MiB，表映射缓存配额仍生效。

CLI 的 --max-event-bytes 控制文件层，但事务核心及其表/行解析目前仍固定最多 16 MiB，所以增大该选项不会扩大事务模式内部上限。--max-file-bytes 仍控制整文件读取，默认 64 MiB；事务配额没有新增 CLI 调整选项。编码字节配额并非精确堆内存限制，事务核心会缓存完整有类型行对象直到边界。

启用 --include-rows 会额外构建整笔事务的 JSON 对象和字符串；重复列标签、hex 及 JSON 转义可能使输出明显大于编码字节数。本批没有分块输出或单独的 JSON 输出字节配额。

## EOF、错误与可信范围

EOF 总是调用 finish。完整 ROWS 后缺 XID/COMMIT 也属于 IncompleteTransaction，退出 1，不输出该笔事务或 transaction_summary。CRC/截断、schema、格式、未知事件、配额或输出错误同样失败；参数错误退出 2。

前面已输出的完成事务记录可能保留，消费方必须检查进程退出码及最后的 transaction_summary，不能将该前缀当成全文件成功。输出通道损坏时也可能写出不完整行。

committed 仅表达本工具在上述已知事务型表前提下验证了受支持的显式区间，不承诺处理任意 MySQL Binlog、隐式或自动提交、XA、DDL、非事务表、GTID 语义、多文件续接、SQL 回放或 exactly-once。有类型提交行结果也可通过[事务库接口](transactions.md)获取，独立 `--rows` 的值仍标记 unconfirmed。

普通完整 JSON 列也沿用该导出协议，value 为 json_text 字符串；SQL NULL、JSON null 和缺失列分别保留。opaque / partial JSON 明确失败，不导出该笔待定事务，示例见 [JSON 字段](json-values.md)。

## 验证

```text
moon test --target native --filter "CLI transactions*"
moon test --target native --filter "CLI committed*"
moon build --target native
python scripts/test_transactions_cli.py
```

事务及行导出合计新增 13 项 MoonBit 测试，子进程场景从 50 个扩展为 72 个。三组真实 MySQL 8.0.43 捕获核对官方 mysqlbinlog 的 BEGIN/XID 位置、XID 及导出行的 300 个列位置；合成场景覆盖空事务、COMMIT/ROLLBACK、高位 XID、多笔事务、多表同 ID 重用、多行序号、BOM/Unicode/转义标签、schema 错误、活动事务包络、有效 CRC 的语义错误、事件/变化配额及完整/截断 EOF。原有事件及行模式回归独立保留，脚本核对固定输入未改变，不启动数据库。

可选 `--with-gtid` 使用严格的 GTID 前缀绑定器，支持现有行导出/筛选/摘要，在完成事务中附加 gtid 和包含前缀的 gtid_span。默认模式及本页原有 BEGIN-based 字段保持一致，完整规则见 [GTID 事务导出](cli-gtid-transactions.md)。

单文件事务导出可加 `--stream` 逐事件读取；支持 --with-gtid、--include-rows、筛选和摘要，保留单笔事务的缓冲及 EOF 检查，详见 [逐事件读取](cli-stream.md)。
