# 单个行镜像解码

`TableMap::decode_row_image` 将一份普通行镜像与当前表映射组合。输入 `data` 从紧凑 NULL 位图开始，不包含事件头、table_id、事件级列数或列存在位图；后者通过 `columns_present` 单独传入。

返回 `RowImage`：`columns` 长度等于表列数，使用 `RowCell` 区分 `Absent`（本镜像未包含）、`Null`（SQL NULL）和各类值；`bytes_read` 包含 NULL 位图及已消费字段，尾部可包含下一镜像。

## 两种位图

列存在位图恰好占 `ceil(表列数/8)` 字节，按表列号排列，字节内低位在先。设真实列范围内有 P 个存在位为一，NULL 位图则占 `ceil(P/8)` 字节，按这些存在列的顺序紧凑排列，包括 NOT NULL 列。

例如仅包含表列 1、5、8、14、16（从零开始）时，NULL 位图的五个位分别对应这五列；位 3 指列 14，而不是表列 3。未包含的列不占 NULL 位也不消费值字节。位图末尾超出实际位数的填充位忽略。

NULL 位为一时不读取字段值，但要求表映射声明该列 nullable，否则返回 `UnexpectedRowNull`。不支持的字段若为 NULL 或缺失也可表示；若为存在且非 NULL，则明确失败，不猜测长度或尝试跳过。

## 字段分派与整数符号

复用现有整数、浮点、字符串、BLOB、DECIMAL、BIT、ENUM/SET、日期时间和 JSON 解码器。STRING（254）先检查真实类型，区分普通字符串和 ENUM/SET；各解码器已有的精度、特殊值与元数据策略继续生效。

`integer_unsigned` 是与表列数相同的 `ReadOnlyArray[Bool?]`。存在且非 NULL 的整数列必须有 `Some(false)`（signed）或 `Some(true)`（unsigned），缺少时返回 `MissingIntegerSignedness`。其他列以及缺失/NULL 整数列的条目忽略，可以是 None。当前不从 TABLE_MAP 可选元数据推断 signedness。

`RowCell::Integer` 和 `EnumSet` 保存对应值枚举；`StringBytes`、`BlobBytes` 保存原始字节；`Floating`、`Decimal`、`Bit`、`Temporal` 保留对应标量结果及精度等属性。`JsonDocument` 保存 JSON AST 和消费长度，JSON null 是实际值，区别于 SQL NULL。零、空字符串、空 BLOB 和空 SET 都不等于 NULL。

## 上限、错误和位置

`max_bytes` 默认 16 MiB，限制一份镜像的总消费量，包括 NULL 位图；合法配置为 0～2147483643。每个字段只获得剩余预算内的输入视图，在字符串/BLOB 内容复制前受此视图限制。BLOB 和 JSON 的内容上限同时设为行预算；JSON 深度/节点使用默认配额，见 [JSON 字段](json-values.md)。

原输入足够但字段超出剩余预算时返回 `RowImageLimitExceeded`；原输入本身不足时保留标量截断错误。超过 BLOB 内容上限的声明也可能优先返回 `BlobTooLarge`。本方法不以输入总长度作为行长度，因此允许后续镜像跟随。

`file_offset` 是 NULL 位图首字节的物理位置。标量错误定位到该字段首字节，NULL 约束错误定位到对应 NULL 位所在字节，列号始终是表列号。输入的 `min(data.length, max_bytes)` 地址跨度必须能表示在 UInt64 中，防止后续偏移加法溢出。

存在位图或符号数组长度错误、非法预算、NULL 位图截断和不支持的非 NULL 类型均通过结构化错误返回。此方法不会修改表映射或缓存，失败后不返回部分行结果。

## 当前范围

此批仅支持普通单镜像布局，不处理 ROWS 事件头、before/after 配对、事件 CRC、多行遍历、partial JSON 格式、事务或 statement-end 缓存清理。调用者须从已验证且格式匹配的事件中提取普通镜像输入。

全零存在位图合法，返回全部 Absent 且消费零字节。后续事件遍历层必须检查零进展，避免无限循环；当前方法本身不循环读取多行。

## 验证与依据

Python 独立构造一个 17 列 TABLE_MAP 和六份混合镜像：完整、稀疏、全 NULL、跨字节 NULL、零/空值及全缺失。测试覆盖全部已支持字段族、紧凑位图、符号参数、NOT NULL 约束、不支持列的 NULL/缺失情况、逐字节截断、所有紧预算、偏移溢出、填充及连续镜像。样本与状态清单附 SHA-256。

格式依据固定在 MySQL commit `9fc8d60003b4eee32767c1e30942f222c3508c31` 的 [Rows_event 位图和行布局](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/libbinlogevents/include/rows_event.h)。实现与样本独立编写，原有字段的真实 MySQL 验证见 [集成验证](mysql-integration.md)，新增 JSON 对照见 [JSON 字段](json-values.md)；Java 差分尚未完成。
