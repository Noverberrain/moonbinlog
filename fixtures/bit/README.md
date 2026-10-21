# BIT 样本

运行 `python scripts/generate_bit_fixtures.py` 重建 `bit_fixture_test.mbt` 与 manifest；`--check` 检查一致性。

一个 CRC 保护的 71 列 TABLE_MAP 包含 BIT(1)～BIT(64) 和七种非法元数据。188 组字段样本由 Python 大整数通过大端 `to_bytes`/`from_bytes` 独立构造并读取，覆盖每种宽度的零、最大值和固定非对称模式；重复值已去重。

manifest 保存非法元数据、向量数量、表映射及规范化向量 SHA-256。填充位的变体由 MoonBit 黑盒测试另行构造。

这些是协议构造数据，不是真实数据库日志。
