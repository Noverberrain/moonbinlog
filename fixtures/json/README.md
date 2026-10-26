# 独立 binary JSON 样本

`scripts/generate_json_fixtures.py` 使用 Python 标准库独立构造 31 个有效和 24 个无效文档，以及两列 TABLE_MAP、INSERT / UPDATE / DELETE 和显式事务。不是从 MoonBit 实现反向生成，也未复制上游代码或样本。

有效值覆盖全部支持的标记、整数各宽度极值、UInt64 最大值、Int64 最小值、double 负零与次正规数、Unicode/NUL/转义、变长字符串、BOM、小/大嵌套容器、空容器、内联填充及空隙/逆序载荷。无效值覆盖 opaque/未知标记、非法字面量、截断/溢出长度、非法 UTF-8、非有限 double、重叠引用、坏偏移/容器大小、重复/乱序键和伪造巨大节点数。

生成文件为根目录 json_fixture_test.mbt；manifest.json 记录文档及事件 SHA-256 和独立预期 JSON 文本。生成文件接受 moon fmt 排版。

```sh
python scripts/generate_json_fixtures.py
moon fmt
python scripts/generate_json_fixtures.py --check
```

完整边界见 [JSON 字段说明](../../docs/json-values.md)。样本与脚本按仓库 Apache-2.0 许可证提供。
