# CLI 行变化 JSON Lines v1

行模式读取外部 schema，将常规 ROWS v2 事件输出为带列名的 INSERT / UPDATE / DELETE。它复用既有文件校验、表映射和字段解码器，所有结果均标记 `transaction_status: "unconfirmed"`；本模式没有启用事务组装。

## 运行

在仓库根目录执行：

```text
moon run --target native cmd/moonbinlog -- --rows --schema examples/mysql-8.0-schema.json fixtures/mysql-8.0/crc32-full.binlog
moon run --target native cmd/moonbinlog -- --rows --schema examples/mysql-8.0-schema.json --summary fixtures/mysql-8.0/crc32-minimal.binlog
```

`--rows` 和 `--schema PATH` 缺一不可。自动启用 JSON Lines，无需再传 `--json`；显式添加 `--json` 也可。每行一个完整对象，没有 TSV 表头或顶层 JSON 数组。`--summary` 省略逐行变化，但仍绑定 schema、解码全部行事件，遇到同样的错误。

--database NAME / --table NAME 可选择匹配的行事件；未匹配事件仍完整解码，原有 row_events/changes 继续表示全文件总量，摘要另加 selected_*，详见[筛选计数与限制](cli-filters.md)。

配置文件必须为 UTF-8，接受一个开头 BOM，拒绝无效 UTF-8。分配读取前限制为 4 MiB，转成字符串后继续检查 schema 库默认配额；`--max-file-bytes` 只影响 Binlog 文件。配置格式、示例及匹配可信范围见 [schema v1](schema.md)，通用大小参数、退出码见 [CLI 使用说明](cli.md)。

## 行记录

每个 ROWS 事件完整解码成功后，按原顺序输出其中的变化；同一事件的变化使用从零开始的 `change_index`。下面用单列 INSERT 展示对象形状：

```jsonl
{"schema_version":1,"kind":"row_change","transaction_status":"unconfirmed","offset":"400","type":30,"database":"shop","table":"orders","table_id":"108","change_index":0,"operation":"insert","before":null,"after":[{"index":0,"name":"id","state":"value","type":"integer","unsigned":true,"value":"18446744073709551615"}]}
```

此示例仅说明字段形状，不是固定样本的实际偏移或 schema。对象键顺序不作为协议保证。

| 字段 | 类型与含义 |
| --- | --- |
| schema_version / kind | 数字 1 / 字符串 row_change |
| transaction_status | 固定字符串 unconfirmed，即使已经看到 XID 或 COMMIT |
| offset / table_id | 真实事件物理偏移 / 当前表 ID，始终为十进制字符串 |
| type | 数字 30、31、32，分别对应 WRITE、UPDATE、DELETE_ROWS v2 |
| database / table | TABLE_MAP 中的库表名 |
| change_index | 该事件内从零开始的变化序号；下一个事件重新从零计数 |
| operation | 字符串 insert、update 或 delete |
| before / after | 按物理列顺序排列的镜像数组；INSERT 的 before 为 null，DELETE 的 after 为 null，UPDATE 两侧均为数组 |

镜像数组保留表的全部列槽位，不按配置名字排序，也不删除 MINIMAL 模式省略的列。每个列对象都含数字 `index`、配置中的字符串 `name` 和字符串 `state`：

- `absent`：该镜像的列存在位图未记录此列；没有 type/value。
- `null`：日志明确记录 SQL NULL；没有 type/value。
- `value`：日志记录实际值；另有 type/value 及下面列出的附加字段。

列标签经过 JSON 转义；其中的换行不会拆成额外的 JSON 行。空字节串是 `value: ""`，仍属于实际值。

## 有类型的值

| type | value 与附加字段 |
| --- | --- |
| integer | signed/unsigned 均为十进制字符串；布尔 unsigned 表明解码符号属性 |
| string_bytes / blob_bytes | 小写十六进制字符串；encoding 固定为 hex，不推断字符集 |
| json | 紧凑 JSON 文本字符串，encoding 固定为 json_text，整数保留十进制原文 |
| decimal | 精确十进制字符串，保留 scale；数字 precision / scale |
| float32 / float64 | 有限 JSON 数字；bits 为原始 IEEE-754 位模式的无符号十进制字符串 |
| bit | 无符号十进制字符串；数字 bit_length |
| enum / set | 枚举索引 / 集合位掩码的无符号十进制字符串，不转换成员名称 |
| year | 对象 {year}，分量均为数字 |
| date | 对象 {year, month, day}，分量均为数字 |
| datetime | 对象 {year, month, day, hour, minute, second, microsecond}，分量均为数字 |
| time | 对象 {negative, hour, minute, second, microsecond}，negative 为布尔，其余为数字；hour 表示时长小时数 |
| timestamp | 对象 {seconds, microsecond}，均为数字；seconds 为原始 UInt32 Unix 秒 |

所有日期时间类型额外包含数字 `fractional_precision`，不做时区转换，也不将零日期强制转成应用语言的日期对象。浮点消费方若需要区分负零，应读取 bits；不要只依赖 JSON 数字解析结果。整数、BIT、SET 和 bits 使用字符串，避免经过 double 时丢失精度；Java 可按需使用 BigInteger，DECIMAL 可用 BigDecimal 并保留 scale。

JSON 的 value 是字符串，须再次用保留大整数精度的解析器读取；JSON null 为 state=value/value="null"，SQL NULL 为 state=null。完整支持范围见 [JSON 字段](json-values.md)。

## 统计与错误

只有在完整事件边界正常 EOF 后才输出一个 `kind: "row_summary"` 对象，包含：

- `schema_version: 1` 和 `transaction_status: "unconfirmed"`。
- 数字 `row_events`（解码的 ROWS 事件数）与 `changes`（变化数；一对 UPDATE 镜像计为一条变化）。
- 与事件统计含义相同的 `events`、`event_bytes`、`file_bytes`、`types`；events 统计所有遍历事件，event_bytes 为十进制字符串，其余计数为数字，types 按数字类型码升序排列。

三组真实样本各有 4 个行事件、4 条变化，操作顺序为 insert、insert、update、delete。行模式不输出单独的 event 记录。`--summary` 只输出 row_summary，但不会绕过错误。

配置、校验或行解码失败退出 1，并在 stderr 输出文本，不追加成功摘要。已经输出的完整行记录可能保留，消费方必须检查退出码及末尾 row_summary。单个 ROWS 必须整体解码成功后才输出其中的变化，因此结构错误不会返回该事件的部分变化；输出通道损坏时仍可能出现不完整写入。

## 事件分发与可信范围

FDE（15）建立或替换格式上下文并丢弃旧映射。每个 TABLE_MAP（19）都立即按库表名绑定 schema，检查列数、逐列 wire_type、原始 metadata、nullable；缺配置或失配立即失败。绑定不验证列名和整数符号属性，仍需调用者提供正确的历史 schema，不能据此识别同物理描述列互换或仅 signedness 变化。

ROWS（30/31/32）按当前 table_id 查找映射并完整解码；STMT_END_F 清空映射，解码/绑定错误也清空。以下非行事件仅作为允许的包络跳过其 body 语义，同时清空映射：QUERY（2）、STOP（3）、ROTATE（4）、XID（16）、HEARTBEAT（27）、GTID（33）、ANONYMOUS_GTID（34）、PREVIOUS_GTIDS（35）。此处并不校验 SQL、GTID 集或事务边界的业务语义，也不支持自动切换到其他日志文件。

其他类型立即报 UnsupportedEvent，不尝试恢复后继续；包含旧版行事件、PARTIAL_UPDATE_ROWS（39）和未知类型。字段支持范围与现有行解码器一致，JSON 的 opaque 扩展/partial diff、GEOMETRY、压缩事务等尚不支持。

完整事件边界 EOF、成功退出码或 row_summary 只能说明本模式扫描完成，均不能证明事务已提交。即使文件在完整 ROWS 后、XID 前结束，仍可扫描成功，行与摘要继续标记 unconfirmed；需要提交语义可使用[事务 CLI 的 --include-rows](cli-transactions.md#导出已提交行变化)或[显式事务库接口](transactions.md)。

## 验证

```text
moon test --target native
moon build --target native
python scripts/test_cli.py
python scripts/test_rows_cli.py
```

本功能新增 9 项 MoonBit 测试，覆盖参数、精确值/字节、状态清理、多行及镜像配对。28 个行模式子进程场景对三组固定 MySQL 8.0.43 捕获逐一比较官方 mysqlbinlog 的 300 个列位置，并覆盖 BOM/Unicode/转义标签、错误 schema、两层输入上限、语义损坏的有效 CRC 事件、未知事件、截断及无提交尾部。输入摘要在运行前后核对；脚本不启动数据库。

单文件行导出可加 `--stream` 逐事件读取，避免预先读入整个 binlog；schema、筛选、摘要和未确认语义保持一致，详见 [逐事件读取](cli-stream.md)。
