# FLOAT/DOUBLE 值解码

`TableColumn::decode_floating` 接受已确认存在、非 NULL 的 FLOAT（4）或 DOUBLE（5）字段。元数据必须恰好为一个字节，分别标记宽度 4 或 8；不接受零宽度或与类型不匹配的宽度。

结果 `DecodedFloating` 包含：

- `value: FloatingValue`：`Single(Float)` 或 `DoublePrecision(Double)`，保留原始二进制精度。
- `bits: UInt64`：原始 IEEE 754 位模式，FLOAT 使用低 32 位，其余为零。
- `bytes_read`：固定为 4 或 8，只消费当前字段。

## 数值与特殊位模式

输入按小端字节组装，再进行位重解释，不将位模式当作整数做数值转换。保留有限的次正规数、最大有限值以及正负零。浮点数值比较无法区分正负零，打印也可能规范化，因此需要保留原始 bits。

FLOAT/DOUBLE 不是精确十进制类型。例如单精度编码的 0.1 转成 Double 后为 0.10000000149011612；本方法不按照显示格式舍入、不恢复 schema 的小数位数，也不推断 UNSIGNED 约束。需要精确金额时应使用前一批的 DECIMAL 解码。

本接口只接受有限数：指数位全一的 NaN（含 quiet/signaling 和不同 payload）及正负无穷大，在位重解释前返回 `NonFiniteFloatingValue`，错误保留 wire type 和原始 bits。该策略是当前解码接口的明确边界，不将这些位模式替换成零或 NULL，也不宣称它们是可由常规 MySQL 列值正常生成的样本。

元数据错误返回 `InvalidFloatingMetadata`，不支持的类型返回 `UnsupportedFloatingColumn`，输入不足返回 `TruncatedColumnValue`。错误保留字段首字节的 `file_offset` 和从零开始的 `column_index`。调用者负责行的存在位图及 NULL 位图；nullable 列的零值不等于 NULL。

## 验证与依据

Python 标准库 struct 独立生成并读取 64 组有限样本，另构造 10 组非有限位模式。覆盖正负零、最小/最大次正规数、最小正规数、最大有限值、固定数值与固定种子的随机位模式。黑盒测试同时比较数值、重新解释后的位模式和消费长度，覆盖全部截断前缀、错误元数据、混合字段与切片。

协议依据固定在 MySQL commit `9fc8d60003b4eee32767c1e30942f222c3508c31` 的 [Field_float/Field_double 元数据及存储定义](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/sql/field.cc)。MoonBit 位重解释接口通过本地 `moon ide doc Float` 和 `moon ide doc Double` 核对，行为在 native 目标验证。实现与样本独立编写，真实 MySQL/Java 交叉验证仍未完成。
