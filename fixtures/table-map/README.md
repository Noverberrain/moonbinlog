# TABLE_MAP 合成样本

运行 `python scripts/generate_table_map_fixtures.py` 重建 38 组样本和 SHA-256 清单，运行带 `--check` 的同一命令检查一致性。

生成脚本复用前一批的 framing/FDE 生成器，使用 Python struct/zlib 写入事件头及 CRC，不调用 MoonBit 实现。常量位于根目录 `table_map_fixture_test.mbt`。畸形 body 也写入正确 CRC，确保可以测试内层字段检查。

涵盖普通表、相同 ID 不同表名、第二 ID、最大 48 位 ID、UTF-8 名称、NULL 位图、可选 TLV、各元数据宽度、各种 packed count 编码及结构错误。

样本属于本项目自行生成的协议数据，不是服务器实录；真实日志与上游客户端的交叉验证仍需后续完成。
