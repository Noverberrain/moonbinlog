# TABLE_MAP_EVENT 与映射上下文

## 当前交付

解析类型 19 的完整事件，复用既有格式上下文与 CRC/OFF 校验。仅支持 MySQL 8.0 的 8 字节 table-map post-header：6 字节无符号 table_id 与 2 字节 table-map flags。这里的 flags 与公共事件头的 flags 分别保存。

解析库名和表名的字节长度、UTF-8 内容及 NUL 结束符；拒绝空名称、内嵌 NUL、无效 UTF-8 和截断字段。随后读取 packed column_count、类型数组、packed metadata_length、列元数据区及 nullable 位图。数据库和表名保留原始 Unicode 字符，不做大小写或 BOM 规范化。

`TableMap`、`TableColumn`、`TableMetadataField` 均为只读值，集合使用 ReadOnlyArray。列仅含 wire_type、原始 metadata 和 nullable，不推导列名、signedness、charset、主键或行值，也不替代外部历史 schema。

## 列元数据宽度

分割宽度依据 MySQL 8.0 `read_field_metadata`，保留 wire 字节顺序，不把各种双字节字段都解释为同一种整数：

| wire type | 元数据宽度 |
| --- | --- |
| 0—3、6—13 | 0 |
| 4、5、17—19、245、249—252、255 | 1 |
| 15、16、246—248、254 | 2 |

其他类型显式拒绝，包括 NEWDATE（14）、typed array（20）和当前未承诺解释的 VAR_STRING（253），不能靠“默认零字节”继续读取。对于支持的宽度，目前只验证字节边界；DECIMAL 参数、时间精度、STRING 的编码含义等值级检查由后续字段解码功能承担。

元数据块必须恰好分割完毕，既不能短缺，也不能遗留未解释的列元数据字节。nullable 位图按列顺序从低位到高位读取，与可选 SIGNEDNESS 的位序不是同一承诺；最后一个字节的填充位忽略。

## 可选元数据

nullable 位图之后按 TLV 读取：类型一字节，长度为 packed integer，再读取指定长度的值。已知与未知类型都保留原始值，不声称已经解释 COLUMN_NAME、SIGNEDNESS 或字符集。

长度不能超过当前事件 body；NULL（0xfb）与保留（0xff）长度标记拒绝。每事件最多保留 256 个 TLV，可保留空值和重复类型，防止大量空 TLV 导致无界分配。该限制属于库的资源策略，不是 MySQL 的协议限制。

## 资源与错误

默认最多 1,024 列，可由 `max_columns` 显式调整，必须为正数。先以 UInt64 读取计数并比较上限、可用输入，再转换索引或分配。沿用默认 16 MiB 事件上限。

`InvalidTableMap` 包含事件真实 file_offset、相对于去除公共头后 body 的 body_offset 及原因；类型错误另带列序号和 wire type。文件位置不与事件内部 next_position 混用。

## 上下文生命周期

`TableMapContext::new(format)` 将缓存绑定到一个格式上下文；`apply` 验证后安装映射，`get` 查找，重复 table_id 替换旧定义。返回的旧只读值不会因替换而改变。

- `clear()`：手动消费者须在语句结束时清理。`decode_rows` 已根据 ROWS flags 的 STMT_END_F 自动清理；该方法解析失败时也清空整个映射作用域，详见 [ROWS 事件说明](rows-events.md)。
- `reset(format)`：新文件或新 FDE 后清空缓存并使用新的校验策略。仅有 table_id 或 event offset 不能证明文件身份。
- `apply` 失败：清空整个当前映射范围，防止调用者捕获错误后继续使用旧定义；包括解析、CRC 和配额错误。
- 默认最多 1,024 个表 ID，以及 32 MiB 已保留 wire 事件大小预算。预算替换时扣除旧事件，不把同 ID 重复累计。此数字不代表精确堆内存，峰值解析内存还受事件与列数上限控制。

缓存是解码上下文，不是数据库 schema registry，也不处理事务提交或 DDL 演进。

## 验证与参考

38 组自建合成样本由 Python struct/zlib 独立生成。覆盖 CRC/OFF、48 位 ID、Unicode 标识符、packed count 多种编码、NULL 位图跨字节、支持类型的元数据宽度、TLV、畸形字段和缓存生命周期。

这些测试尚未完成真实 MySQL 日志或 Java 客户端差分验证，不能据此宣称完整数据库兼容性。没有复制上游实现或测试数据。

参考固定 MySQL commit `9fc8d60003b4eee32767c1e30942f222c3508c31`：

- [TABLE_MAP 结构及可选元数据格式](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/libbinlogevents/include/rows_event.h)
- [TABLE_MAP 读取规则](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/libbinlogevents/src/rows_event.cpp)
- [实际列元数据宽度规则 read_field_metadata](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/sql/rpl_utility.cc)
