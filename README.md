# MoonBinlog

**用 MoonBit 读取 MySQL Binlog，从二进制事件到有类型的行变化。**

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)
[![Language: MoonBit](https://img.shields.io/badge/Language-MoonBit-orange.svg)](https://www.moonbitlang.com/)

MoonBinlog 是一个纯 MoonBit 的 MySQL 8.0 Binlog 解析库。它接收 `BytesView`，完成事件校验、表映射和字段解码，将 ROWS v2 事件转换为 INSERT / UPDATE / DELETE 行变化，并支持显式事务区间的提交与回滚汇总。

项目面向 MoonBit 十月黑客松，正在逐步开发。当前提供可组合的协议解析库，以及读取本地文件、显示事件列表、带列名行变化和显式事务汇总的 native CLI。

## 为什么做 MoonBinlog

Binlog 记录数据库的数据变化，是理解 CDC、数据同步和变更审计的重要入口。MoonBinlog 希望为 MoonBit 提供可复用的 MySQL Binlog 解码能力，让上层工具可以基于结构化事件继续开发。

- **纯 MoonBit 实现**：解析过程不依赖 MySQL 连接、Java 服务或外部解析程序。
- **保留数据含义**：区分缺失列、NULL 和实际值；整数保留完整精度，DECIMAL 使用精确字符串。
- **显式管理状态**：表映射按语句清理，待定行变化在事务提交后才作为提交结果返回。
- **可定位的错误**：通过 `DecodeError` 报告截断、非法元数据、校验失败和资源上限等问题。
- **可复现的验证**：独立构造协议样本，并固定九组真实 MySQL 日志与官方工具输出，记录 SHA-256，逐字段比较行镜像。

离线分析、CDC 和审计是后续应用方向；目前没有数据库订阅、数据投递或 SQL 回放功能。

## 当前支持什么

| 层次 | 已实现能力 | 说明 |
| --- | --- | --- |
| 文件标识与事件头 | 未加密 Binlog magic、v4 公共事件头 | 保存真实物理偏移，事件长度有上限 |
| 离线文件遍历 | 顺序切分、FDE 上下文切换、事件完整性校验 | 输入完整内存视图，未知事件保留原始数据 |
| 离线 CLI | 事件统计、外部 schema 行变化、显式事务汇总与已提交行导出 | 行模式标记 unconfirmed，事务模式可按整笔提交导出行值 |
| 格式与完整性 | MySQL 8.0.x FORMAT_DESCRIPTION、CRC32 / OFF | 检查格式、完整事件及校验尾部 |
| 日志轮转 | ROTATE_EVENT 目标文件标识和 UInt64 起始位置 | 库接口及可选 CLI 详情；保留文件名字节，尚不自动跟随 |
| 历史 GTID 集合 | PREVIOUS_GTIDS_EVENT 的 SID 与精确整数区间 | 库接口及可选 CLI 详情；带配额，尚不绑定事务 GTID |
| 事务 GTID 事件 | GTID_EVENT / ANONYMOUS_GTID_EVENT 标识、时钟与扩展 | 库接口及可选 CLI 详情；事件本身不确认提交 |
| 表映射 | TABLE_MAP、逐列元数据、可选 TLV | 有容量限制的缓存，不自动推导完整 schema |
| 外部 schema | JSON 配置、表映射绑定及从日志生成草稿 | 物理描述自动提取，列名和整数符号需确认 |
| 整数 | TINYINT / SMALLINT / MEDIUMINT / INT / BIGINT | signed / unsigned 由调用者明确提供 |
| 字符串与二进制 | VARCHAR / STRING、常规 BLOB / TEXT | 保留原始字节，不推断字符集 |
| 精确小数 | NEWDECIMAL | 最高 65 位精度、30 位小数，保留 scale |
| 日期与时间 | DATE / YEAR / TIMESTAMP2 / DATETIME2 / TIME2 | 支持 0～6 位小数，不进行时区转换 |
| 其他标量 | FLOAT / DOUBLE、BIT、ENUM / SET | 浮点拒绝非有限值；枚举返回索引，集合返回位掩码 |
| JSON | 完整 binary JSON 对象、数组与普通标量 | 精确整数，严格 UTF-8；opaque / partial diff 尚不支持 |
| 行镜像 | 列存在位图、紧凑 NULL 位图、有类型字段 | 区分 `Absent`、`Null` 和实际值 |
| 行事件 | WRITE / UPDATE / DELETE_ROWS v2 | 支持多行及 UPDATE 的 before / after 配对 |
| 显式事务 | BEGIN → TABLE_MAP / ROWS → XID / COMMIT / ROLLBACK | 提交返回完整结果，回滚丢弃，EOF 检查未结束事务 |
| GTID 事务绑定 | GTID / 匿名前缀与紧邻显式事务的提交/回滚关联 | 独立库接口及 CLI --with-gtid，含前缀配额和失败终止 |

**验证状态：376 项 MoonBit 测试，以及事件/行变化/事务/筛选/JSON/schema 草稿/元数据/轮转/多文件/历史集合/事务 GTID/绑定导出/真实 GTID 十三组 CLI 共 2272 个场景通过，运行验证使用 native 后端。** 已对九组真实 MySQL 8.0.43 日志完成官方 `mysqlbinlog` 对照，覆盖 CRC32/OFF、FULL/MINIMAL：原有字段共 300 个列位置，JSON 场景共 42 个列位置，真实 GTID 场景另有 42 个列位置及 9 笔 assigned 事务；其他版本及 Java 客户端差分尚未完成。详见[集成验证结果](docs/mysql-integration.md)、[JSON 捕获](fixtures/mysql-json/README.md)及 [真实 GTID 捕获](fixtures/gtid-real/README.md)。

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

这里展示的是已有解析层的组合关系。CLI 的行模式封装文件读取、schema 绑定与行事件分发；事务模式组合既有事务解码器，仅处理受支持的连续显式事务区间，并在空闲时跳过明确允许的文件级包络。

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

### 持续集成

[CI 工作流](.github/workflows/ci.yml) 在推送 main、向 main 提交 PR 或手动触发时运行 Windows native 检查，固定 MoonBit/core `0.10.15+943464bfa` 与 Python `3.13.9`。覆盖格式、严格检查、全部测试、构建、接口差异、样本和十三组 CLI 回归，无需启动 MySQL。

Windows 本地已准备好工具链后，也可运行同一入口：

```powershell
./scripts/ci.ps1
```

CI 的[首次基线运行（19102ce）](https://github.com/Noverberrain/moonbinlog/actions/runs/40107571568)已通过；后续提交结果以各自 Actions 运行记录为准。版本更新与排查方法见 [CI 说明](docs/ci.md)。

### 查看本地 Binlog 文件

```sh
moon run --target native cmd/moonbinlog -- fixtures/mysql-8.0/crc32-full.binlog
moon run --target native cmd/moonbinlog -- --summary fixtures/mysql-8.0/off-full.binlog
moon run --target native cmd/moonbinlog -- --json --summary fixtures/mysql-8.0/crc32-full.binlog
```

默认显示 TSV 事件表及类型统计，`--json` 切换为逐行 JSON 对象，`--summary` 仅输出统计。JSON 的 UInt64 字段用十进制字符串保留精度。文件默认限制 64 MiB，单事件默认限制 16 MiB。退出码 0 表示遍历成功，1 表示读取或解析失败，2 表示参数错误；完整参数和构建产物路径见 [CLI 使用说明](docs/cli.md)。

### 按顺序浏览多份日志

```sh
moon run --target native cmd/moonbinlog -- --chain --summary mysql-bin.000001 mysql-bin.000002
```

显式提供 2～128 份文件，按每份 FDE 独立校验，并核对中间文件的末尾轮转是否指向下一文件 basename、位置是否为 4。事件带来源文件，成功后输出全链统计；仅用于事件浏览，详见 [多文件 CLI](docs/cli-chain.md)。

### 查看日志轮转目标

```sh
moon run --target native cmd/moonbinlog -- --decode-rotate fixtures/mysql-8.0/crc32-full.binlog
```

该选项自动输出 JSON Lines，在轮转事件中增加目标位置、文件名 hex 和可用的 UTF-8 文本；--summary 仍验证轮转结构，默认事件模式保持兼容。详情见 [轮转 CLI](docs/cli-rotate.md)。

### 先生成 schema 草稿

```sh
moon run --target native cmd/moonbinlog -- --schema-template fixtures/mysql-json/crc32-full.binlog
```

自动提取库表和逐列物理描述；列名为 column_N 占位标签，整数 unsigned 为 null，须按历史 DDL 确认后再使用。重复表映射会合并，同名表结构冲突会报错，成功 EOF 后才输出整份 JSON。保存和确认步骤见 [schema 草稿](docs/cli-schema-template.md)。增加 `--use-table-metadata` 可读取日志中已有的列名和整数符号属性，缺失时保留占位值，损坏或冲突时失败，见 [元数据提取](docs/template-metadata.md)。

### 查看带列名的行变化

```sh
moon run --target native cmd/moonbinlog -- --rows --schema examples/mysql-8.0-schema.json fixtures/mysql-8.0/crc32-full.binlog
```

`--rows` 与 `--schema PATH` 必须一起使用，自动输出 JSON Lines。每条 INSERT / UPDATE / DELETE 包含库表名、列标签及 before / after，保留缺失列、NULL、精确整数与小数；原始字符串和 BLOB 使用 hex。增加 `--summary` 只输出行变化统计，但仍执行解码。

所有行记录及摘要均标记 `transaction_status: "unconfirmed"`，本模式不组装提交事务。配置必须匹配日志对应的历史 schema，列名及整数符号属性由提供者负责。输出字段与限制见[行变化 CLI](docs/cli-rows.md)和 [schema 配置](docs/schema.md)。

### 读取 JSON 字段

```sh
moon run --target native cmd/moonbinlog -- --rows --schema examples/mysql-8.0-json-schema.json fixtures/mysql-json/crc32-minimal.binlog
```

普通完整 JSON 已接入行与事务导出。列值使用 `type: "json", encoding: "json_text"`，value 为保留整数原文的 JSON 文本字符串，SQL NULL 与 JSON null 分开表示；消费方再次解析时需要保留大整数精度。支持范围和配额见 [JSON 字段说明](docs/json-values.md)。

### 查看显式事务汇总

```sh
moon run --target native cmd/moonbinlog -- --transactions --schema examples/mysql-8.0-schema.json fixtures/mysql-8.0/crc32-full.binlog
moon run --target native cmd/moonbinlog -- --transactions --include-rows --schema examples/mysql-8.0-schema.json fixtures/mysql-8.0/crc32-full.binlog
```

每笔 BEGIN → XID / COMMIT 完成后输出起止偏移、XID、行变化数与各表计数，ROLLBACK 输出丢弃数量；增加 `--include-rows` 在提交对象内附带 `row_changes`，其中行记录均标记 committed，保留列名及有类型的 before/after。默认仍只导出计数，`--summary` 只输出全文件统计。

事务未结束、遇到未知事件或超过配额会失败，不输出该笔待定事务。此模式要求调用者已知涉及的表支持事务；--with-gtid 只关联已有前缀，不推断 DDL 或隐式提交；详见[事务 CLI](docs/cli-transactions.md)。

### 按库表筛选输出

```sh
moon run --target native cmd/moonbinlog -- --rows --schema examples/mysql-8.0-schema.json --database moonbinlog_fixture --table sample fixtures/mysql-8.0/crc32-full.binlog
```

`--database NAME` 和 `--table NAME` 可单独或组合使用，按精确名称匹配。行模式输出匹配的行事件；事务模式按整笔选择，只要其中有匹配的行事件就保留完整事务，包含其中其他表的行值。所有输入仍完整解码，摘要保留全文件计数并增加 selected_* 计数，详见[筛选规则](docs/cli-filters.md)。

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
2. 用 `TableMapContext` 管理表映射，调用 `decode_rows` 获取行变化；可用 `SchemaConfig::parse` 与 `bind` 校验外部配置并提供整数符号属性及列标签，见 [schema 说明](docs/schema.md)。
3. 需要提交语义时，使用 `TransactionDecoder::new`，从明确的 BEGIN 开始逐事件调用 `feed`。
4. 处理返回的 `Committed` 或 `RolledBack` 结果，并在输入结束时调用 `finish()` 检查截断事务。

ROWS 的 `STMT_END_F` 表示语句结束，不代表事务提交。事务内遇到不支持的事件会报错并丢弃待定结果，不能直接跳过后继续提交。

## 使用边界

- 当前面向 MySQL **8.0.x、Binlog v4、未加密、常规 ROWS v2** 子集，不承诺兼容 MariaDB 或其他 MySQL 版本。
- 库接口及 CLI --with-gtid 已支持 GTID 前缀绑定显式事务；XA、DDL / 隐式事务、自动提交推断、SAVEPOINT、压缩事务及旧版 / partial 行事件仍未实现。
- JSON 的 opaque 扩展、partial diff、GEOMETRY 和字符集转换尚未实现；外部 schema 目前提供列名与整数符号属性，历史演进及自动推导尚未实现。
- 事务汇总以调用者已知使用事务型表为前提，无法从当前表映射推断存储引擎及非事务表回滚语义。
- 默认单事件上限 16 MiB；事务上限为 4096 个事件、10000 个行变化、64 MiB 编码字节。详细配额及配置范围见各层文档。
- 真实文件验证目前仅覆盖 Windows / MySQL 8.0.43 的六组固定样本；性能基准和生产环境验证尚未完成。

事务导出可组合 `--transactions --with-gtid --schema PATH`，在提交/回滚结果中附带紧邻的 GTID/匿名信息，可继续组合行导出和库表筛选，见 [GTID 事务 CLI](docs/cli-gtid-transactions.md)。

查看已分配或匿名 GTID 事件可使用 `--decode-gtid FILE`，输出精确身份、逻辑时钟和可选扩展，见 [GTID CLI](docs/cli-gtid.md)。

查看历史 GTID 声明可使用 `--decode-previous-gtids FILE`，可与 `--chain`、`--decode-rotate` 或 `--summary` 组合；端点以精确十进制字符串输出，见 [历史 GTID CLI](docs/cli-previous-gtids.md)。

## 文档导航

| 主题 | 文档 |
| --- | --- |
| API 总览与可执行示例 | [README.mbt.md](README.mbt.md) · [生成的公共接口](pkg.generated.mbti) |
| 事件格式与校验 | [格式描述 / CRC32](docs/format-checksum.md) |
| 日志轮转 | [ROTATE_EVENT 库接口](docs/rotate-events.md) · [CLI 详情输出](docs/cli-rotate.md) |
| 多文件事件浏览 | [显式文件顺序、连接核对和来源统计](docs/cli-chain.md) |
| JSON 字段 | [binary JSON、精度、配额与 CLI 表示](docs/json-values.md) |
| 文件级遍历 | [内存文件遍历、偏移与错误处理](docs/file-traversal.md) |
| 命令行工具 | [CLI 参数、输出和退出码](docs/cli.md) |
| Schema 草稿 | [从 TABLE_MAP 生成并确认配置](docs/cli-schema-template.md) |
| 命令行行变化 | [schema 接入、行 JSON 与提交状态](docs/cli-rows.md) |
| 命令行事务 | [显式提交/回滚汇总、统计与配额](docs/cli-transactions.md) |
| 输出筛选 | [库表精确匹配、整笔事务与计数范围](docs/cli-filters.md) |
| 真实文件验证 | [MySQL 8.0.43 与官方 mysqlbinlog 对照](docs/mysql-integration.md) |
| 表结构上下文 | [TABLE_MAP 与缓存生命周期](docs/table-map.md) |
| 外部配置 | [schema v1 格式、绑定及可信范围](docs/schema.md) · [真实样本配置](examples/mysql-8.0-schema.json) |
| 整数与精确小数 | [整数](docs/integer-values.md) · [DECIMAL](docs/decimal-values.md) |
| 字符串与二进制 | [字符串](docs/string-values.md) · [BLOB / TEXT](docs/blob-values.md) |
| 日期与时间 | [日期时间](docs/temporal-values.md) |
| 其他字段 | [浮点](docs/floating-values.md) · [BIT](docs/bit-values.md) · [ENUM / SET](docs/enum-set-values.md) |
| 行变化 | [行镜像](docs/row-images.md) · [ROWS v2 事件](docs/rows-events.md) |
| 提交与回滚 | [事务边界、状态和资源限制](docs/transactions.md) |
| GTID 信息 | [历史集合](docs/previous-gtids.md) · [历史集合 CLI](docs/cli-previous-gtids.md) · [事务 GTID 事件](docs/gtid-events.md) · [GTID CLI](docs/cli-gtid.md) · [事务绑定](docs/gtid-transactions.md) · [绑定导出 CLI](docs/cli-gtid-transactions.md) |
| 开发记录 | [逐功能实现与验证记录](docs/progress.md) |
| 自动化检查 | [CI 触发、固定版本与本地复现](docs/ci.md) |

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
python scripts/verify_json_fixtures.py --check
if ($LASTEXITCODE -ne 0) { throw 'JSON fixture check failed' }
python scripts/generate_schema_example.py --check
if ($LASTEXITCODE -ne 0) { throw 'Schema example check failed' }
```

[真实 MySQL 样本](fixtures/mysql-8.0/README.md)包含采集 SQL、原始日志、官方解码输出和摘要。普通回归直接使用仓库中的固定数据，无需启动 MySQL；重新采集可使用独立临时实例的脚本。

协议参考固定到 MySQL 源码 commit `9fc8d60003b4eee32767c1e30942f222c3508c31`，具体依据记录在各功能文档中。实现和测试样本独立编写，当前没有复制上游实现代码或测试数据。

## 开发路线

- [x] 文件标识、事件头、格式描述与 CRC32
- [x] ROTATE_EVENT 轮转信息解析（库接口）
- [x] PREVIOUS_GTIDS_EVENT 历史集合解析及 CLI 详情
- [x] GTID_EVENT / ANONYMOUS_GTID_EVENT 字段解析及 CLI 详情
- [x] GTID 前缀与显式事务绑定（库接口及可选 CLI 导出）
- [x] 三组真实 GTID=ON 日志、非空历史及官方事务/行值对照
- [x] 显式多文件事件浏览与轮转连接核对（CLI）
- [x] 表映射、常用字段值与行镜像
- [x] ROWS v2 多行解析与 UPDATE 配对
- [x] 显式事务边界、提交 / 回滚与配额检查
- [x] 离线 Binlog 文件字节遍历（内存视图接口）
- [x] 三组真实 MySQL 8.0.43 文件集成及官方 mysqlbinlog 对照
- [x] 完整 binary JSON 普通标量、容器及行/事务接入
- [ ] 更多字段 / 事件类型
- [x] 最小离线 CLI：文件读取、事件列表与统计
- [x] CLI 的 JSON Lines 输出与机器处理示例
- [x] 外部 schema 配置与表映射绑定（库接口）
- [x] 从 Binlog 生成 schema 草稿，检查同名表物理结构冲突
- [x] CLI 接入 schema 并显示未确认提交的行变化
- [x] CLI 显式事务提交/回滚汇总
- [x] 事务模式按整笔提交导出有类型行变化
- [x] CLI 按库表筛选行事件或完整事务

路线会根据真实样本验证结果调整，勾选项只代表当前限定范围内的实现。

## 参与贡献

欢迎通过 Issue 提供使用场景、最小复现或协议兼容性问题。提交问题时请附上工具链版本、MySQL 版本、校验模式、事件类型、错误偏移和预期行为；提交日志样本前请移除业务敏感数据。

修改后请运行 `./scripts/ci.ps1`，或独立执行检查、native 测试、构建、格式、接口及样本检查；CLI 验证为 `scripts/test_cli.py`、`scripts/test_rows_cli.py`、`scripts/test_transactions_cli.py`、`scripts/test_filters_cli.py`、`scripts/test_json_cli.py`、`scripts/test_schema_template_cli.py`、`scripts/test_template_metadata_cli.py`、`scripts/test_rotate_cli.py` 和 `scripts/test_chain_cli.py`。项目目前按功能逐批推进，公共 API 仍可能调整。

## 开源许可证

Copyright 2026 Noverberrain.

本项目采用 [Apache License 2.0](LICENSE)，版权声明见 [NOTICE](NOTICE)。
