# 外部 schema 配置 v1

`SchemaConfig` 为调用者提供列名和整数 signed/unsigned 信息，并在使用前与 TABLE_MAP 的物理列描述逐位置匹配。库接口接收 JSON 文本；CLI 的 `--rows --schema PATH` 输出行变化，`--transactions --schema PATH` 解码并汇总显式事务，详见[行变化 CLI](cli-rows.md)与[事务 CLI](cli-transactions.md)。原有事件模式输出协议保持不变。

## 从日志起草

可先运行 `moonbinlog --schema-template FILE` 提取物理列描述，列名填 column_N、整数 unsigned 填 null，须对照历史 DDL 确认后再交给配置解析器。它不推导列名、signedness 或历史演进，同名表物理结构冲突会失败，详见 [草稿生成](cli-schema-template.md)。

## 配置格式

一个包含两列的表配置示例：

```json
{
  "schema_version": 1,
  "tables": [
    {
      "database": "shop",
      "table": "orders",
      "columns": [
        {"name": "id", "wire_type": 8, "metadata": "", "nullable": false, "unsigned": true},
        {"name": "title", "wire_type": 15, "metadata": "9001", "nullable": true}
      ]
    }
  ]
}
```

| 字段 | 含义 |
| --- | --- |
| schema_version | 数字 1；不接受字符串或其他版本 |
| tables | 表配置数组；允许空数组 |
| database / table | 原始库表名，按精确字符串对匹配，区分大小写 |
| columns | 非空数组，顺序必须对应 TABLE_MAP 中的物理列顺序 |
| name | 调用者提供的列标签，不用于 SQL 执行 |
| wire_type | 0～255 的整值数字，必须是当前 TABLE_MAP 解析器接受的类型码 |
| metadata | 原始逐列元数据的十六进制字符串；不含 `0x`、分隔符或长度前缀，可使用大小写 hex |
| nullable | 必填布尔值，必须与 TABLE_MAP 中该列的标志一致 |
| unsigned | TINYINT/SMALLINT/INT/BIGINT/MEDIUMINT（1/2/3/8/9）必填布尔值；其他类型必须省略此字段 |

元数据字节顺序与日志一致，不统一转换成大端或小端。例如 `9001` 是 VARCHAR 最大 400 字节的两字节元数据；它不代表 400 个字符。`1406` 是 DECIMAL(20,6)，`06` 是 DATETIME2/TIME2/TIMESTAMP2 的 fsp=6；零元数据宽度类型使用空字符串。

配置只核对元数据类型与字节宽度，不代替各字段解码器对 precision、scale、fsp 等数值语义的校验。配置一个 TABLE_MAP 支持、但行值解码尚不支持的类型，不会让行解码器自动支持该类型。

完整的 20 列真实样本配置见 [mysql-8.0-schema.json](../examples/mysql-8.0-schema.json)。它从仓库固定的 MySQL 8.0.43 TABLE_MAP 获取物理描述，从专用测试 DDL 获取列名和整数 signedness，不查询业务数据库。

JSON 列使用 wire_type=245、metadata="04"、nullable 按实际表定义配置，省略 unsigned。两列示例见 [mysql-8.0-json-schema.json](../examples/mysql-8.0-json-schema.json)，已由三组真实日志回归验证。元数据表示长度前缀宽度，不能写成 JSON 文本编码；解码限制见 [JSON 字段](json-values.md)。

## 库接口与使用顺序

1. 将 JSON 文本交给 `SchemaConfig::parse(text)`。输入为 `StringView`，本层不进行文件 I/O 或 UTF-8 转换。
2. `config.get(database, table)` 返回只读 `TableSchema?`，可查看按顺序保存的 `SchemaColumn`。
3. 每次收到新的 TABLE_MAP 后调用 `config.bind(table_map)`。成功返回 `BoundTableSchema`，含表映射快照、schema 快照及 `integer_unsigned`。
4. 将 `bound.integer_unsigned` 交给既有行镜像或 ROWS 解码器，并用 `bound.schema.columns[i].name` 标注同位置的值。不要改变 `Absent` / `Null` 的含义。

例如在已有表映射和完整 ROWS 事件的应用中，调用关系为：

```moonbit
let config = @moonbinlog.SchemaConfig::parse(schema_text)
let bound = config.bind(table_map)
let rows = context.decode_rows(
  rows_event,
  file_offset=rows_offset,
  integer_unsigned=bound.integer_unsigned,
)
```

这里的 `context` 仍须已应用对应 TABLE_MAP，`rows_event` 仍须是同一张表的事件。示例省略应用自身的数据读取和错误处理；配置接口不会自动替上下文选择表，也不会把 schema 绑定到某个永久 table_id。

## 匹配与可信范围

绑定首先精确查找 `(database, table)`，然后比较列数，并逐位置比较 `wire_type`、完整原始 `metadata`、`nullable`。不匹配立即返回错误，不返回部分 signedness 向量。

**匹配成功只说明这些物理描述一致。** 列名和整数符号属性由调用者负责提供，本层不从可选 TLV 推导或核对它们。同物理类型的列交换位置、仅改变整数 signedness、列重命名等情况可能不改变当前比较的描述，因此不能据此证明配置属于正确的历史 schema。

库表和列名按精确字符串处理，不模拟 MySQL 的大小写、排序规则或 SQL 标识符规则。库表键使用二元组，`("a.b", "c")` 与 `("a", "b.c")` 不冲突；同一表内重复列标签、重复库表对均拒绝。不同表可以使用相同列名。

新 TABLE_MAP 必须重新绑定。已有绑定保留原快照，不因后续 table_id 重用或调用者重新解析配置而改变。该接口不推导 DDL、schema 演进、版本时间线、列字符集、ENUM/SET 成员或存储引擎。

## 配置错误和资源上限

`SchemaError` 独立于原有 `DecodeError`：

| 错误 | 含义 |
| --- | --- |
| InvalidSchema | JSON、版本、未知字段、类型、重复项或字段值无效，含配置字段路径与原因 |
| InvalidSchemaLimits | 上限配置不是正数 |
| SchemaLimitExceeded | 文本、表数、列数或嵌套深度超限 |
| MissingTableSchema | 没有对应库表配置，含当前 TABLE_MAP 真实偏移 |
| SchemaMismatch | 列数或描述不一致，含真实偏移及可选的零起始列号 |

默认最多 1024 张表、每表 1024 列、输入 1048576 个 UTF-16 code units。三个限制可通过 `max_tables`、`max_columns`、`max_input_units` 设置，均必须为正。输入大小在 JSON 解析前检查；它是字符串单位上限，不能当作 UTF-8 文件字节数或精确堆内存上限。

CLI 在分配文件内容前另行检查 schema 文件不超过 4 MiB，严格解码 UTF-8（接受一个开头 BOM），随后使用上述默认配置配额。`--max-file-bytes` 只控制 Binlog，不改变 schema 的上限。

JSON 嵌套最多 16 层；名字要求 1～256 个 UTF-16 单位且不包含 NUL。未知字段和重复 JSON 对象成员均拒绝，包括转义后同名的键及被覆盖的嵌套对象。字符串中的冒号、引号、反斜杠和括号不会被当作结构字段或嵌套层次。

## 验证与示例重建

```text
moon test --target native --filter "schema*"
python scripts/generate_schema_example.py --check
```

17 项黑盒测试及 1 个可执行文档注释测试覆盖结构、重复成员、转义、字段宽度、配额、失配、表 ID 重用和快照。三组真实 MySQL CRC32/FULL、CRC32/MINIMAL、OFF/FULL 样本确认绑定生成的 signedness 可用于现有行解码，并精确保留 UInt64 最大值。

`scripts/generate_schema_example.py` 是针对固定 20 列样本的离线导出脚本，不是通用 SQL 解析器或业务库 schema 抓取工具。重新生成示例：

```text
python scripts/generate_schema_example.py
```
