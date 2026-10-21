# BLOB/TEXT 值解码

`TableColumn::decode_blob` 接受已确认存在、非 NULL 的字段，返回 `DecodedBlob`：`value: Bytes` 保存内容，`bytes_read` 包含前缀和内容的消费长度。后续字段保持未消费。

## 编码范围

支持 MySQL 常规 TABLE_MAP 中的 BLOB wire type 252。TINYBLOB/TINYTEXT、BLOB/TEXT、MEDIUMBLOB/MEDIUMTEXT、LONGBLOB/LONGTEXT 都以该类型加一个元数据字节区分长度前缀宽度：

| 元数据 | 小端长度前缀 | 可表示的最大内容长度 |
| --- | --- | --- |
| 1 | 1 字节 | 255 |
| 2 | 2 字节 | 65535 |
| 3 | 3 字节 | 16777215 |
| 4 | 4 字节 | 4294967295 |

元数据宽度必须为 1～4。独立类型码 249～251、JSON（245）、GEOMETRY（255）以及其他列类型均明确拒绝；不能仅凭类似的前缀把它们作为 BLOB 解码。TABLE_MAP 层保留这些类型不代表当前支持其值解码。

内容保持原始字节，可包含中文、非法 UTF-8、NUL 或尾部空格。当前不区分 TEXT 字符集、不做解码转换。空内容仍消费完整前缀，不等于 NULL；调用者负责行的存在位图和 NULL 位图。

## 大小与错误

`max_value_bytes` 默认 16777216（16 MiB），只限制内容，不包含前缀。允许配置为 0，仅接受空内容；负值和大于 2147483643 的配置返回 `InvalidBlobLimit`。保留四字节余量，使总消费量和截断诊断安全落在 Int32 范围。

先以 UInt64 解码长度并检查上限，再转为索引、检查完整输入，最后复制内容。不会因输入的长度声明提前分配缓冲区。实际包含在事件中的字段仍受事件层大小限制；配置字段上限不会放宽事件上限。

错误包括 `UnsupportedBlobColumn`、`InvalidBlobMetadata`、`BlobTooLarge` 和复用的 `TruncatedColumnValue`。除配置错误外均保留字段首字节的 `file_offset` 与从零开始的 `column_index`。截断的 expected/actual 从字段首字节计算，包含长度前缀。

## 验证与依据

Python 独立构造并用 zlib 保护 TABLE_MAP，覆盖四种合法及三种非法前缀宽度，并提供四组字段样本和 SHA-256 清单。测试覆盖所有截断点、零上限、精确上限、默认及调整上限、跨字节长度、高位四字节长度、原始内容及连续字段消费。未完成真实 MySQL 日志交叉验证。

协议依据固定在 MySQL commit `9fc8d60003b4eee32767c1e30942f222c3508c31` 的 [Field_blob 元数据与 pack/unpack 定义](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/sql/field.cc)。实现与合成样本独立编写。
