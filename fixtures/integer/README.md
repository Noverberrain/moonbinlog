# 整数样本

运行 `python scripts/generate_integer_fixtures.py` 重建 `integer_fixture_test.mbt` 和本目录清单；添加 `--check` 只校验一致性。

生成器采用 Python 标准库 `int.to_bytes` / `int.from_bytes`，覆盖 1、2、3、4、8 字节宽度。固定随机种子与边界模式共生成 60 组输入、120 个符号解释断言。十进制期望值使用字符串保存，避免 UInt64 经浮点转换丢失精度。

manifest 记录生成参数及规范化样本的 SHA-256。样本不来自真实数据库，不代表 MySQL 集成测试通过。
