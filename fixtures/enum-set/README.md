# ENUM/SET 样本

运行 `python scripts/generate_enum_set_fixtures.py` 重建 `enum_set_fixture_test.mbt` 与 manifest；`--check` 校验一致性。

一个 CRC 保护的 22 列 TABLE_MAP 包含七种有效、十三种非法元数据，以及两个不支持的独立类型码。35 组值覆盖零、1、最高位、最大值与非对称模式，通过 Python 大整数的 little-endian `to_bytes` / `from_bytes` 独立构造并读取。

manifest 记录元数据组合、样本数、表映射和规范化向量 SHA-256。这些样本没有成员名称表，不能用于宣称成员名称或范围解析已经完成。

样本属于协议构造，不是真实数据库导出的日志。
