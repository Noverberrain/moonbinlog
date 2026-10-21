# 日期时间值解码

`TableColumn::decode_temporal` 解析一个存在、非 NULL 的字段，返回 `DecodedTemporal`，包含 `value: TemporalValue`、`fractional_precision` 和 `bytes_read`。

| wire type | 类型 | 返回分量 | 固定部分 |
| --- | --- | --- | --- |
| 10 | DATE | year/month/day | 3 字节，小端 |
| 13 | YEAR | 0 或 1901～2155 | 1 字节 |
| 17 | TIMESTAMP2 | 原始 UInt32 秒数、微秒 | 4 字节，大端 |
| 18 | DATETIME2 | 年月日时分秒、微秒 | 5 字节，大端 |
| 19 | TIME2 | 正负号、小时分秒、微秒 | 3 字节偏移编码 |

DATE/YEAR 不应有列元数据；后三类元数据为一个字节，表示 0～6 位小数精度。小数部分额外占 `(fsp+1)/2` 个字节。旧 TIMESTAMP/TIME/DATETIME（7/11/12）和内部 NEWDATE（14）不在本批范围。

## 保留语义

- DATE/DATETIME 保留零日期、部分为零的日期及 SQL mode 可能允许的非日历日期，例如 2023-02-31，不做补齐或自动纠正。校验年份最多 9999、月份最多 12、日最多 31、时最多 23、分秒最多 59。
- YEAR 的字节 0 返回 0，其余返回字节值加 1900，不使用两位年份的输入转换规则。
- TIME 是时长，可以超过 24 小时，支持负的小于一秒的值。验证绝对值不超过 838:59:59，端点处不允许非零微秒；零值不带负号。
- TIMESTAMP 保留全部四字节秒数，包括高位；不套用本机时区、不强制 SQL 层日期范围。原始零秒也可能是 MySQL 的零时间戳表示，不应据此自动显示为 Unix epoch 的日历日期。
- 微秒是整数，范围 0～999999，并须符合声明的 fsp 精度；奇数 fsp 的额外填充位必须为零。保留 `fractional_precision` 可供后续格式化时恢复声明的小数位数。

零日期、零年份、零时长和零时间戳都不是 NULL；调用者负责行的列存在和 NULL 位图。此接口不进行 SQL mode、字符格式或业务日历验证。

## 边界与错误

`file_offset` 定位字段的首字节，`column_index` 从零开始。类型不支持、元数据错误、值错误和截断分别返回 `UnsupportedTemporalColumn`、`InvalidTemporalMetadata`、`InvalidTemporalValue`、`TruncatedColumnValue`，保留以上定位字段。

先验证精度和完整字段长度，再访问数据。`bytes_read` 只包含当前字段，尾部留给下一个字段。TIME2 按带偏移的定点数解码，处理负小数与整数间的借位，而不是只将小时数取负。

## 验证与依据

Python 根据显式分量独立生成 124 个有效、23 个损坏值，以及包含非法精度和旧类型的 TABLE_MAP。黑盒测试覆盖所有 fsp、YEAR 全部 256 种编码、负小数借位、端点、零/部分零/非日历日期、高位秒数、逐字节截断、混合字段和切片。清单记录 SHA-256。

编码依据固定在 MySQL commit `9fc8d60003b4eee32767c1e30942f222c3508c31` 的 [低层日期时间格式](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/mysys/my_time.cc) 和 [字段实现](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/sql/field.cc)。实现和样本独立编写，未完成真实 MySQL/Java 交叉验证。
