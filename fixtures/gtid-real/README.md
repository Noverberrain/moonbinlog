# 真实 MySQL GTID=ON 捕获

2026-10-29 使用本机 MySQL Community Server 8.0.43，在脚本新建的临时数据目录、随机 loopback 端口中采集。没有连接已有数据库服务；采集完成后正常关闭并清理临时实例。固定 binlog、官方 mysqlbinlog 文本和 SQL 均保存在本目录。

| 文件组 | Checksum | 行镜像 | assigned GTID | 文件开始前历史 |
| --- | --- | --- | --- | --- |
| crc32-full | CRC32 | FULL | 2、3、4 | 1 |
| crc32-minimal | CRC32 | MINIMAL | 5、6、7 | 1～4 |
| off-full | OFF | FULL | 8、9、10 | 1～7 |

所有标识共享 manifest.json 中记录的临时 server_uuid。启动配置为 GTID_MODE=ON、ENFORCE_GTID_CONSISTENCY=ON、ROW、binlog_row_metadata=FULL，关闭事务压缩和 partial JSON。seed.sql 先写入一笔真实事务建立非空历史；建表及各轮清理使用 sql_log_bin=0，不在捕获内。这些文件只供离线解析对照，不是完整的回放或恢复输入。

每个文件包含 18 个事件：FDE、非空 PREVIOUS_GTIDS、三组 GTID → BEGIN → TABLE_MAP → ROWS → XID，以及最后的 ROTATE。三笔事务分别插入三行、更新一行、删除两行；中间另执行 id=99 的回滚插入，没有进入日志或消耗本次捕获的 GTID。最终数据库只剩 id=2，JSON 列为 SQL NULL。

JSON 包含 UInt64/Int64 极值、Unicode、数组和 JSON null；共 9 笔 assigned 事务、21 个行镜像、42 个官方列位置。manifest 记录版本、SQL/seed/原始日志/官方输出 SHA-256、文件大小、最终行以及每轮前后的 @@GLOBAL.gtid_executed 快照。原有六组匿名捕获保持原样。

常规验证无需启动 MySQL：

```sh
python scripts/verify_assigned_gtid_fixtures.py --check
python scripts/test_assigned_gtid_cli.py
```

验证器用独立 struct/zlib 逻辑核对 CRC、物理位置和非空 SID/区间，再从官方文本提取 GTID_NEXT、逻辑时钟、提交时间、事务长度、版本、XID、行值，与服务器历史快照交叉核对，生成 mysql_gtid_fixture_test.mbt。MoonBit 测试对照历史、事件字段、绑定范围及行值；CLI 对照事件详情、绑定导出、行/筛选/摘要、自动 schema 和错误隔离。

重采集会改变 UUID、时间戳、XID、摘要和生成数据，应作为显式样本更新审查：

```powershell
python scripts/capture_mysql_fixtures.py --mysql-bin 'C:/Program Files/MySQL/MySQL Server 8.0/bin' --output-dir fixtures/gtid-real --gtid-mode ON
python scripts/verify_assigned_gtid_fixtures.py --write
moon fmt
```

捕获器默认仍为 GTID OFF；开启 ON 时拒绝覆盖原有 mysql-8.0 / mysql-json 目标。原始 .binlog 和官方 .mysqlbinlog.txt 按 Git 二进制保存，避免换行转换改变摘要。CI 只使用固定样本，不调用数据库或官方程序。没有分发 MySQL 程序或源代码；项目 SQL、测试和生成器按 Apache-2.0 提供。

这些样本补上 assigned GTID 的真实事务与非空历史证据，不证明任意 MySQL 版本、任意历史集合、组提交 ticket 边界、跨文件续接、去重、实时复制或 exactly-once。接口范围见 [GTID 事件](../../docs/gtid-events.md)、[事务绑定](../../docs/gtid-transactions.md)和 [CLI 导出](../../docs/cli-gtid-transactions.md)。
