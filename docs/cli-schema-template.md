# 从 Binlog 生成 schema 草稿

`--schema-template` 读取单个本地 Binlog 中的 TABLE_MAP，输出一份 schema v1 JSON 草稿，省去手填逐列物理类型和元数据的步骤。列名和整数符号仍需对照该日志时期的 DDL 确认。

```sh
moon run --target native cmd/moonbinlog -- --schema-template fixtures/mysql-json/crc32-full.binlog
```

成功时 stdout 只有一个紧凑 JSON 对象和换行，没有事件列表或统计尾部。`--json` 可以显式添加；不能组合 `--rows`、`--transactions`、`--include-rows`、`--schema`、`--summary` 或库表筛选。`--max-file-bytes`、`--max-event-bytes`、`--` 文件名分隔符继续可用，退出码沿用 0/1/2。

保存为 UTF-8 后编辑即可，例如已构建 CLI 的 PowerShell 用法：

```powershell
$draftText = & './_build/native/debug/build/cmd/moonbinlog/moonbinlog.exe' --schema-template fixtures/mysql-json/crc32-full.binlog
if ($LASTEXITCODE -ne 0) { throw 'Schema template generation failed' }
[System.IO.File]::WriteAllText((Join-Path $PWD 'schema.draft.json'), ($draftText -join "`n"), [System.Text.UTF8Encoding]::new($false))
```

确认进程成功后再写文件，避免把失败时的空 stdout 保存成配置。命令本身只读输入，不直接创建配置文件。

## 需要确认的内容

例如两列 INT/JSON 表会输出以下内容（这里为方便阅读进行了排版）：

```json
{
  "schema_version": 1,
  "tables": [{
    "database": "moonbinlog_fixture",
    "table": "sample",
    "columns": [
      {"name":"column_1","wire_type":3,"metadata":"","nullable":false,"unsigned":null},
      {"name":"column_2","wire_type":245,"metadata":"04","nullable":true}
    ]
  }]
}
```

1. 将 column_1、column_2 等占位标签改成对应物理列位置的名称。生成器不解释可选 TABLE_MAP 列名 TLV。
2. 对 TINYINT/SMALLINT/INT/BIGINT/MEDIUMINT，将 `unsigned: null` 改为正确的 true 或 false。其他类型不包含 unsigned，不能随意添加。
3. 对照历史建表结构确认库表、列顺序和符号属性，保存为 UTF-8，再用 `--rows --schema PATH` 或 `--transactions --schema PATH` 验证实际日志。

含整数的草稿故意不能直接通过 SchemaConfig::parse，避免未经确认就把 BIGINT 当作 signed。没有整数的表可以直接满足配置格式，但占位列名仍只是标签；生成器没有证明它与真实列名一致。若日志从未包含某张表的 TABLE_MAP，草稿也不会凭空补上它。

## 合并和冲突规则

以精确的 `(database, table)` 名称对归并，保留首次出现顺序；不会把带点的两个不同名称对拼接成同一个键。表 ID 重用、改变 flags、位图末尾填充位或可选元数据不会产生重复表。

同名表的物理列数、逐列 wire_type、原始 metadata、nullable 必须一致，否则报 `ConflictingTable`，包含库表名及首次/当前 TABLE_MAP 的物理偏移，不输出草稿。跨 QUERY、FDE 也不会清掉这项冲突检查。此时应人工区分历史版本，不能用一份静态 schema 覆盖整段变化。

同物理描述的列互换、列重命名或 signedness 变化可能无法检测；不能把“没有冲突”当成 DDL 一致或 schema 历史已还原的证明。

## 验证范围和配额

先读取完整文件，在正常 EOF 后才渲染和写 stdout。文件标识、格式、所有事件的 framing/CRC、每个 TABLE_MAP 的结构均经过验证；未知或其他事件 body 不作语义解释，ROWS、GTID、DDL、事务提交和 JSON 值不在本模式的验证范围内。schema 生成成功不代表日志可完成行解码或事务导出。

默认文件上限 64 MiB、事件上限 16 MiB；TABLE_MAP 每表最多 1024 列。草稿最多 1024 张不同名称的表，紧凑输出预算为 1048576 个 UTF-16 单位，按 wrapper 和每表分隔符保守计数，可能比实际长度多一个单位。后两个限制没有 CLI 参数。输出预算不是精确堆内存配额，构建当前单表、表映射快照及文件内存另有开销。没有 TABLE_MAP 时输出空 tables 数组。

文件读取、校验、表映射、结构冲突或配额失败均退出 1，stderr 含错误，stdout 不输出草稿；输出通道失败仍可能留下不完整写入。参数错误退出 2。生成器不会修改输入，不能从失败前缀中恢复一份局部草稿。

## 回归

新增 8 项独立 MoonBit 测试及 1 项实现注释中的可执行文档测试；82 个 CLI 子进程场景覆盖六组真实 MySQL 捕获、手工确认后行/事务输出一致、重复/冲突映射、精确名称对、Unicode/转义、错误参数、两层字节上限、1024 张表上限、输出预算、CRC/截断及失败时无部分输出。回归加入统一 CI 入口，常规运行不启动数据库。

原有 [schema 配置规范](schema.md)、[行输出](cli-rows.md)、[事务输出](cli-transactions.md) 和 [筛选](cli-filters.md) 的行为保持一致。此功能没有增加生产依赖或修改根包解析 API。
