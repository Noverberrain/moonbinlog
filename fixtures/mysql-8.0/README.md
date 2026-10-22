# MySQL 8.0.43 真实 Binlog 样本

这三份日志由本机 MySQL Community Server 8.0.43 根据本目录的 `schema.sql` 和 `workload.sql` 实际生成，没有手工重写事件、时间戳、偏移或校验和。

| 文件前缀 | checksum | row image | row metadata |
| --- | --- | --- | --- |
| crc32-full | CRC32 | FULL | FULL |
| crc32-minimal | CRC32 | MINIMAL | FULL |
| off-full | NONE | FULL | FULL |

每组文件包含原始 `.binlog` 和官方 `mysqlbinlog --verify-binlog-checksum --base64-output=DECODE-ROWS --verbose --verbose` 的原始标准输出 `.mysqlbinlog.txt`。输出中含 MySQL 原样打印的二进制字段字节及本地时区文字，并非严格 UTF-8；两个文件都按二进制保存在 Git 中以保持 SHA-256。

`manifest.json` 记录服务端/工具版本、SQL 文件哈希、每组文件大小、原始文件和官方输出的哈希，以及事务执行后查询到的数据库状态。schema、SQL 工作负载和数据均为本项目编写的专用测试内容，不含业务库数据。

工作负载包含两个 INSERT、一个 UPDATE、一个 DELETE，均在同一显式 InnoDB 事务提交；随后执行一个单独回滚的 INSERT。最终只保留 id=2，其余字段为 NULL。纯 InnoDB 回滚未产生记录该行变化的事务，本样本不包含人造 ROLLBACK 事件。

三份文件均保留 FDE、Previous-GTIDs、Anonymous_GTID 和结尾 ROTATE 等真实文件级事件。GTID 模式为 OFF 仍会出现 Anonymous_GTID；测试只在事务区间之外处理这些特定样本的封装事件，不表示库已经实现 GTID 语义。

## 离线校验

```text
python scripts/verify_mysql_fixtures.py --check
moon test --target native --filter "real MySQL*"
```

校验脚本独立检查文件/SQL 摘要、事件边界、zlib CRC32 和官方工具记录的事件偏移，将官方输出的 15 个行镜像转为逐列期望值。`mysql_fixture_test.mbt` 是原始文件字节及这些期望值的可重建副本，普通 MoonBit 测试无需安装或启动 MySQL。

```text
python scripts/verify_mysql_fixtures.py --write
moon fmt
```

## 重新采集

在仓库根目录执行，Windows 示例：

```powershell
python scripts/capture_mysql_fixtures.py --mysql-bin 'C:\Program Files\MySQL\MySQL Server 8.0\bin'
python scripts/verify_mysql_fixtures.py --write
moon fmt
moon test --target native --filter 'real MySQL*'
```

采集器通过 `--no-defaults` 使用独立临时数据目录、临时本地端口与关闭的 MySQL X Plugin，不连接现有服务。它初始化一个空密码 root 的临时实例，仅绑定 127.0.0.1，在本机隔离开发环境中运行；成功后关闭实例并删除该临时目录，失败保留诊断目录。临时目录位于系统临时目录下的 `moonbinlog-integration/`。不要向该实例写入业务数据。

重新采集会替换已提交的三份日志、官方输出及 manifest。真实时间戳、事务 ID 等会变化，不能用重新运行服务端来复现相同字节；回归复现依赖仓库中固定的原始文件与哈希。当前运行验证仅覆盖 Windows 上的 8.0.43，采集脚本的其他系统分支尚未实际运行。

完整对照结果和支持边界见 [真实 MySQL 集成验证](../../docs/mysql-integration.md)。
