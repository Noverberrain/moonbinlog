# 轮转事件样本

`scripts/generate_rotate_fixtures.py` 使用 Python struct/zlib 独立构造 21 个 ROTATE_EVENT/FDE 向量，输出根目录 rotate_fixture_test.mbt。覆盖 UInt64 的 0/4/超过 32 位/最大位置、CRC32/OFF、原始名字节、零时间戳与特殊 flags、九种过短 body、坏 CRC，以及三种不支持的 post-header 长度。

同一生成器读取已有 fixtures/mysql-8.0 和 fixtures/mysql-json 的六份官方 mysqlbinlog 输出，提取 Rotate to / pos 作为独立预期值，供 MoonBit 直接解码真实日志进行对照；生成前先核对每组原始日志和官方输出的固定 SHA-256。没有新增采集或修改原有六组捕获。

manifest.json 保存合成样本 SHA-256、实际捕获的摘要及轮转预期。官方输出只用作测试数据，不执行其中内容。脚本、SQL 和独立生成的测试样本按仓库 Apache-2.0 许可证提供。

```sh
python scripts/generate_rotate_fixtures.py
moon fmt
python scripts/generate_rotate_fixtures.py --check
moon test --target native --filter '*rotat*'
```

使用边界见 [轮转解析](../../docs/rotate-events.md)。本目录没有提供多文件日志链或自动续接测试。
