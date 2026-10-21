# DECIMAL 值解码

`TableColumn::decode_decimal` 接受已确认存在、非 NULL 的 NEWDECIMAL（wire type 246）。旧 DECIMAL（0）和其他类型明确拒绝，不尝试推断旧格式。

两个元数据字节分别表示 precision 和 scale。本实现限定 MySQL 8.0 的 precision 1～65、scale 0～30 且 scale 不超过 precision。结果 `DecodedDecimal` 包含精确十进制字符串 `value`、`precision`、`scale` 和 `bytes_read`。

## 数值表示

全程不转换为浮点数，也不将整个数值压入 Int64/UInt64。输出整数部分去掉多余前导零，至少保留一个零；小数部分精确保留 scale 位，不进行舍入。例如 `123.40`、`-0.000000001` 和 65 位整数均可精确保留。scale 为零时不输出小数点，负零规范化为相同 scale 的零。

unsigned 属性没有从 schema 推断出来；方法依据编码中的符号解码，不承担校验 UNSIGNED 列约束或十进制算术的职责。NULL 和列存在位图仍由未来行事件层处理。

## 分组与校验

整数和小数分别按每组九位十进制数字编码，完整组为四字节大端数；剩余 1～8 位使用 1～4 字节。最高位携带符号信息，负数内容按位取反。固定长度由 precision/scale 决定，先检查输入长度再访问内容。

每组值必须小于该组位数对应的十进制上界，否则返回 `InvalidDecimalValue`。这能拒绝字节可容纳但对应十进制位数无法容纳的值。该错误的 `value_offset` 是损坏分组相对字段开头的字节偏移。

`file_offset` 是字段首字节的物理文件位置，`column_index` 从零开始。类型错误、元数据错误、值错误及截断错误均保留这两个位置。`TruncatedColumnValue` 的 expected 是字段完整固定长度。多余输入留给后续字段，`bytes_read` 返回实际消费长度。

## 验证与依据

Python 使用整数的独立编码器构造 32 种 precision/scale 组合和 192 组样本，使用标准库 Decimal 生成十进制期望值；不依赖 MoonBit 实现输出。还包含固定字节金额样本、65 位最大值、小数尾零、整数分组补零、负零、所有截断前缀、非法元数据和越界分组测试。

协议依据固定在 MySQL commit `9fc8d60003b4eee32767c1e30942f222c3508c31` 的 [decimal 二进制格式与转换定义](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/strings/decimal.cc)。实现与合成样本独立编写；尚未完成真实 MySQL 文件或 Java 客户端交叉验证。
