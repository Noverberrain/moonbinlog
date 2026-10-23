# 离线事件检查 CLI

CLI 使用文件遍历库读取本地未加密 MySQL 8.0.x Binlog，输出 TSV 或 JSON Lines 事件与统计。它检查文件标识、事件完整性、格式与校验和；不解析行值、SQL、GTID 语义或事务提交结果。

## 运行与构建

在仓库根目录执行：

```text
moon run --target native cmd/moonbinlog -- fixtures/mysql-8.0/crc32-full.binlog
moon run --target native cmd/moonbinlog -- --summary fixtures/mysql-8.0/crc32-minimal.binlog
moon run --target native cmd/moonbinlog -- --json fixtures/mysql-8.0/crc32-full.binlog
moon run --target native cmd/moonbinlog -- --json --summary fixtures/mysql-8.0/off-full.binlog
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
moonbinlog [--json] [--summary] [--max-event-bytes N] [--max-file-bytes N] [--] FILE
```

| 参数 | 含义 | 默认值 |
| --- | --- | --- |
| FILE | 一个现有普通文件的路径 | 必填 |
| --json | 使用 JSON Lines，每行一个事件或统计对象 | 关闭（使用 TSV） |
| --summary | 只输出统计，仍完整遍历与校验文件 | 关闭 |
| --max-event-bytes N | 每个事件的编码字节上限，包含头和 CRC | 16777216（16 MiB） |
| --max-file-bytes N | 读取到内存的文件大小上限 | 67108864（64 MiB） |
| -- | 其后参数按文件名处理，可用于以 `-` 开头的路径 | 无 |
| -h / --help | 显示帮助，必须单独使用 | 无 |

每个选项只能出现一次。数值只接受 ASCII 无符号十进制字节数，不接受单位、符号、十六进制或小数。事件上限范围为 19～4294967295，文件上限范围为 1～2147483647。选项可放在文件名前后，不支持 `--option=value` 形式；包含空格的路径需按 shell 规则加引号。

例如读取更大的闭合日志文件：

```text
moon run --target native cmd/moonbinlog -- --summary --max-file-bytes 134217728 path/to/binlog.000001
```

本批仍整份读入内存，不是分块扫描。打开文件后先验证它是普通文件，并检查大小上限，之后才分配读取数据。读取期间文件缩短会失败，读取结束时若发现新增字节也会失败。该检查不能提供操作系统级原子快照，应使用已经关闭或稳定复制的文件。

## 输出

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
| 1 | 读取、文件大小、格式、CRC、截断或输出失败 |
| 2 | 参数错误 |

正常结果写 stdout，错误写 stderr，参数错误同时在 stderr 显示用法。失败时不输出成功摘要：默认模式可能已输出成功读取的事件前缀，使用者必须同时检查退出码；`--summary` 模式的输入/解码失败不会输出统计前缀。输出通道本身损坏时，已经写出的内容可能不完整。

完整事件边界上的 EOF 只表明文件遍历完成，不代表事务已提交。即使文件最后一个完整事件属于未结束事务，CLI 仍可能返回 0；需要提交语义的应用应另外使用 `TransactionDecoder` 并调用 `finish()`。当前 CLI 未接入 schema 配置、行变化显示、事务汇总、实时追踪或多文件轮转。[外部 schema 库接口](schema.md) 已单独提供，但当前命令尚无 `--schema` 参数。

## 验证

```text
moon test --target native internal/cli
moon build --target native
python scripts/test_cli.py
```

13 项纯逻辑测试覆盖参数、边界值、TSV、JSON 字段类型和统计；58 个子进程场景覆盖真实文件、中文/空格路径、以选项形式命名的文件、错误退出码、CRC/截断、资源上限、未知类型及 JSON/TSV 两种输出。JSON 单元测试验证 UInt64 最大偏移保留为字符串，端到端测试验证高位 UInt32 头字段仍为精确 JSON 整数。脚本默认使用上面的 debug 构建路径，也可传 `--executable PATH` 指向其他构建产物。
