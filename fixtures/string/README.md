# 字符串表映射样本

`python scripts/generate_string_fixtures.py` 重建 `string_fixture_test.mbt` 和本目录的 manifest；`--check` 校验一致性。

样本包含六种 VARCHAR 最大字节长度、九种 STRING 最大字节长度，以及 ENUM、SET 和非法内嵌类型。长度列表与整个事件的 SHA-256 记录在 manifest 中。生成器复用已有 TABLE_MAP 封装和 Python zlib 校验，但字符串元数据独立编码；MoonBit 测试使用已知长度构造字段值并验证消费边界。

这是协议构造样本，不是实际数据库导出的日志。
