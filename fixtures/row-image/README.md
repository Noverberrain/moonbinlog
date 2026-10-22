# 行镜像样本

运行 `python scripts/generate_row_image_fixtures.py` 重建 `row_image_fixture_test.mbt` 和 manifest；`--check` 检查一致性。

一个 CRC 保护的 17 列 TABLE_MAP 覆盖所有已支持字段族和一个 JSON 列。六份镜像覆盖完整、稀疏、全 NULL、跨字节、零/空值和全缺失。第 5 列（从零开始）声明 NOT NULL，用于验证该列仍占紧凑 NULL 位。

Python 独立打包列存在及 NULL 位图；标量值使用标准库 struct、整数编码及已有独立日期编码器构造。manifest 记录每列的缺失/NULL/值状态、位图、消费长度和 SHA-256。样本不包含 ROWS 事件头，也不代表数据库集成验证已经通过。
