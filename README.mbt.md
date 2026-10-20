# MoonBinlog

纯 MoonBit 的 MySQL Binlog 解析库，正在按功能逐步开发。

当前已实现未加密 Binlog 的文件标识、v4 公共事件头、MySQL 8.0 格式描述、CRC32 校验、表映射、整数和字符串值解码。
输入使用 `BytesView`，不依赖数据库连接或第三方解析程序。

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
- `TableMapContext` 提供有容量及原始事件字节预算的映射缓存；同 ID 覆盖，失败清空，语句结束须显式 clear，新文件/格式须 reset。
- `TableColumn::decode_integer` 解码五种整数类型，显式指定 signed/unsigned，保留完整 Int64/UInt64 精度并返回消费字节数。
- `TableColumn::decode_string` 解码 VARCHAR/STRING 的长度前缀，返回原始字节及消费长度；不推断字符集，不转换或补齐 CHAR/BINARY 填充。
- 当前不包含文件遍历 CLI、其他字段类型、行事件解码、外部 schema 配置或事务处理。
- 样本由协议构造和独立 zlib 校验生成，尚未完成真实 MySQL 文件集成验证。

格式描述的 body 布局、OFF 特例与校验标志位规则见 [格式与校验说明](docs/format-checksum.md)。
表映射范围、元数据宽度及上下文生命周期见 [表映射说明](docs/table-map.md)。
整数类型、符号属性及 NULL 边界见 [整数值说明](docs/integer-values.md)。
字符串类型、长度元数据及字符集边界见 [字符串值说明](docs/string-values.md)。

## 验证

```text
moon check --warn-list +unnecessary_annotation --deny-warn
moon test
moon build
moon fmt --check
moon info
python scripts/generate_format_fixtures.py --check
python scripts/generate_table_map_fixtures.py --check
python scripts/generate_integer_fixtures.py --check
python scripts/generate_string_fixtures.py --check
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

下一批候选：BLOB/TEXT 字段值解码，等待用户继续指令。
