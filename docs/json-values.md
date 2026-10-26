# MySQL binary JSON 字段

`TableColumn::decode_json` 解码类型码 245（MYSQL_TYPE_JSON）的完整文档。TABLE_MAP 元数据必须是一个值为 1～4 的字节，表示字段长度前缀的宽度；真实 MySQL 样本使用 `04`。前缀为小端无符号数，随后是带根类型标记的 binary JSON；它不是 UTF-8 JSON 文本，也不按 BLOB 返回。

返回只读 `DecodedJson`，其中 `bytes_read` 包括长度前缀，`value` 为 `BinaryJsonValue`。字段后允许有其他列或下一镜像的数据，不消费这些尾部字节；字段内部的根文档必须恰好覆盖声明长度。

## 值类型与精度

| BinaryJsonValue | 含义 |
| --- | --- |
| Null / Boolean | JSON null、true、false |
| Integer(IntegerValue) | 保留 signed/unsigned，完整 Int64 / UInt64 精度 |
| DoubleNumber(value~, bits~) | 有限 Double 及原始 IEEE-754 位模式，保留负零 |
| Text | 严格 UTF-8 解码的字符串，字符串内部 BOM 作为数据保留 |
| Array | 只读、按原顺序排列的子值 |
| Object | 只读键值对，保留 MySQL 存储的成员顺序 |

支持 small / large 对象和数组、内联与非内联标量、16/32/64 位有符号和无符号整数、double、变长 UTF-8 字符串及嵌套容器。对象键按 UTF-8 字节长度、再按字节序严格排序，拒绝重复或乱序键。允许容器内部空隙、反向存放的非内联值和未使用的内联填充字节，避免拒绝更新后合法的物理布局。

`to_json_text()` 输出紧凑 JSON 文本；整数直接生成精确十进制，负零输出 `-0.0`。它不恢复原 SQL 文本、空白或对象输入顺序，也不保证 double 的文本拼写与 mysqlbinlog 相同。比较浮点值应使用数值及需要时的原始位模式。手动构造的公开枚举应由调用者保证树深、有限浮点值和 bits 与 value 一致。

## 行与 CLI

行解码自动分派为 `RowCell::JsonDocument(DecodedJson)`，ROWS、显式事务和筛选均可直接使用。SQL NULL 仍为 `RowCell::Null`，MINIMAL 中未记录的列为 `Absent`；JSON 字面量 null 是实际 JSON 值。

CLI 使用以下列对象，`value` 为 JSON 文本字符串：

```json
{"index":1,"name":"text_value","state":"value","type":"json","encoding":"json_text","value":"{\"u\":18446744073709551615}"}
```

JSON null 表示为 `state: "value", value: "null"`；SQL NULL 表示为 `state: "null"`，不含 type/value。字符串形式让外层 JSON 解析器保留整数原文；消费方再次解析 value 时仍应选择保留大整数精度的解析方式。例如 Java 可使用 BigInteger，JavaScript 直接 JSON.parse 会把大整数转换为 Number。

```sh
moon run --target native cmd/moonbinlog -- --rows --schema examples/mysql-8.0-json-schema.json fixtures/mysql-json/crc32-minimal.binlog
moon run --target native cmd/moonbinlog -- --transactions --include-rows --schema examples/mysql-8.0-json-schema.json fixtures/mysql-json/crc32-full.binlog
```

行模式仍为 unconfirmed；事务模式只在显式提交后导出完整行，错误、截断或回滚不导出该笔行值。

## 资源限制与错误

`decode_json` 的可选参数：

| 参数 | 默认值 | 允许范围 / 计数方式 |
| --- | --- | --- |
| max_value_bytes | 16777216 | 0～2147483643，仅 binary JSON 字节，不含字段长度前缀 |
| max_depth | 64 | 1～128，根值算第 1 层，叶子也计层数 |
| max_nodes | 65536 | 正整数，根、容器和每个值均算节点，键不单独计节点 |

长度和节点数在窄化转换、分配前检查。容器先检查头部、索引和子值范围，再排序检查非内联区间，拒绝键/值重叠，之后才解码字符串和递归。这避免多个条目别名引用同一大值造成重复展开。字节配额限制编码输入，不是精确堆内存配额；AST、字符串转义和 CLI 事务输出仍有额外内存开销，没有独立输出字节上限。

行解码继续使用剩余行预算限制输入视图和 JSON 字节数，深度/节点使用默认值；CLI 当前没有单独调整 JSON 配额的参数。

错误包括 UnsupportedJsonColumn、InvalidJsonMetadata、InvalidJsonLimits、JsonLimitExceeded、InvalidJsonValue、UnsupportedJsonType，字段截断继续使用 TruncatedColumnValue。file_offset 为字段长度前缀首字节的物理位置；column_index 为表列号；value_offset 相对根 binary JSON 的类型字节，指出发生错误的载荷或结构位置，不一定是类型标记本身。物理地址跨度也检查 UInt64 溢出。

## 当前范围与验证

不支持 opaque 类型标记 15（包括 MySQL 扩展 decimal、日期时间等）、PARTIAL_UPDATE_ROWS 的 JSON diff、空 binary JSON 文档或 GEOMETRY。非有限 double、非法 UTF-8、越界/重叠引用、异常字符串长度及根尾部垃圾明确失败。普通完整 JSON 文档中的 decimal 扩展仍属于 opaque，不能据此宣称所有 MySQL JSON 值均已支持。

新增 12 项独立 MoonBit 测试及 1 项可执行文档测试，包含 31 个独立有效向量、24 个无效向量、逐字节截断/变异、各类配额、行与事务接入。113 个 JSON CLI 场景覆盖精确整数、转义、负零、错误与回滚、未提交隔离、筛选和 summary 验证。另固定三组真实 MySQL 8.0.43 JSON 日志，对照官方 mysqlbinlog 的 42 个列位置；说明见 [JSON 捕获](../fixtures/mysql-json/README.md)。已有其他类型的三组真实样本及回归保留。

协议依据固定为 MySQL commit `9fc8d60003b4eee32767c1e30942f222c3508c31` 的 [json_binary.h](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/sql-common/json_binary.h) 和 [json_binary.cc](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/sql-common/json_binary.cc)。实现和向量独立编写，没有复制上游代码。
