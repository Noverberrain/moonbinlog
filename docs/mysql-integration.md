# 真实 MySQL 集成与官方工具对照

2026-10-23 使用本机 MySQL Community Server **8.0.43 / Windows x86_64** 运行独立临时实例，生成三组真实日志；用同版本官方 `mysqlbinlog` 校验与解码，再与 MoonBinlog 的文件、行事件及事务结果比较。没有连接或改动已安装的 MySQL 服务及其数据库。

## 本批验证结果

| 配置 | 原始日志大小 | 事件数 | 行变化 | 对照镜像 / 字段数 |
| --- | --- | --- | --- | --- |
| CRC32 + FULL | 2499 bytes | 14 | 4 | 5 / 100 |
| CRC32 + MINIMAL | 2246 bytes | 14 | 4 | 5 / 100 |
| OFF + FULL | 2447 bytes | 14 | 4 | 5 / 100 |

所有事件边界与官方工具的 `# at` 位置一致。三组样本均由文件遍历器通过完整性校验，受支持的 BEGIN 到 XID 连续区间由事务解码器汇总为一个提交事务：10 个事务事件、4 个 ROWS 事件、4 个行变化。

每个 ROWS 结果中的 20 列按官方工具的实际输出逐字段比较，涵盖：

- INT、TINYINT、SMALLINT、MEDIUMINT、BIGINT UNSIGNED，包括负数和 UInt64 最大值。
- UTF-8 VARCHAR、CHAR、BLOB 与 VARBINARY，包括 NUL 和 0xFF；比较原始字节，不进行库内字符集推断。
- DECIMAL(20,6) 的大负数与 0.000001，不经过浮点转换。
- DATE、YEAR、DATETIME(6)、负 TIME(6)、TIMESTAMP(6)，会话时区显式设为 UTC。
- FLOAT、DOUBLE、BIT(9)、ENUM 索引、SET 掩码。
- 完整 NULL 镜像、稀疏镜像，以及 UPDATE 前后与 DELETE 镜像。

对照器使用本项目固定 schema 解释官方显示的字段，整数符号属性仍由调用者提供。官方工具可能同时显示一个整数的 signed/unsigned 解释，比较时选择 schema 指定的解释；不会从 TABLE_MAP 自动推导完整 SQL schema。官方显示的字符串按原始字节和转义规则转换后再比较。

## MINIMAL 与回滚的实际行为

该版本在 MINIMAL 模式下，第二个仅写 id 的 INSERT 没有记录其余 19 列。这些列在数据库最终为 NULL，但日志镜像里是缺失，因此 MoonBinlog 返回 `Absent`；FULL 模式对应位置为 `Null`。UPDATE 的 before 镜像只含主键，after 只含三个被更新的列；DELETE 只含主键。这些结果均与官方解码输出一致。

单独回滚的 InnoDB INSERT 没有出现在这三份提交日志中，最终数据库只保留 id=2。本批没有把这种实际行为描述为“解析到了真实 ROLLBACK 事件”；显式 ROLLBACK 控制事件的处理继续由原有协议构造样本覆盖。

GTID 模式 OFF 的真实文件仍包含 Anonymous_GTID。集成测试仅在 BEGIN 之前或 XID 之后识别并越过这份固定样本的文件级封装事件，事务内部没有过滤事件。额外测试确认将 Anonymous_GTID 直接交给 `TransactionDecoder` 仍会明确报错，库的 GTID 支持范围没有扩大。

## 可复现验证

原始文件、采集 SQL、完整官方输出和摘要清单保存在 [fixtures/mysql-8.0](../fixtures/mysql-8.0/README.md)。两类流程分开执行：

1. **离线回归**：运行 `python scripts/verify_mysql_fixtures.py --check` 和 `moon test --target native --filter 'real MySQL*'`。不需要 MySQL、管理员权限或数据库凭据。
2. **重新采集**：运行采集器启动专用临时 MySQL 实例，再用校验器 `--write` 更新测试副本。需要本地 MySQL 8.0 可执行文件，命令和目录清理规则见样本 README。

普通回归同时检查原始文件哈希、SQL 哈希、官方输出哈希、所有 CRC、官方事件偏移以及 300 个列位置的实际值。还覆盖真实 ROWS 事件被篡改后的 CRC 失败和结尾 ROTATE 被截断的错误。生成的测试字节不改变原始日志。

## 范围与后续

这是一组真实服务端产生的集成回归，不代表所有 MySQL 8.0 版本或所有类型组合均已验证。当前未验证真实 GTID/XA/DDL/隐式事务、压缩/加密日志、其他 row metadata 配置、NOBLOB、额外字符集、超大事务和性能。本批没有 Java 客户端差分测试。

底层解析实现和公共 API 无需改动即可通过这批样本。后续已提供[最小离线 CLI](cli.md)，可以直接读取文件并查看事件列表与统计。

采集与对照命令参考 MySQL 官方文档：[初始化独立数据目录](https://dev.mysql.com/doc/refman/8.0/en/data-directory-initialization.html)、[二进制日志选项及 row image/checksum](https://dev.mysql.com/doc/refman/8.0/en/replication-options-binary-log.html)、[mysqlbinlog 行事件显示](https://dev.mysql.com/doc/refman/8.0/en/mysqlbinlog-row-events.html)。

2026-10-29 新增三组 [GTID=ON 捕获](../fixtures/gtid-real/README.md)，覆盖 9 笔 assigned 事务、非空历史集合、JSON 行值及 CLI 绑定导出；本页原有三组样本和官方对照不变。
