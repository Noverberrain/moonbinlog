# GTID 事件样本

`scripts/generate_gtid_fixtures.py` 根据 MySQL 8.0 布局，用 Python struct/zlib 独立生成根目录 `gtid_fixture_test.mbt` 和本目录 manifest。包含 22 种有效内容的 CRC32/OFF 共 44 个事件、94 个无效 body，另有坏 CRC、缺失/错误/按类型区分的 FDE 辅助样本。

有效内容涵盖 assigned/anonymous 标识、最大合法 GNO、任意 SID/flags、逻辑时钟位值、各扩展阶段、提交时间/版本的共同和分别编码、packed integer 宽度及非最短编码、零值与缺失值、UInt64 ticket。无效 body 覆盖短基础字段、GNO 范围、未知逻辑类型、NULL/保留长度标记、扩展字段截断和尾部垃圾。

六组原始 MySQL 8.0.43 捕获和官方输出仍从 `fixtures/mysql-8.0`、`fixtures/mysql-json` 读取，SHA-256 保持一致；生成器从官方文本提取匿名事件位置、时钟、提交时间、事务长度和版本。没有复制或修改原始捕获，也没有新增真实 assigned GTID 样本。

可选 `--mysqlbinlog PATH` 在临时目录创建合成文件，用官方程序验证 CRC 并比较 assigned/anonymous 标识、逻辑时钟及可用时间/长度/版本。常规 CI 不要求安装 MySQL 或启动服务。详细支持边界及固定参考源码见 [GTID 事件文档](../../docs/gtid-events.md)。
