# 单文件逐事件读取

```sh
moon run --target native cmd/moonbinlog -- --stream --summary mysql-bin.000001
moon run --target native cmd/moonbinlog -- --stream --json --max-file-bytes 1073741824 mysql-bin.000001
moon run --target native cmd/moonbinlog -- --stream --decode-gtid --decode-previous-gtids mysql-bin.000001
moon run --target native cmd/moonbinlog -- --stream --rows --schema examples/mysql-8.0-schema.json --database moonbinlog_fixture --table sample mysql-bin.000001
moon run --target native cmd/moonbinlog -- --stream --transactions --schema examples/mysql-8.0-schema.json --with-gtid --include-rows mysql-bin.000001
```

`--stream` 用于单文件事件浏览、行或事务导出。CLI 不再预先把整个输入文件读入一个 Bytes，而是先读文件标识，再读每个 19 字节事件头和它声明的完整事件，校验后输出。可与 --json、--summary、--decode-rotate、--decode-previous-gtids 和 --decode-gtid 组合，输出字段、统计及退出码与默认事件模式一致。

行导出使用 `--stream --rows --schema PATH`，复用原 RowScanner 和行报告；可组合 --database、--table、--summary、--json 及文件/事件预算。JSON Lines 字段、物理偏移、行计数、筛选计数、SQL NULL/Absent 和字节值与整文件行模式一致。schema 仍独立整份读取，上限 4 MiB，并保留 schema 解析器自身预算。

行输出保持 `transaction_status: "unconfirmed"`：完整行事件后 EOF 不等于已提交，不推断事务。筛选只影响输出与 selected 计数；未选中表的 TABLE_MAP、schema 和行内容仍须校验。未知事件仍按原行模式拒绝。事件详情开关只用于事件浏览，不能与 --rows 组合。

事务导出使用 `--stream --transactions --schema PATH`，可组合 --with-gtid、--include-rows、库表筛选、摘要和字节预算，复用原 TransactionScanner。仅在显式 BEGIN 到 XID/COMMIT/ROLLBACK 完整结束后输出结果；回滚没有 row_changes。GTID 仍要求紧邻前缀，不做重复身份去重。筛选选择整笔事务，未命中仍完整验证，EOF 有未结束事务或孤立前缀时失败。

事务扫描器仍保留一笔待完成事务的行快照，直到提交输出或回滚丢弃；逐事件读取并不会把一笔事务拆成可提前确认的小批。沿用原扫描器配额：每笔最多 4096 事件、10000 变化、64 MiB wire bytes；绑定模式计入 GTID 前缀。现有事务核心解析仍有默认 16 MiB 单事件限制，提高 CLI --max-event-bytes 只放宽外层读取，不放宽核心解析限制。配额不是精确堆内存预算。

目前不支持 --chain、--schema-template 或其相关选项；草稿和链仍整文件读取。不扩大自动提交、DDL、XA 或跨文件事务的支持范围。

## 大小限制和资源

文件默认上限仍为 67108864 字节（64 MiB）。较大文件需要显式提高 --max-file-bytes，当前最大 2147483647 字节；这批没有增加超过该上限的文件支持。单事件默认上限为 16777216 字节，可通过 --max-event-bytes 调整；事件声明的大小会在分配 body 前与事件上限和文件剩余字节核对。

事件完整内容仍须驻留内存以便检查 CRC 和解析，可产生头部、body、组合事件及 JSON 输出的临时副本。内存占用与当前事件大小、选择的详情输出和运行时分配有关，行模式还持有 schema、表映射缓存及当前已解码行/JSON 值；不积累整个文件的行输出。事务模式另持有待完成事务及最近完成结果的行快照，输出 JSON 时可能产生整笔事务的临时结构和字符串。没有精确堆内存上限或性能指标；不能把 --stream 理解为固定几 KB 内存，也没有独立输出字节配额。

只接受普通文件。打开后记录文件大小，读取中缩短会失败，处理完原始大小后检查额外字节以发现增长；同大小原地修改和读取时的其他竞态不能由此完全检测。请使用已关闭或稳定复制的日志；这不是操作系统级原子快照，也不是持续追踪正在写入的日志。

无论是否 --summary，均检查文件标识、首个 FDE、后续格式切换及 CRC32/OFF，开启的详情选项也会解析并校验相应事件 body，行及事务模式会校验 TABLE_MAP/schema 及 ROWS，事务模式还校验边界与 EOF 状态。错误退出码为 1，不输出成功摘要；明细模式可能已经输出之前完整的事件。文件/事件上限错误同样不会输出成功摘要。参数错误退出码为 2。

## 库接口

`BinlogEventStream::new(signature, max_event_size~)` 只验证文件标识的前四字节，不自动消费附带的后续数据；`feed(data)` 接受**一个完整事件**，返回与 BinlogFileReader 相同的 BinlogFileEvent；声明事件以外的输入不消费。调用者可先用 EventHeader::parse 检查 19 字节头，再按预算读取完整事件。该接口不缓存不完整的输入块，也不操作文件系统。

position() 返回下一事件物理位置，format() 返回当前 FDE。每个返回事件的视图保留其输入，调用方持有事件时该事件数据也会保留。新 FDE 正常切换格式；事件处理或 EOF 校验错误会清除上下文并永久失败。成功 finish() 要求至少一个 FDE、可重复调用；之后 feed 返回 StreamAlreadyFinished，并保留最终格式上下文。实际文件 EOF、增长和读取错误由调用方检查。

## 验证与范围

新增 6 项独立 MoonBit 测试：九组真实文件与内存遍历器逐事件比较、输出快照、FDE/CRC/OFF、签名和首 FDE、逐字节事件截断、错误后停止及参数互斥。

`scripts/test_stream_cli.py` 新增 449 个端到端场景，对九组真实日志和现有事件协议逐项比较，覆盖逐字节文件截断、坏 CRC、FDE 切换、声明超大但文件不足、详细输出及配额。另生成 68158801 字节的临时文件：默认上限拒绝，提高文件上限后流式与原模式摘要一致；单事件超过 16 MiB 时也验证提高事件预算。临时大文件不进入仓库，原九组捕获保持不变。CI 不测内存峰值或吞吐量。

`scripts/test_stream_rows_cli.py` 增加 264 个场景，逐字节比较九组捕获的行输出、摘要、筛选及预算；覆盖 schema/UTF-8/BOM、坏 CRC、语义错误、缺映射、截断、未命中筛选仍报错、FDE 重置和 CRC32/OFF 切换。另构造 68161434 字节文件，验证默认拒绝、提高文件预算后行输出和摘要与整文件模式一致。大文件由已有真实事件与合成包络组成，不代表新的真实 MySQL 捕获。

`scripts/test_stream_transactions_cli.py` 增加 536 个场景，对照九组捕获的普通/GTID 事务、提交行、过滤、摘要及预算。覆盖回滚丢弃、重复/匿名身份、空事务、孤立前缀、未结束事务、结尾逐字节截断、坏 CRC/GTID、未命中筛选仍验证 schema、事件数配额与 CRC32/OFF 切换；68161434 字节混合输入验证提高文件上限后的结果一致。原九组捕获未变；没有内存峰值或吞吐结论。

当前覆盖单文件事件浏览、未确认行导出及显式事务导出；尚未接入多文件链或 schema 草稿，也不支持超过现有 2 GiB−1 文件上限、实时订阅或自动跟随轮转。
