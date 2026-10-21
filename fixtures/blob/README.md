# BLOB 样本

`python scripts/generate_blob_fixtures.py` 重建 `blob_fixture_test.mbt` 和本目录 manifest；`--check` 校验一致性。

TABLE_MAP 样本包含四种合法、三种非法长度宽度，以及不应被 BLOB 解码器接受的 JSON、GEOMETRY 和独立类型码 249～251。四组字段样本由 Python `int.to_bytes` 构造长度前缀，内容包括中文、NUL、FF 与尾部空格。

清单记录长度和 SHA-256。所有样本为协议构造，不是真实 MySQL 导出文件。
