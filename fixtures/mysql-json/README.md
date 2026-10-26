# MySQL 8.0.43 JSON 实际捕获

2026-10-26 在 Windows 独立临时 MySQL 8.0.43 实例上运行本目录 schema.sql、workload.sql，得到 CRC32/FULL、CRC32/MINIMAL、OFF/FULL 三组日志及官方 `mysqlbinlog --base64-output=DECODE-ROWS -vv` 输出。捕获不连接已有业务数据库。

两列为 signed INT 主键 id、可空 JSON text_value。场景包含嵌套对象/数组、中文、布尔、null、double、UInt64 最大值和 Int64 最小值；插入三行，更新一行、删除两行后提交，再回滚一笔插入。关闭 binlog_row_value_options，生成完整 JSON 值，未覆盖 partial JSON diff 或 opaque。

每组日志有 12 个事件、3 个 ROWS、6 条变化、7 个镜像；三组共 42 个列位置。MINIMAL 保留缺失槽位；SQL NULL 与 JSON null 独立比较。回滚 id=99 不进入 binlog，最终只剩 id=2 的 SQL NULL。原有 fixtures/mysql-8.0 的 20 列样本不受影响。

manifest.json 记录工具版本、设置、SQL/原始日志/官方输出 SHA-256、文件大小和最终行。时间戳及事务 ID 会随重新捕获改变，验证脚本校验的是仓库固定文件，无需本地数据库：

```sh
python scripts/verify_json_fixtures.py --check
python scripts/test_json_cli.py
```

验证脚本独立检查 CRC32、事件物理位置和官方行值，并生成根目录 mysql_json_fixture_test.mbt 的原始字节及预期镜像。Python JSON 解析保留完整整数；MoonBit 与 CLI 分别对照这些预期值，不要求对象空白和浮点文本拼写一致。

如需重新捕获，先准备 MySQL 8.0 工具，再显式运行：

```powershell
python scripts/capture_mysql_fixtures.py --mysql-bin 'C:/Program Files/MySQL/MySQL Server 8.0/bin' --output-dir fixtures/mysql-json
python scripts/verify_json_fixtures.py --write
moon fmt
```

捕获器仅操作本次创建的临时实例，完成后关闭并清理该实例；不在常规 CI 中启动。SQL 和生成的测试数据独立编写，按仓库 Apache-2.0 许可证提供，未分发 MySQL 程序或源代码。使用边界见 [JSON 字段说明](../../docs/json-values.md)。
