# DECIMAL 样本

`python scripts/generate_decimal_fixtures.py` 重建 `decimal_fixture_test.mbt` 和本目录 manifest；`--check` 校验一致性。

包含一个 CRC 保护的 TABLE_MAP、32 种有效 precision/scale 和五种非法组合，以及 192 组字段值。覆盖整数/小数的余数位宽、九位分组、65 位精度和 30 位 scale。固定随机种子为 20261021。

编码由 Python 整数分组完成，期望字符串由精度为 80 的标准库 Decimal 上下文生成，避免默认 28 位上下文舍入。清单记录参数、TABLE_MAP 的 SHA-256 及规范化值向量摘要。

样本属于协议构造，不是实际 MySQL 导出的日志。
