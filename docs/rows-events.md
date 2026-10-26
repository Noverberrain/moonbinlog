# WRITE/UPDATE/DELETE_ROWS v2

`TableMapContext::decode_rows` 接受完整事件及真实 `file_offset`，仅处理类型 30、31、32 和格式描述中十字节的 post-header。使用上下文的 CRC32/OFF 策略校验事件，解析 48 位 table_id，并从当前缓存获取表映射。整数符号属性沿用行镜像的逐列 `integer_unsigned` 数组。

## 布局与结果

post-header 为六字节 table_id、两字节 ROWS flags、两字节额外头长度。额外头长度包含其自身的两字节，必须至少为二；后续字节保存为 `extra_data`，不解释 NDB/分区标签的内部语义。外层长度受到 payload 边界限制。

之后读取 packed column count，并要求与表映射的完整列数一致，再读取列存在位图。位图字节数由已匹配的表列数计算，不将未验证的大整数直接转成索引。两、三、八字节 packed 编码均支持，NULL/reserved 标记明确拒绝。

返回 `RowsEvent`，包含公共事件头、不可变表映射快照、独立的 ROWS flags、extra_data、前后列位图和 `changes`：

| 事件 | RowChange | 列位图 |
| --- | --- | --- |
| WRITE_ROWS（30） | Insert(RowImage) | columns_after |
| UPDATE_ROWS（31） | Update(before, after) | columns_before、columns_after |
| DELETE_ROWS（32） | Delete(RowImage) | columns_before |

逐行解析到该事件 payload 末尾。UPDATE 必须完整读取一对镜像后才记录一个变化；后镜像缺失或后续行截断会使整个事件失败，不返回已经解码的前几行。输入可以跟随其他事件，消费边界由 header.event_size 决定，后续事件的字节不参与校验或解码。

普通空 payload 可以返回零个变化；不会凭空生成一行。单镜像的全缺失位图可消费零字节，因此每个变化必须整体取得进展：UPDATE 可以有空 before 镜像，但若 before/after 都不消费且还有 payload，则明确失败，避免无限循环。

## 缓存生命周期

只有整个事件成功后，才检查 ROWS flags 中的 `STMT_END_F`（最低位）并清空所有表映射。它与公共事件头 flags、TABLE_MAP flags 不同。结果自带表快照，清理后仍可读取表名、列元数据及已解码值。

任意失败也清空整个当前映射作用域，包括格式/CRC、未知 table_id、列数不匹配、参数配置、值解析或资源上限错误。之后需要重新 apply TABLE_MAP；format 仍保留，遇到新文件或格式描述应 reset。

手动读取行镜像或其他消费者不会触发本方法的清理，仍须自行在适当边界 clear。

## 上限与错误

默认事件大小上限 16 MiB，单镜像预算 16 MiB，单事件最多 1024 个变化。`max_rows` 必须为正；UPDATE 一对镜像计为一个变化，单镜像预算分别适用于 before/after。上限不表示精确堆内存字节数，解码后的列对象还占用额外内存。

事件偏移加事件长度必须能由 UInt64 表示。标量错误保留真实字段位置及表列号，结构错误使用 `InvalidRowsEvent` 的事件起点和 body_offset，未知表 ID 返回 `MissingTableMap`。参数和行数上限分别返回 `InvalidRowsLimit`、`RowsLimitExceeded`，行镜像和 CRC 错误沿用现有类型。

## 尚未包含

本接口输出只是 Binlog 中的行变化，不代表事务提交。需要按事务汇总时可使用 [TransactionDecoder](transactions.md)；本层本身不缓冲事务或执行数据库写入。旧 ROWS、PARTIAL_UPDATE_ROWS、压缩事务和 dummy table-id 结束事件不在支持范围；不应将未知事件硬套到本接口。

extra_data 只是外层有界的原始字节，不宣称已经验证其中所有标签。普通完整 JSON 已支持；opaque / partial JSON 以及标量层尚不支持的非 NULL 列仍明确失败，见 [JSON 字段](json-values.md)。缺失或 NULL 的不支持列可由行镜像正常表示。

## 验证与依据

Python 独立封装混合行镜像并用 zlib 计算 CRC，共 36 组样本，包含 I/U/D 多行、不同前后位图、OFF、额外头、packed count 变体，以及完整 CRC 下的结构/语义错误。测试覆盖每个事件截断前缀、第二行及配对截断、缓存清理/恢复、独立标志位、无进展、上限、偏移和后续事件边界。

协议依据固定在 MySQL commit `9fc8d60003b4eee32767c1e30942f222c3508c31` 的 [ROWS 事件布局与 STMT_END_F](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/libbinlogevents/include/rows_event.h) 和 [构造器中的 v2 额外头、列数及位图读取](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/libbinlogevents/src/rows_event.cpp)。实现及样本独立编写，真实 MySQL/Java 交叉验证仍未完成。
