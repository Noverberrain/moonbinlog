# ROWS v2 事件样本

运行 `python scripts/generate_rows_event_fixtures.py` 重建 `rows_event_fixture_test.mbt` 和 manifest；`--check` 检查一致性。

复用行镜像生成器公开的原始样本函数，使用 Python struct、packed length 及 zlib 封装 36 个样本。包含 I/U/D 多行、语句结束、独立公共 flags、额外头、OFF、空 payload、packed count、错误 post-header 格式及结构/语义错误；损坏 CRC 另有专用样本。

所有期望数据来自协议构造；manifest 记录每个样本的字节数和 SHA-256。当前没有真实数据库导出日志，也不能由这些测试证明事务提交处理已完成。
