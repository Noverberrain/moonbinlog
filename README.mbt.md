# MoonBinlog

纯 MoonBit 的 MySQL Binlog 解析库，正在按功能逐步开发。

当前已实现未加密 Binlog 的文件标识、v4 公共事件头、MySQL 8.0 格式描述、CRC32 校验、表映射、常用字段值、ROWS v2 事件，以及显式边界的事务型 RBR 汇总。
输入使用 `BytesView`，不依赖数据库连接或第三方解析程序。

现已提供 `BinlogFileReader`，可顺序遍历已读入内存的完整文件字节，并为每个事件返回原始视图、body、真实偏移和当前格式上下文。

查看本地文件可运行 `moon run --target native cmd/moonbinlog -- FILE`；仅查看统计添加 `--summary`，机器处理可添加 `--json` 输出 JSON Lines。文件默认上限 64 MiB，参数、输出协议和退出码见 [CLI 文档](docs/cli.md)。

`--rows --schema PATH` 自动以 JSON Lines 显示带列名的 INSERT / UPDATE / DELETE，所有行与摘要标记为 `unconfirmed`。精确值、原始字节和缺失列规则见[行变化 CLI](docs/cli-rows.md)。

## 使用示例

```mbt check
///|
test "validate a file signature and decode a common header" {
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

## 当前接口与边界

- `BinlogFileReader::new` 校验文件标识；`next()` 按事件大小遍历并校验，首个事件要求 FDE。未知类型保留原始数据，错误后永久停止；本层不进行业务事件分发。详见[文件遍历说明](docs/file-traversal.md)。

- `validate_file_header` 校验前四字节 `FE 62 69 6E`，不据此确认 Binlog 版本。
- `EventHeader::parse` 读取前 19 字节，保留时间、类型、服务端 ID、事件长度、日志位置和标志。
- 调用者传入真实 `file_offset`；它与日志头中的 `next_position` 分开保存。
- 事件长度下限为 19 字节；默认上限为 16 MiB，可显式调整。
- 数据截断、错误文件标识、非法事件长度及上限配置通过 `DecodeError` 返回。
- `EventHeader::parse` 允许仅输入头部；格式描述及 payload 接口要求包含完整事件。
- `FormatDescription::parse` 验证 MySQL 8.0.x、Binlog v4、19 字节公共头和事件长度表，建立不可变校验上下文。
- `FormatDescription::payload` 检查后续事件的完整性，返回去除公共头和校验尾部的 body；它不解码 body 的业务语义。
- CRC32 策略验证普通事件并移除四字节 CRC；OFF 策略保留普通事件的全部 body。
- 格式描述自身始终校验 CRC32，校验时仅忽略它的 in-use 标志位。
- 遇到新格式描述必须重新解析建立上下文；未知算法、版本和格式明确报错。
- `TableMap::parse` 解析表 ID、库表名、列类型、逐列原始元数据及 nullable 标志，可选元数据按 TLV 保留。
- `SchemaConfig::parse` 校验外部 JSON 配置；`bind` 按库表名、列数及逐列物理描述匹配 TABLE_MAP，返回列标签和整数符号向量，详见 [schema 说明](docs/schema.md)。
- `TableMapContext` 提供有容量及原始事件字节预算的映射缓存；同 ID 覆盖，失败清空。decode_rows 会在语句结束时清理，手动消费仍须显式 clear，新文件/格式须 reset。
- `TableColumn::decode_integer` 解码五种整数类型，显式指定 signed/unsigned，保留完整 Int64/UInt64 精度并返回消费字节数。
- `TableColumn::decode_string` 解码 VARCHAR/STRING 的长度前缀，返回原始字节及消费长度；不推断字符集，不转换或补齐 CHAR/BINARY 填充。
- `TableColumn::decode_blob` 支持 BLOB/TEXT 的 1～4 字节长度前缀，返回原始字节及消费长度；默认内容上限为 16 MiB，可显式配置。
- `TableColumn::decode_decimal` 支持 NEWDECIMAL 的 65 位精度与最多 30 位小数，返回保留 scale 的精确十进制字符串及消费长度。
- `TableColumn::decode_temporal` 支持 DATE、YEAR、DATETIME2、TIME2、TIMESTAMP2，保留日期分量、带符号时长或原始时间戳秒数及微秒，不进行时区转换。
- `TableColumn::decode_floating` 解码 FLOAT/DOUBLE，返回相应精度的有限值、原始位模式及消费长度；保留负零和次正规数，明确拒绝 NaN/无穷大。
- `TableColumn::decode_bit` 支持 BIT(1)～BIT(64)，返回 UInt64、声明位宽和消费长度；大端解码并屏蔽部分首字节的未使用高位。
- `TableColumn::decode_enum_set` 解析 STRING 元数据中内嵌的 ENUM/SET，分别返回枚举索引或集合位掩码及消费长度，不推断成员名称或数量。
- `TableMap::decode_row_image` 组合已有字段解码器，处理列存在/紧凑 NULL 位图，区分缺失列、NULL 和实际值，返回按表列号排列的结果及消费长度；整数符号属性必须显式提供。
- `TableMapContext::decode_rows` 校验 v2 行事件、查找表映射并解码多行/更新配对，成功遇到 STMT_END_F 或任意解析失败均清空缓存，返回表定义快照。
- `TransactionBoundary::parse` 校验 QUERY/XID 边界；`TransactionDecoder` 缓存显式 BEGIN 后的行事件，在 XID/COMMIT 返回事务，ROLLBACK 或错误时丢弃，EOF 必须调用 finish 检查未结束事务。
- CLI 已支持文件读取、事件列表与统计，以及外部 schema 驱动的行变化 JSON；没有启用事务汇总，单独的行输出仍不代表已经提交。其他字段类型、GTID/XA/DDL/隐式事务或非事务表语义尚未实现。
- 合成样本由协议构造和独立 zlib 校验生成；另有三组真实 MySQL 8.0.43 日志，已与官方 mysqlbinlog 逐字段对照，详见[集成验证](docs/mysql-integration.md)。Java 客户端差分尚未完成。

格式描述的 body 布局、OFF 特例与校验标志位规则见 [格式与校验说明](docs/format-checksum.md)。
表映射范围、元数据宽度及上下文生命周期见 [表映射说明](docs/table-map.md)。
整数类型、符号属性及 NULL 边界见 [整数值说明](docs/integer-values.md)。
字符串类型、长度元数据及字符集边界见 [字符串值说明](docs/string-values.md)。
BLOB/TEXT 长度、安全边界及支持范围见 [BLOB 值说明](docs/blob-values.md)。
DECIMAL 的精度、符号及分组校验见 [DECIMAL 值说明](docs/decimal-values.md)。
日期时间类型、微秒精度和零日期边界见 [日期时间值说明](docs/temporal-values.md)。
FLOAT/DOUBLE 的精度、位模式及非有限值策略见 [浮点值说明](docs/floating-values.md)。
BIT 的元数据、字节序和填充位策略见 [BIT 值说明](docs/bit-values.md)。
ENUM/SET 的元数据、存储宽度和成员边界见 [ENUM/SET 值说明](docs/enum-set-values.md)。
单个行镜像的位图、字段分派和资源边界见 [行镜像说明](docs/row-images.md)。
行事件布局、多行配对及缓存生命周期见 [ROWS 事件说明](docs/rows-events.md)。
事务型 RBR 子集、连续偏移与提交/回滚边界见 [事务说明](docs/transactions.md)。

## 验证

```text
moon check --warn-list +unnecessary_annotation --deny-warn
moon test --target native
moon build --target native
moon fmt --check
moon info
python scripts/generate_format_fixtures.py --check
python scripts/generate_table_map_fixtures.py --check
python scripts/generate_integer_fixtures.py --check
python scripts/generate_string_fixtures.py --check
python scripts/generate_blob_fixtures.py --check
python scripts/generate_decimal_fixtures.py --check
python scripts/generate_temporal_fixtures.py --check
python scripts/generate_floating_fixtures.py --check
python scripts/generate_bit_fixtures.py --check
python scripts/generate_enum_set_fixtures.py --check
python scripts/generate_row_image_fixtures.py --check
python scripts/generate_rows_event_fixtures.py --check
python scripts/generate_transaction_fixtures.py --check
python scripts/verify_mysql_fixtures.py --check
python scripts/test_cli.py
python scripts/test_rows_cli.py
python scripts/generate_schema_example.py --check
```

公共接口由 `moon info` 生成在 `pkg.generated.mbti`。

## 协议依据

- [MySQL 8.0 事件头偏移与长度定义](https://github.com/mysql/mysql-server/blob/8.0/libbinlogevents/include/binlog_event.h)
- [MySQL 8.0 事件头字段](https://github.com/mysql/mysql-server/blob/8.0/libbinlogevents/include/control_events.h)

实现根据格式独立编写，当前没有复制上游实现代码或测试数据。

## 开源许可证

Copyright 2026 Noverberrain.

本项目采用 [Apache License 2.0](LICENSE)，版权声明见 [NOTICE](NOTICE)。

## 开发节奏

每次完成一个功能后暂停，报告行为变化、验证结果和新增行数。
源码、测试、生成接口及文档/配置分别统计；行数包含空行与注释，不作为有效代码量或完成度指标。

下一批候选：CLI 显式事务汇总。等待用户继续指令。
