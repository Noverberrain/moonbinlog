# 整数值解码

`TableColumn::decode_integer` 从字段起点的 `BytesView` 解码一个非 NULL 整数。

| MySQL 类型 | wire type | 字节数 |
| --- | --- | --- |
| TINYINT | 1 | 1 |
| SMALLINT | 2 | 2 |
| MEDIUMINT | 9 | 3 |
| INT | 3 | 4 |
| BIGINT | 8 | 8 |

字段采用小端编码。`unsigned` 是必填参数，须由调用者提供可信的 schema 属性；当前没有从 TABLE_MAP 可选元数据中解析 signedness。相同的全 FF 字节可以表示 -1 或对应宽度的无符号最大值。

返回 `DecodedInteger`：`value` 为 `IntegerValue::Signed(Int64)` 或 `Unsigned(UInt64)`，`bytes_read` 为消费字节数。不会经过浮点转换，因此 BIGINT 的完整范围可以精确保留。输入允许包含后续字段，调用者根据消费量推进游标。

`file_offset` 指向当前字段的第一个字节，`column_index` 是从零开始的列号，用于结构化错误定位。输入不足返回 `TruncatedColumnValue`；不支持的列类型返回 `UnsupportedIntegerColumn`。

NULL 不占用此解码器的整数值字节。列定义中的 nullable 只表示允许 NULL，实际 NULL 与列是否存在必须由后续行事件层的位图决定。当前方法不解析行事件、位图或事务。

验证包含 60 组 Python 独立生成的输入，各检查 signed/unsigned 两种解释；额外穷举 TINYINT 的 256 种字节模式，并覆盖各宽度的截断、边界、相邻字段和切片。样本属于协议构造，尚未与真实 MySQL 日志交叉验证。

协议类型依据沿用 [固定版本 MySQL 类型定义](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/include/field_types.h)。实现独立编写。
