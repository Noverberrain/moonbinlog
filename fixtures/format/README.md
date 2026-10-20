# 格式描述合成样本

这些字节由本项目脚本独立构造，不来自上游测试库或业务数据库。

`scripts/generate_format_fixtures.py` 生成根目录 `format_fixture_test.mbt` 中的 17 组样本常量，以及此目录的 SHA-256/长度清单。CRC 由 Python 标准库 zlib 计算；无需运行 MoonBit 解析器即可重建预期值。

```text
python scripts/generate_format_fixtures.py
moon fmt
python scripts/generate_format_fixtures.py --check
```

清单覆盖 CRC32/OFF、FDE in-use 与其他 flags、畸形版本与长度表、未知算法，以及有/无 CRC 的普通事件。原始 Byte 常量只表示事件，不带文件 magic。

固定字段使用虚构版本后缀 `8.0.36-moonbinlog`。这不是“已在 MySQL 8.0.36 上验证”的声明；实际服务器兼容矩阵应由之后的集成测试建立。
