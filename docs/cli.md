# 离线 Binlog CLI

CLI 使用文件遍历库读取本地未加密 MySQL 8.0.x Binlog。默认检查文件标识、事件完整性、格式与校验和，输出 TSV 或 JSON Lines 事件与统计；`--rows --schema PATH` 输出[有类型的行变化](cli-rows.md)，`--transactions --schema PATH` 输出[显式事务汇总](cli-transactions.md)。只有事务模式解析受支持的 BEGIN/COMMIT/ROLLBACK 与 XID 边界；四种模式都不解释通用 SQL 或 GTID 语义；`--schema-template FILE` 生成[待确认的 schema 草稿](cli-schema-template.md)。

## 运行与构建

在仓库根目录执行：

```text
moon run --target native cmd/moonbinlog -- fixtures/mysql-8.0/crc32-full.binlog
moon run --target native cmd/moonbinlog -- --summary fixtures/mysql-8.0/crc32-minimal.binlog
moon run --target native cmd/moonbinlog -- --json fixtures/mysql-8.0/crc32-full.binlog
moon run --target native cmd/moonbinlog -- --json --summary fixtures/mysql-8.0/off-full.binlog
moon run --target native cmd/moonbinlog -- --rows --schema examples/mysql-8.0-schema.json fixtures/mysql-8.0/crc32-full.binlog
moon run --target native cmd/moonbinlog -- --transactions --schema examples/mysql-8.0-schema.json fixtures/mysql-8.0/crc32-full.binlog
moon run --target native cmd/moonbinlog -- --transactions --include-rows --schema examples/mysql-8.0-schema.json fixtures/mysql-8.0/crc32-full.binlog
moon run --target native cmd/moonbinlog -- --rows --schema examples/mysql-8.0-schema.json --table sample fixtures/mysql-8.0/crc32-full.binlog
moon run --target native cmd/moonbinlog -- --help
```

构建并在 PowerShell 中直接运行可执行文件：

```powershell
moon build --target native
& './_build/native/debug/build/cmd/moonbinlog/moonbinlog.exe' --summary 'fixtures/mysql-8.0/off-full.binlog'
```

本批实际验证环境为 Windows / MSVC、MoonBit v0.10.15、moon 0.1.20261012。入口限定 native，使用官方 `moonbitlang/async@0.21.3` 的文件/标准输出接口，以及 `moonbitlang/x@0.5.5` 的进程退出接口。解析核心没有引入这些 I/O 调用。

MSVC 首次编译 async 依赖的 `internal/event_loop/fs.c` 时会出现一条 `EINVAL` 宏重定义 C4005 警告；构建及运行成功，本项目未修改依赖源码。其他操作系统与工具链的 CLI 运行尚未实际验证。

## 参数

```text
moonbinlog [--json] [--summary] [--chain [--max-total-bytes N]] [--decode-previous-gtids] [--decode-rotate | --schema-template | --rows | --transactions [--include-rows]] [--schema PATH] [--database NAME] [--table NAME] [--max-event-bytes N] [--max-file-bytes N] [--] FILE [FILE...]
```

| 参数 | 含义 | 默认值 |
| --- | --- | --- |
| FILE | 一个现有普通文件；--chain 时按顺序提供 2～128 份 | 必填 |
| --chain | 显式多文件事件浏览，自动 JSON Lines，核对轮转连接 | 关闭 |
| --max-total-bytes N | 多文件输入总预算，只能与 --chain 使用 | 268435456 |
| --decode-rotate | 事件模式输出轮转详情，自动使用 JSON Lines；--summary 仍验证轮转 | 关闭 |
| --decode-previous-gtids | 事件模式输出历史 SID/GTID 区间，自动 JSON Lines；可组合轮转/多文件，summary 仍验证 | 关闭 |
| --json | 使用 JSON Lines，每行一个事件或统计对象 | 关闭（使用 TSV） |
| --summary | 只输出统计，仍完整遍历与校验文件 | 关闭 |
| --use-table-metadata | 提取可用列名和整数符号，仅用于 --schema-template；缺失时保留占位值 | 关闭 |
| --schema-template | 生成待确认的 schema 草稿；仅在正常 EOF 后输出一个 JSON 对象 | 关闭 |
| --rows | 解码行变化，自动输出 JSON Lines；必须指定 --schema | 关闭 |
| --transactions | 汇总显式事务，自动输出 JSON Lines；必须指定 --schema，与 --rows 互斥 | 关闭 |
| --include-rows | 在提交对象中导出完整 row_changes；必须与 --transactions 一起使用 | 关闭 |
| --schema PATH | UTF-8 schema v1 JSON 文件；必须选择 --rows 或 --transactions | 无 |
| --database NAME | 精确匹配库名；必须选择行/事务模式 | 不限制 |
| --table NAME | 精确匹配表名；可与 --database 组合 | 不限制 |
| --max-event-bytes N | 每个事件的编码字节上限，包含头和 CRC | 16777216（16 MiB） |
| --max-file-bytes N | 读取到内存的文件大小上限 | 67108864（64 MiB） |
| -- | 其后参数按文件名处理，可用于以 `-` 开头的路径 | 无 |
| -h / --help | 显示帮助，必须单独使用 | 无 |

每个选项只能出现一次。数值只接受 ASCII 无符号十进制字节数，不接受单位、符号、十六进制或小数。事件上限范围为 19～4294967295，文件上限范围为 1～2147483647。选项可放在文件名前后，不支持 `--option=value` 形式；包含空格的路径需按 shell 规则加引号。

筛选名字要求 1～256 个 UTF-16 单位、不含 NUL，区分大小写，点号和星号均按普通名字字符处理。行模式选择行事件，事务模式选择包含匹配行事件的完整提交/回滚区间；过滤不跳过任何输入解码，schema 仍须覆盖所有经过的表。启用时只在摘要附加 filter 与 selected_* 字段；没有筛选参数的输出形状不变，详见[库表筛选](cli-filters.md)。

例如读取更大的闭合日志文件：

```text
moon run --target native cmd/moonbinlog -- --summary --max-file-bytes 134217728 path/to/binlog.000001
```

本批仍整份读入内存，不是分块扫描。打开文件后先验证它是普通文件，并检查大小上限，之后才分配读取数据。读取期间文件缩短会失败，读取结束时若发现新增字节也会失败。该检查不能提供操作系统级原子快照，应使用已经关闭或稳定复制的文件。

schema 文件使用同样的普通文件与稳定性检查，硬上限为 4 MiB；严格 UTF-8 解码，接受一个开头 BOM，然后按配置库默认的 1048576 个 UTF-16 单位、1024 张表、每表 1024 列、16 层嵌套检查。此上限不受 --max-file-bytes 改变，详见 [schema 格式](schema.md)。事务模式额外受既有事务解码器固定配额约束，详见[事务上限](cli-transactions.md#配额)。

## 输出

本节及下一节说明事件模式。行模式使用独立的 `row_change` / `row_summary` 对象，字段见[行输出协议](cli-rows.md)；事务模式使用 `transaction` / `transaction_summary`，见[事务输出协议](cli-transactions.md)。

默认首行为字段名，后续每个事件一行：

```text
offset  type  name  bytes  next_position  timestamp  server_id  flags  checksum
```

实际分隔符为 TAB。`offset` 是真实文件起点，`next_position` 是头中保留的原值；`timestamp` 是原始 Unix 秒，不转换时区；整数值按十进制输出。`checksum` 表示当前事件实际采用的 CRC32/OFF 策略，FDE 自身总是显示 CRC32，即使它为后续事件声明 OFF。

未知类型使用 `UNKNOWN`，同时保留数值类型码；已命名类型也只完成本层完整性检查，不代表其 body 已解码。

完整遍历成功后追加摘要和按数字类型升序排列的计数。CRC32/FULL 样本的首行摘要为：

```text
summary	events=14	event_bytes=2495	file_bytes=2499
```

`event_bytes` 为所有事件编码长度之和，`file_bytes` 还包含四字节文件标识。后续每行依次为 `type`、数值类型、名称和数量。`--summary` 仅省略事件表，仍执行全部解析；空白尾部、损坏事件和未知格式均不会被跳过。

## JSON Lines 输出协议（v1）

`--json` 输出逐行独立的紧凑 JSON 对象，不输出 TSV 表头，也不是一个顶层 JSON 数组。每个对象包含数字 `schema_version: 1`。完整事件使用 `kind: "event"`，完整遍历成功后最后一行使用 `kind: "summary"`。对象键的排列顺序不作为协议保证。

以下展示仅含一个 122 字节 FDE 的文件的输出形状，每行都是独立 JSON：

```jsonl
{"schema_version":1,"kind":"event","offset":"4","type":15,"name":"FORMAT_DESCRIPTION_EVENT","bytes":122,"next_position":126,"timestamp":1792685918,"server_id":810043,"flags":0,"checksum":"CRC32"}
{"schema_version":1,"kind":"summary","events":1,"event_bytes":"122","file_bytes":126,"types":[{"type":15,"name":"FORMAT_DESCRIPTION_EVENT","count":1}]}
```

| 对象 | 字段类型与含义 |
| --- | --- |
| event | `offset` 为十进制字符串；`type`、`bytes`、`next_position`、`timestamp`、`server_id`、`flags` 为 JSON 整数；`name`、`checksum` 为字符串，与 TSV 的含义一致 |
| summary | `events`、`file_bytes` 为 JSON 整数；`event_bytes` 为十进制字符串；`types` 为按数字类型码升序排列的数组 |
| types 数组元素 | `type`、`count` 为 JSON 整数，`name` 为字符串；只包含出现过的类型 |

所有 UInt64 字段始终使用十进制字符串，包括很小的偏移和总字节数，避免 JSON 消费端经过 IEEE-754 double 时丢失精度。其余数值的当前范围可以被 double 精确表示。Java 程序可按需把字符串转换为 `BigInteger`，不要先转为 double；JavaScript 可使用 `BigInt`。

`--json --summary` 只输出最后一个统计对象，仍完整检查所有事件。失败时不输出统计对象；普通 JSON 模式可能已输出若干完整事件对象，消费方必须检查进程退出码和最后的 summary，不能把事件前缀当作完整结果。错误信息仍是 stderr 中的文本，不混入 stdout；帮助输出仍为普通文本。

PowerShell 中读取 JSON Lines 的例子（在仓库根目录，先构建 native）：

```powershell
$records = & './_build/native/debug/build/cmd/moonbinlog/moonbinlog.exe' --json 'fixtures/mysql-8.0/crc32-full.binlog' |
  ForEach-Object { $_ | ConvertFrom-Json }
if ($LASTEXITCODE -ne 0) { throw 'Binlog scan failed' }
$records | Where-Object { $_.kind -eq 'event' } | Select-Object offset, name, bytes
```

## 错误和退出码

| 退出码 | 含义 |
| --- | --- |
| 0 | 文件遍历成功，或显示帮助成功 |
| 1 | 读取、文件大小、格式、CRC、截断、schema、行/事务解码或输出失败 |
| 2 | 参数错误 |

正常结果写 stdout，错误写 stderr，参数错误同时在 stderr 显示用法。失败时不输出成功摘要：默认模式可能已输出成功读取的事件前缀，使用者必须同时检查退出码；`--summary` 模式的输入/解码失败不会输出统计前缀。输出通道本身损坏时，已经写出的内容可能不完整。

事件/行模式在完整事件边界 EOF 可返回 0，即使事务尚未结束；行模式所有结果均标记 `unconfirmed`。事务模式则在 EOF 调用 `finish()`，未结束事务报错，不输出该笔事务或成功摘要。行/事务模式均拒绝未支持事件。CLI 尚未提供实时追踪或多文件轮转。

## 验证

```text
moon test --target native internal/cli
moon build --target native
python scripts/test_cli.py
python scripts/test_rows_cli.py
python scripts/test_transactions_cli.py
python scripts/test_filters_cli.py
```

20 项内部包测试覆盖参数、边界值、TSV、JSON 字段类型、统计和精确匹配；根包另有 7 项行测试、7 项事务测试、4 项提交行导出测试和 4 项筛选状态测试。58 个事件、28 个行模式、72 个事务及 89 个筛选子进程场景合计 247 个；覆盖真实文件、300 个官方列位置、路径/编码、精度、大小配额、schema、错误前缀及完整事务选择。脚本默认使用上面的 debug 构建路径，也可传 `--executable PATH` 指向其他构建产物。

JSON 字段新增独立 `python scripts/test_json_cli.py` 回归（可用 `--exe PATH` 指定构建产物），覆盖 113 个场景和三组 JSON 实际捕获的 42 个官方列位置；加上以上四组共 360 个 CLI 场景。协议见 [JSON 字段](json-values.md)。

`--schema-template FILE` 可生成待确认的 schema 草稿，与行/事务/summary/schema/筛选选项互斥，仅在完整校验到 EOF 后输出一个 JSON。列名和整数符号需手动确认，详见 [生成 schema 草稿](cli-schema-template.md)。该模式新增 82 个子进程场景，六组 CLI 合计 442 个，已加入统一 CI。

`--decode-rotate FILE` 自动使用 JSON Lines，轮转事件增加精确位置、原始 hex 和可用 UTF-8 文件名，规则见 [轮转 CLI](cli-rotate.md)。该选项只用于事件模式，与 schema/行/事务模式及库表筛选互斥；--summary 仍解析轮转结构。新增 148 个端到端场景，八组 CLI 合计 682 个。

`--chain FILE1 FILE2 ...` 增加显式多文件事件浏览和来源标记，最终输出 chain_summary；文件名/目标位置、顺序、配额及失败前缀规则见 [多文件 CLI](cli-chain.md)。其他模式仍只接受单文件。新增 78 个子进程场景，九组 CLI 合计 760 个。

历史 GTID 详情可用 `--decode-previous-gtids FILE`，可组合 --decode-rotate、--chain、--summary，字段和配额见 [历史 GTID CLI](cli-previous-gtids.md)。默认模式仍将类型 35 body 作为不透明数据，行/事务语义范围保持原样。
