# 字符串值解码

`TableColumn::decode_string` 解码一个已确认存在、非 NULL 的字段，返回 `DecodedString`：

- `value: Bytes` 保存字段的原始字节，不包含长度前缀。
- `bytes_read` 包含长度前缀和字段内容，用于推进后续字段游标。

支持 wire type 15（VARCHAR，包括 VARBINARY）与 254（真正的 STRING，包括 CHAR/BINARY）。不支持内部 VAR_STRING（253）、ENUM/SET、BLOB/TEXT 或 JSON。

## 长度与边界

VARCHAR 的两个元数据字节是小端最大字节长度，范围为 0～65535。STRING 的第一个元数据字节混合真实类型与长度高两位，第二个字节是长度低八位，最大为 1023 字节。STRING 内嵌的 ENUM/SET 及未知真实类型会返回 `InvalidStringMetadata`。

最大字节长度不超过 255 时，字段使用一个字节的长度前缀；大于 255 时使用两个小端字节。前缀宽度由元数据决定，即使实际内容只有一个字节或为空也不能省略。实际长度超过元数据上限返回 `StringLengthExceeded`，输入不足返回 `TruncatedColumnValue`。检查完成后仅复制实际内容，后续字段保持未消费。

`file_offset` 定位当前字段首字节，`column_index` 是从零开始的列号；错误保留两者。截断错误的 expected/actual 都指从字段首字节起的总字节数，包含长度前缀。

## 文本与 NULL

数据库字符串可能使用不同字符集，也可能是二进制数据。因此保留 NUL、非法 UTF-8、BOM 和尾部空格；当前不进行字符集转换。生产者可能已去掉 CHAR/BINARY 的填充，本方法不根据列宽恢复填充或宣称返回了完整 SQL 显示值。

空字符串不是 NULL：空值仍消费长度前缀。nullable 列属性不能代替行 NULL 位图；调用者须在调用前处理行的列存在位图和 NULL 位图。本批未实现行事件层。

## 验证与依据

黑盒测试通过真实公共 TABLE_MAP 解析接口获得列定义。Python 独立构造并用 zlib 校验一个 18 列的合成事件；覆盖 15 种最大长度及三种不支持的内嵌类型。测试包含最大长度、255/256 边界、中文与二进制保留、空值、逐字节截断、长度超限、切片及字符串/整数连续读取。尚未完成真实 MySQL 日志交叉验证。

格式依据固定在 MySQL commit `9fc8d60003b4eee32767c1e30942f222c3508c31` 的 [Field_string / Field_varstring 元数据与 pack/unpack 定义](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/sql/field.cc)；实现及合成样本独立编写。
