# PREVIOUS_GTIDS 样本

`scripts/generate_previous_gtids_fixtures.py` 使用 Python struct/zlib 独立构造 10 个有效事件（五种集合 × CRC32/OFF）、25 个无效 body，以及坏 CRC、错误/缺失 post-header 辅助输入，生成根目录 `previous_gtids_fixture_test.mbt`。manifest 记录集合预期值和事件摘要。

有效集合覆盖空集合、单 GNO、多 SID、多区间、超过 UInt32 的端点、最大合法 GNO、原始 SID 字节及非规范条目顺序。无效 body 覆盖短计数、巨量计数、缺失 SID/区间、尾部垃圾及非法/相邻/重叠/乱序端点。事件逐字节截断和配额由独立 MoonBit 测试覆盖。

六组真实捕获仍使用 `fixtures/mysql-8.0` 和 `fixtures/mysql-json` 中的原始文件，没有新增数据库捕获。生成器核对其 SHA-256 及官方 Previous-GTIDs / `[empty]` 文本；它们只能为零 SID 集合提供真实样本依据。

非空规范合成集合另可通过生成器的可选 `--mysqlbinlog PATH` 与官方工具对照；本地 MySQL 8.0.43 已通过八组 CRC32/OFF 对照，常规 CI 不依赖该程序。详情及范围见 [历史 GTID 文档](../../docs/previous-gtids.md)。
