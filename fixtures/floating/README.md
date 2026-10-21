# 浮点数样本

运行 `python scripts/generate_floating_fixtures.py` 重建 `floating_fixture_test.mbt` 和 manifest；`--check` 检查一致性。

一个 CRC 保护的 TABLE_MAP 包含合法 FLOAT/DOUBLE 以及六种错误元数据。64 组有限字段值使用 Python struct 独立编码/读取，种子为 20261021；10 组 NaN/无穷大位模式仅用于拒绝测试。

期望值包括原始位模式与 Python 生成的数值字面量。最小 Double 次正规数的科学计数法显式保留小数点，满足 MoonBit 字面量语法。manifest 记录样本数、表映射及规范化向量 SHA-256。

样本属于协议构造，不是真实 MySQL 导出的日志。
