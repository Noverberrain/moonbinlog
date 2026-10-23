# MoonBinlog

**用 MoonBit 读取 MySQL Binlog，从二进制事件到有类型的行变化。**

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)
[![Language: MoonBit](https://img.shields.io/badge/Language-MoonBit-orange.svg)](https://www.moonbitlang.com/)

MoonBinlog 是一个纯 MoonBit 的 MySQL 8.0 Binlog 解析库。它接收 `BytesView`，完成事件校验、表映射和字段解码，将 ROWS v2 事件转换为 INSERT / UPDATE / DELETE 行变化，并支持显式事务区间的提交与回滚汇总。

项目面向 MoonBit 十月黑客松，正在逐步开发。当前提供可组合的协议解析库，以及读取本地文件、显示事件列表与统计的 native CLI。

## 为什么做 MoonBinlog

Binlog 记录数据库的数据变化，是理解 CDC、数据同步和变更审计的重要入口。MoonBinlog 希望为 MoonBit 提供可复用的 MySQL Binlog 解码能力，让上层工具可以基于结构化事件继续开发。

- **纯 MoonBit 实现**：解析过程不依赖 MySQL 连接、Java 服务或外部解析程序。
- **保留数据含义**：区分缺失列、NULL 和实际值；整数保留完整精度，DECIMAL 使用精确字符串。
- **显式管理状态**：表映射按语句清理，待定行变化在事务提交后才作为提交结果返回。
- **可定位的错误**：通过 `DecodeError` 报告截断、非法元数据、校验失败和资源上限等问题。
- **可复现的验证**：独立构造协议样本，并固定三组真实 MySQL 日志与官方工具输出，记录 SHA-256，逐字段比较行镜像。

离线分析、CDC 和审计是后续应用方向；目前没有数据库订阅、数据投递或 SQL 回放功能。

## 当前支持什么

| 层次 | 已实现能力 | 说明 |
| --- | --- | --- |
| 文件标识与事件头 | 未加密 Binlog magic、v4 公共事件头 | 保存真实物理偏移，事件长度有上限 |
| 离线文件遍历 | 顺序切分、FDE 上下文切换、事件完整性校验 | 输入完整内存视图，未知事件保留原始数据 |
| 离线 CLI | 文件读取、TSV / JSON Lines 事件与类型统计 | 支持大小上限和错误退出码，不自动解码 body |
| 格式与完整性 | MySQL 8.0.x FORMAT_DESCRIPTION、CRC32 / OFF | 检查格式、完整事件及校验尾部 |
| 表映射 | TABLE_MAP、逐列元数据、可选 TLV | 有容量限制的缓存，不自动推导完整 schema |
| 整数 | TINYINT / SMALLINT / MEDIUMINT / INT / BIGINT | signed / unsigned 由调用者明确提供 |
| 字符串与二进制 | VARCHAR / STRING、常规 BLOB / TEXT | 保留原始字节，不推断字符集 |
| 精确小数 | NEWDECIMAL | 最高 65 位精度、30 位小数，保留 scale |
| 日期与时间 | DATE / YEAR / TIMESTAMP2 / DATETIME2 / TIME2 | 支持 0～6 位小数，不进行时区转换 |
| 其他标量 | FLOAT / DOUBLE、BIT、ENUM / SET | 浮点拒绝非有限值；枚举返回索引，集合返回位掩码 |
| 行镜像 | 列存在位图、紧凑 NULL 位图、有类型字段 | 区分 `Absent`、`Null` 和实际值 |
| 行事件 | WRITE / UPDATE / DELETE_ROWS v2 | 支持多行及 UPDATE 的 before / after 配对 |
| 显式事务 | BEGIN → TABLE_MAP / ROWS → XID / COMMIT / ROLLBACK | 提交返回完整结果，回滚丢弃，EOF 检查未结束事务 |

**验证状态：232 项测试和 58 个 CLI 场景通过，运行验证使用 native 后端。** 已对三组真实 MySQL 8.0.43 日志完成官方 `mysqlbinlog` 对照，覆盖 CRC32/OFF、FULL/MINIMAL，共 15 个镜像、300 个列位置；其他版本及 Java 客户端差分尚未完成。详见[集成验证结果](docs/mysql-integration.md)。

## 解析流程

```text
调用者提供 Binlog 字节 → BinlogFileReader 逐事件遍历
        │
        ├── 文件标识 + EventHeader
        │
        └── FormatDescription：格式及 CRC32 / OFF 校验
                │
                ├── TableMapContext：表定义与列元数据
                │       └── RowsEvent：Insert / Update / Delete
                │               └── RowImage：Absent / Null / 有类型的值
                │
                └── TransactionDecoder：缓存显式事务内的行事件
                        ├── XID / COMMIT → CommittedTransaction
                        └── ROLLBACK / 错误 / EOF 截断 → 丢弃待定数据
```

这里展示的是已有解析层的组合关系。CLI 已封装文件读取与事件列表，业务事件分发仍需调用者负责；事务解码器只接受受支持的连续显式事务区间。

## 快速上手

### 从源码验证

安装 MoonBit 工具链后，在终端执行：

```sh
git clone https://github.com/Noverberrain/moonbinlog.git
cd moonbinlog
moon check --warn-list +unnecessary_annotation --deny-warn
moon test --target native
moon build --target native
```

当前开发环境为 Windows、MoonBit v0.10.15、moon 0.1.20261012，native 构建使用 MSVC。其他环境和后端的运行兼容性仍待验证。重建协议样本还需要 Python 3。

### 查看本地 Binlog 文件

```sh
moon run --target native cmd/moonbinlog -- fixtures/mysql-8.0/crc32-full.binlog
moon run --target native cmd/moonbinlog -- --summary fixtures/mysql-8.0/off-full.binlog
moon run --target native cmd/moonbinlog -- --json --summary fixtures/mysql-8.0/crc32-full.binlog
```

默认显示 TSV 事件表及类型统计，`--json` 切换为逐行 JSON 对象，`--summary` 仅输出统计。JSON 的 UInt64 字段用十进制字符串保留精度。文件默认限制 64 MiB，单事件默认限制 16 MiB。退出码 0 表示遍历成功，1 表示读取或解析失败，2 表示参数错误。该命令不输出行变化或事务结果；完整参数和构建产物路径见 [CLI 使用说明](docs/cli.md)。

### 最小解析示例

下面的示例演示文件标识校验与公共头解析；相同逻辑在 [可执行文档](README.mbt.md) 中接受工具链检查。

在使用该库的 MoonBit 包中导入 `Noverberrain/moonbinlog`，别名为 `moonbinlog`：

```text
import {
  "Noverberrain/moonbinlog",
}
```

将以下测试放入已配置依赖的包中：

```moonbit
///|
test "decode a binlog event header" {
  @moonbinlog.validate_file_header([0xfe, 0x62, 0x69, 0x6e])
  let header : Bytes = [
    0x78, 0x56, 0x34, 0x12, 0x1e, 0x01, 0x00, 0x00, 0x00, 0x13, 0x00, 0x00, 0x00,
    0x17, 0x00, 0x00, 0x00, 0x00, 0x00,
  ]
  let decoded = @moonbinlog.EventHeader::parse(header, file_offset=4)
  assert_eq(decoded.event_size, 19U)
  assert_eq(decoded.next_position, 23U)
}
```

这份 19 字节数据只用于演示公共头，不是完整 ROWS 事件。`EventHeader::parse` 可以只接收头部；格式、表映射、行事件和事务接口需要完整事件数据。

### 继续使用行事件与事务接口

对完整文件字节，可先使用 `BinlogFileReader::new(data)`，循环调用 `next()`，直到返回 `None`。每个结果提供 `header`、`raw`、`body` 和 `format`；遍历错误后需丢弃活动的上层状态。完整说明见[离线文件遍历](docs/file-traversal.md)。

1. 用 `FormatDescription::parse` 解析格式描述，建立校验上下文。
2. 用 `TableMapContext` 管理表映射，调用 `decode_rows` 获取行变化；整数列的符号属性需由外部 schema 提供。
3. 需要提交语义时，使用 `TransactionDecoder::new`，从明确的 BEGIN 开始逐事件调用 `feed`。
4. 处理返回的 `Committed` 或 `RolledBack` 结果，并在输入结束时调用 `finish()` 检查截断事务。

ROWS 的 `STMT_END_F` 表示语句结束，不代表事务提交。事务内遇到不支持的事件会报错并丢弃待定结果，不能直接跳过后继续提交。

## 使用边界

- 当前面向 MySQL **8.0.x、Binlog v4、未加密、常规 ROWS v2** 子集，不承诺兼容 MariaDB 或其他 MySQL 版本。
- 尚未实现 GTID、XA、DDL / 隐式事务、自动提交推断、SAVEPOINT、压缩事务及旧版 / partial 行事件。
- JSON、GEOMETRY 等字段类型、字符集转换、列名和完整外部 schema 配置尚未实现。
- 事务汇总以调用者已知使用事务型表为前提，无法从当前表映射推断存储引擎及非事务表回滚语义。
- 默认单事件上限 16 MiB；事务上限为 4096 个事件、10000 个行变化、64 MiB 编码字节。详细配额及配置范围见各层文档。
- 真实文件验证目前仅覆盖 Windows / MySQL 8.0.43 的三组固定样本；性能基准和生产环境验证尚未完成。

## 文档导航

| 主题 | 文档 |
| --- | --- |
| API 总览与可执行示例 | [README.mbt.md](README.mbt.md) · [生成的公共接口](pkg.generated.mbti) |
| 事件格式与校验 | [格式描述 / CRC32](docs/format-checksum.md) |
| 文件级遍历 | [内存文件遍历、偏移与错误处理](docs/file-traversal.md) |
| 命令行工具 | [CLI 参数、输出和退出码](docs/cli.md) |
| 真实文件验证 | [MySQL 8.0.43 与官方 mysqlbinlog 对照](docs/mysql-integration.md) |
| 表结构上下文 | [TABLE_MAP 与缓存生命周期](docs/table-map.md) |
| 整数与精确小数 | [整数](docs/integer-values.md) · [DECIMAL](docs/decimal-values.md) |
| 字符串与二进制 | [字符串](docs/string-values.md) · [BLOB / TEXT](docs/blob-values.md) |
| 日期与时间 | [日期时间](docs/temporal-values.md) |
| 其他字段 | [浮点](docs/floating-values.md) · [BIT](docs/bit-values.md) · [ENUM / SET](docs/enum-set-values.md) |
| 行变化 | [行镜像](docs/row-images.md) · [ROWS v2 事件](docs/rows-events.md) |
| 提交与回滚 | [事务边界、状态和资源限制](docs/transactions.md) |
| 开发记录 | [逐功能实现与验证记录](docs/progress.md) |

## 验证与样本

测试覆盖正常解码、截断输入、非法元数据、CRC 损坏、资源配额、表映射生命周期、事务提交 / 回滚及错误后的状态清理。完整验证命令见 [可执行文档的验证部分](README.mbt.md#验证)。

`fixtures/` 保存各类样本说明和清单，`scripts/generate_*_fixtures.py` 生成对应的 MoonBit 测试数据。可在 PowerShell 中检查全部生成结果是否与仓库一致：

```powershell
Get-ChildItem scripts/generate_*_fixtures.py | ForEach-Object {
  python $_.FullName --check
  if ($LASTEXITCODE -ne 0) { throw "Fixture check failed: $($_.Name)" }
}
python scripts/verify_mysql_fixtures.py --check
if ($LASTEXITCODE -ne 0) { throw 'MySQL fixture check failed' }
```

[真实 MySQL 样本](fixtures/mysql-8.0/README.md)包含采集 SQL、原始日志、官方解码输出和摘要。普通回归直接使用仓库中的固定数据，无需启动 MySQL；重新采集可使用独立临时实例的脚本。

协议参考固定到 MySQL 源码 commit `9fc8d60003b4eee32767c1e30942f222c3508c31`，具体依据记录在各功能文档中。实现和测试样本独立编写，当前没有复制上游实现代码或测试数据。

## 开发路线

- [x] 文件标识、事件头、格式描述与 CRC32
- [x] 表映射、常用字段值与行镜像
- [x] ROWS v2 多行解析与 UPDATE 配对
- [x] 显式事务边界、提交 / 回滚与配额检查
- [x] 离线 Binlog 文件字节遍历（内存视图接口）
- [x] 三组真实 MySQL 8.0.43 文件集成及官方 mysqlbinlog 对照
- [ ] 更多字段 / 事件类型
- [x] 最小离线 CLI：文件读取、事件列表与统计
- [x] CLI 的 JSON Lines 输出与机器处理示例
- [ ] 外部 schema 配置，供后续 CLI 行变化解码使用（下一步候选）

路线会根据真实样本验证结果调整，勾选项只代表当前限定范围内的实现。

## 参与贡献

欢迎通过 Issue 提供使用场景、最小复现或协议兼容性问题。提交问题时请附上工具链版本、MySQL 版本、校验模式、事件类型、错误偏移和预期行为；提交日志样本前请移除业务敏感数据。

修改后请运行检查、native 测试、构建、`moon fmt --check`、`moon info` 及相关样本一致性检查；CLI 的端到端验证运行 `python scripts/test_cli.py`。项目目前按功能逐批推进，公共 API 仍可能调整。

## 开源许可证

Copyright 2026 Noverberrain.

本项目采用 [Apache License 2.0](LICENSE)，版权声明见 [NOTICE](NOTICE)。
