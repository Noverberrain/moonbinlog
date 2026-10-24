# 显式边界的事务型 RBR 汇总

`TransactionDecoder` 支持调用者已知为事务型表的、连续的显式 BEGIN 到 XID/COMMIT/ROLLBACK 事件区间。它不是完整 Binlog 文件解析器，也不能从当前 TABLE_MAP 判断存储引擎是否支持回滚。

离线命令可使用 `--transactions --schema PATH` 组合本接口与文件遍历器，输出完成事务的计数和各表汇总；文件级包络允许范围与输出协议见[事务 CLI](cli-transactions.md)。本页描述库解码器本身，feed 的支持范围保持不变。

## 边界解析

`TransactionBoundary::parse` 复用格式描述的 CRC32/OFF 策略：

- QUERY（2）必须采用十三字节 post-header，验证 status/database 外层长度、数据库名 NUL 终止及 error_code 为零。status 变量内容不解释，数据库名不做字符集转换。
- 只识别 ASCII BEGIN、COMMIT、ROLLBACK，不区分大小写，允许两端 ASCII 空白和最多一个末尾分号。不搜索 SQL 子串，不接受多语句、注释、WORK、AND CHAIN、START TRANSACTION 或 SAVEPOINT。
- XID（16）要求零 post-header 和恰好八字节 body，以小端 UInt64 保存，支持高位及零。XID 不等于 GTID，也不作为全局唯一标识。

返回 `TransactionBoundary` 的 header 和 `TransactionAction`。它只解析控制信息，不维护事务状态；普通业务 QUERY、失败语句及错误布局明确报错。

## 流式状态

使用已验证的 `FormatDescription` 创建 `TransactionDecoder`，逐事件调用 `feed`。`TransactionStep.header.event_size` 是消费长度，输入可以跟随后续事件字节；只有当前事件参与校验与处理。`integer_unsigned` 只在 ROWS 事件使用，仍须由调用者按该 table_id 提供。

支持事件为 QUERY、XID、TABLE_MAP（19）及普通 ROWS v2（30/31/32）。空闲状态必须从显式 BEGIN 开始；活动状态内每个事件的真实物理起点必须等于上一事件结束位置。重叠、间隙、重复偏移和嵌套 BEGIN 都是错误，不根据公共头 next_position 推断连续性。

| 输入/状态 | 结果 |
| --- | --- |
| BEGIN | 开始新事务，outcome 为 None |
| TABLE_MAP | 建立当前语句的表映射，outcome 为 None |
| ROWS | 缓存完整行事件，outcome 为 None |
| XID/COMMIT | 返回 CommittedTransaction 并清理当前状态 |
| ROLLBACK | 丢弃行事件，仅返回 RolledBack 的起止位置和丢弃数量 |
| 非法顺序、未知事件或解析错误 | 丢弃整个待定事务和映射，抛出结构化错误 |

ROWS 的 STMT_END_F 只清理语句级表映射，不提交事务。一份事务可以包含多条语句；下一条语句必须重新提供 TABLE_MAP。提交结果保留每个 ROWS 事件的表定义快照，后续事务不会修改已经返回的结果。

## 提交结果与 EOF

`CommittedTransaction` 包含起点 `start_offset`、结束事件之后的 `end_offset`、可选 XID、行事件列表、原始事件总数、行变化数及 wire_bytes。QUERY COMMIT 没有 XID。空事务可返回零个行事件；UPDATE 的一对 before/after 计为一个变化。

在 EOF 必须调用 `finish()`。未结束事务会被丢弃并返回 `IncompleteTransaction`，绝不自动提交。错误后也不会因后续 COMMIT 恢复此前丢弃的数据，恢复必须从新的明确 BEGIN 开始。

每次错误都会清空活动事务，不能将 unknown event 当成可安全跳过的内容。若调用者过滤事务内事件，物理偏移检查会拒绝缺口；调用者仍负责提供完整且正确的文件字节。新文件或格式描述需要新建解码器。

## 上限和范围

默认最多 4096 个事件、10000 个行变化、64 MiB 编码字节，三项配置必须为正。事件数/字节包含 BEGIN、TABLE_MAP 和结束事件，事务字节配额以 UInt64 检查后相加，避免溢出。配额失败不会输出部分提交。

既有单事件 16 MiB、每个 ROWS 事件 1024 个变化、单镜像 16 MiB 和表映射缓存上限继续生效。编码字节配额不等于精确堆内存上限，解码后的对象和元数据有额外占用。

当前不处理 GTID/anonymous GTID、XA/两阶段提交、压缩事务、DDL/隐式提交、自动提交推断、混合或 statement 格式、SAVEPOINT 或非事务表的回滚语义。事务开始前的 GTID 等文件级元数据也不由 feed 自动跳过；调用者应明确选择受支持区间，不应宣称可以解析任意完整日志。没有执行数据库写入或保证 exactly-once。

## 验证与依据

Python 独立构造 36 个控制事件、格式变体及连续 RBR 流。完整流重写 next_position 并重新计算 CRC，覆盖 XID/QUERY 提交、回滚、多语句、多事务、EOF、OFF、配额和错误恢复。测试还验证未提交状态不输出结果、快照独立、所有控制事件截断点，以及不将业务 SQL 中的 COMMIT 当作边界。

协议依据固定在 MySQL commit `9fc8d60003b4eee32767c1e30942f222c3508c31` 的 [QUERY post-header 和 status/database/query 布局](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/libbinlogevents/include/statement_events.h) 与 [XID 事件定义](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/libbinlogevents/include/control_events.h)。实现与合成样本独立编写；另有[三组真实 MySQL 8.0.43 日志及官方工具对照](mysql-integration.md)，Java 客户端差分尚未完成。
