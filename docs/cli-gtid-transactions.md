# CLI GTID 事务导出

```sh
moon run --target native cmd/moonbinlog -- --transactions --with-gtid --schema examples/mysql-8.0-schema.json mysql-bin.000001
moon run --target native cmd/moonbinlog -- --transactions --with-gtid --include-rows --schema examples/mysql-8.0-schema.json --table sample mysql-bin.000001
moon run --target native cmd/moonbinlog -- --transactions --with-gtid --summary --schema examples/mysql-8.0-schema.json mysql-bin.000001
```

`--with-gtid` 显式开启 GTID 前缀绑定，必须与 --transactions 和 --schema 一起使用，可组合 --include-rows、--summary、--json、库表筛选和单文件字节预算。它与 --rows、schema 草稿、多文件链及 --decode-gtid / --decode-previous-gtids / --decode-rotate 事件详情选项互斥；重复选项或无效组合退出码为 2。

没有该选项时，原事务模式仍允许空闲时跳过 GTID 包络，不校验或关联其 body，输出协议保持原样。--decode-gtid 只是事件浏览；--with-gtid 才会要求每笔显式事务前有合法 GTID/匿名事件，两者不混用。

## 结果协议

每个完成的 transaction 保留既有 schema_version=1、status、start_offset、end_offset，以及提交/回滚特有字段。增加：

| 新字段 | 含义 |
| --- | --- |
| gtid | 与 [GTID 事件详情](cli-gtid.md) 相同的完整对象，含 identity、sid/gno、时钟及可选扩展 |
| gtid_span.start_offset | GTID 事件的真实物理起点，十进制字符串 |
| gtid_span.end_offset | 提交/回滚结束事件之后的位置，十进制字符串 |
| gtid_span.events | 包含 GTID 前缀的区间事件数 |
| gtid_span.event_bytes | 包含 GTID 前缀的编码字节数，十进制字符串 |

原 start_offset 仍指向 BEGIN，原 events / event_bytes 仍统计 BEGIN 到结束事件；gtid_span 的终点与原 end_offset 相同，提交时事件数比原 events 多 1，字节数多出 GTID 事件大小。回滚保留原 discarded_changes，并有完整 gtid_span，但不新增原协议没有的提交计数或行值字段。

匿名身份 gtid.identity 为 null，仍保留原始 SID、零 GNO 和其他字段。UInt64 值继续使用十进制字符串，扩展缺失为 null、编码零值独立表示；不会把匿名事件转成可用于去重的 GTID。

--include-rows 只为提交结果附带完整 row_changes，仍使用每个行事件保存的 TABLE_MAP 快照绑定列名/符号。回滚结果不包含 row_changes 或待定行值。整个报告构造成功后才写 stdout。

## 输入、筛选和 EOF

使用 [GtidTransactionDecoder](gtid-transactions.md) 验证紧邻的 `GTID / Anonymous → BEGIN → TABLE_MAP / ROWS v2 → XID / COMMIT / ROLLBACK`。缺失前缀、第二份前缀覆盖未结束事务、非相邻偏移、嵌套 BEGIN 或不支持的 SQL/事件均失败。GTID 中的 transaction_length、时间戳和逻辑时钟不用于跳过事件或证明提交。

库表筛选沿用整笔事务规则：任一 ROWS 命中，保留整笔提交/回滚及其 GTID；提交行导出保留其中其他表。空事务、只有 TABLE_MAP 的区间不命中活动筛选。未选中输入仍完整验证 GTID、schema、行、边界、CRC 和配额，不允许筛选掩盖错误。

--summary 不输出明细，仍执行所有绑定和 EOF 校验；最终 transaction_summary 与默认事务模式使用相同全文件/已选事务计数，不增加新的汇总字段。GTID 包络原本已计入全文件 events，开启绑定不会重复计数。

空闲时仍允许 framing/CRC 已验证的 STOP、ROTATE、HEARTBEAT、PREVIOUS_GTIDS 包络，body 保持不透明；GTID/匿名事件改为严格解析。新 FDE 只有在没有待定前缀/事务时才能重建上下文。仅有 GTID、尚无 BEGIN 时，EOF 或 FDE 切换同样失败；活动区间内不跳过包络。

失败退出码为 1，不输出失败事务或成功摘要，之前完整的事务可能已输出。schema/行/GTID/EOF 或格式重建错误都会清理当前关联，开启绑定的扫描器之后永久返回 GtidTransactionFailed；默认扫描器原恢复规则保持兼容。CLI 在第一次错误时直接退出。

## 资源和限制

默认每笔最多 4096 个事件、10000 个变化、67108864 编码字节；开启绑定后事件/字节预算包含 GTID。单事件和行/镜像/表缓存上限继续使用原事务核心的固定限制，--max-event-bytes 调整文件遍历器上限不会解除核心的 16 MiB 单事件限制。--max-file-bytes 仍限制整个输入文件，schema 文件仍有原字节上限；没有新增事务预算参数或独立输出字节预算。

只支持单文件、调用方已知为事务型表的显式 RBR 子集。重复 assigned GTID 可以分别返回，不做去重或更新历史集合；回滚的关联也不会声明 GTID 已执行。没有新增自动提交/DDL/XA 推断、跨文件事务续接、历史连续性证明、断点恢复、exactly-once 投递或实时复制。

## 验证

新增 7 项独立 MoonBit 测试，覆盖参数、六组真实事务和原报告/行快照的一致性、assigned 提交/anonymous 回滚、筛选、空事务、schema/EOF/格式错误后禁止复用、含前缀的事件/字节/变化配额，以及成功事务之间的格式切换。

`scripts/test_gtid_transactions_cli.py` 新增 568 个端到端场景：六组真实捕获的完整/行导出/筛选/摘要对照，22 种合成前缀的 CRC32/OFF 事务绑定，94 个坏 GTID body 的默认兼容和明细/摘要失败，缺前缀/重复前缀/孤立前缀/未提交行/FDE/未知事件/SQL、回滚不导出行值、重复身份不去重、之前成功事务后的 EOF 错误、未选中缺 schema、预算/CRC/参数组合。原始六组捕获保持原样，边界场景继续使用合成数据，另有三组 [真实 assigned GTID 捕获](../fixtures/gtid-real/README.md)的 72 个 CLI 对照场景。

脚本纳入统一 CI，十二组 CLI 合计 2200 个场景。字段和底层依据见 [GTID 事件](gtid-events.md)、[事务绑定库](gtid-transactions.md)和 [原事务 CLI](cli-transactions.md)。
