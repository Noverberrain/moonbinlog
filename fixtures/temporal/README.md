# 日期时间样本

运行 `python scripts/generate_temporal_fixtures.py` 重建 `temporal_fixture_test.mbt` 与 manifest，`--check` 检查一致性。

包含一个 CRC 保护的 29 列 TABLE_MAP、124 个有效和 23 个损坏字段值。字段从显式年月日时分秒/微秒或秒数构造，不依赖机器时区。DATE/YEAR 和三个现代时间类型均被覆盖，后者各含全部 0～6 位精度。

损坏样本包括非法组件、符号位、微秒范围、奇数精度填充和 TIME 端点超限；表映射另含非法精度及不支持的旧时间类型。manifest 保存表映射和规范化向量的 SHA-256。

合成样本不代表真实数据库日志集成验证已经通过。
