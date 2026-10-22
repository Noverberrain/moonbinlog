# ENUM/SET 值解码

`TableColumn::decode_enum_set` 接受已确认存在、非 NULL 的字段。只处理常规 MySQL TABLE_MAP 的 STRING（254）表示，元数据的第一字节是真实类型，第二字节是固定存储宽度：

| 真实类型 | 元数据首字节 | 合法字节宽度 | 返回值 |
| --- | --- | --- | --- |
| ENUM | 247 | 1、2 | `EnumSetValue::EnumIndex(UInt16)` |
| SET | 248 | 1、2、3、4、8 | `EnumSetValue::SetMask(UInt64)` |

结果 `DecodedEnumSet` 包含 `value` 和 `bytes_read`。原始数值按小端解码，不带字符串长度前缀，不按 STRING 的最大长度规则解读。

SET 的 5～7 字节不是本接口支持的存储宽度：MySQL 对超过四字节的 SET 使用八字节。零宽度、错误真实类型和非法宽度返回 `InvalidEnumSetMetadata`。独立 wire type 247/248 及其他字段类型返回 `UnsupportedEnumSetColumn`，本批未猜测它们的额外布局。

## 索引与成员范围

ENUM 返回原始索引。通常从 1 起对应声明中的成员，0 是 MySQL 特殊错误索引，保留为数值而不替换为 NULL。二字节最大值 65535 也完整保留。

SET 按位表示成员，最低位对应第一个成员。例如掩码 261 设置了第 1、3、9 个成员位置；零掩码表示空集合，不是 NULL。八字节 SET 的最高位和完整 UInt64 最大值均不经过浮点或有符号转换。

当前 TABLE_MAP 可选元数据仍按原始 TLV 保存，没有解析成员名称、实际成员数量或字符集。因此接口仅检查固定宽度，不校验 ENUM 索引是否超过成员数，也不屏蔽 SET 中可能超出实际成员数的高位，不返回推测出的名称。

## 消费边界和验证

`file_offset` 是字段首字节，`column_index` 从零开始。元数据和类型错误以及 `TruncatedColumnValue` 均保留这些定位字段。先验证元数据和完整输入长度，再访问值；只消费声明的固定宽度。调用者负责行的列存在位图和 NULL 位图。

字符串解码器仍拒绝内嵌 ENUM/SET，ENUM/SET 解码器同样拒绝真正的 STRING。两者可根据真实类型显式分派，不将枚举索引误当作字符串长度。

Python 独立构造 35 组数值、七种有效及十三种非法元数据组合；测试还覆盖单字节 ENUM 全部 256 个索引、空值语义、UInt64 高位、全部截断位置、字符串分派、连续字段与切片。

协议依据固定在 MySQL commit `9fc8d60003b4eee32767c1e30942f222c3508c31` 的 [Field_enum 元数据及 pack 定义](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/sql/field.cc) 和 [ENUM/SET 存储宽度计算](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/sql/field.h)。实现与合成样本独立编写，尚未完成真实 MySQL/Java 交叉验证。
