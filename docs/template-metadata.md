# 使用 TABLE_MAP 元数据补齐草稿

```sh
moon run --target native cmd/moonbinlog -- --schema-template --use-table-metadata fixtures/mysql-8.0/crc32-full.binlog
```

`--use-table-metadata` 只能与 `--schema-template` 配合使用，默认关闭。启用后解码 SIGNEDNESS（类型 1）和 COLUMN_NAME（类型 4）可选字段，自动填充可用的列名和整数 unsigned。其他参数、输入限制、退出码和正常 EOF 后一次输出的规则与[普通草稿](cli-schema-template.md)相同。

仓库六组真实 MySQL 8.0.43 捕获均包含所需元数据；该命令输出与对应的 examples/mysql-8.0-schema.json 或 examples/mysql-8.0-json-schema.json 配置逐项一致，可在核对后用于 --rows 或 --transactions。这是对已有捕获的验证，不承诺所有日志都含完整元数据。

## 缺失、合并与冲突

| 输入情况 | 处理 |
| --- | --- |
| 缺 COLUMN_NAME | 继续使用 column_N 占位标签 |
| 缺 SIGNEDNESS | 整数 unsigned 保留 null，配置解析要求人工确认 |
| 两种字段独立出现 | 分别填充已有信息，不要求同时出现 |
| 后续同名表补齐此前缺失的字段 | 合并到同一个草稿条目，不改变表顺序 |
| 已有信息在后续映射中缺失 | 保留已有信息 |
| 已知列名或整数符号属性发生矛盾 | ConflictingTable，报告首次与当前映射偏移，不输出部分草稿 |
| 适用元数据内容无效或重复 | InvalidTemplateMetadata，含 TABLE_MAP 物理偏移、字段类型与原因 |
| 其他可选字段 | 保留底层 TLV 结构检查，不解释内容 |

同名表物理列描述冲突仍会失败；查询事件或 FDE 不清掉检查结果。冲突的首次偏移指本表第一次出现的位置，可能早于相关提示字段第一次出现的位置。没加选项时继续使用占位列名/符号属性，并忽略可选字段内容的语义差别。

自动填充来源是日志中的元数据，没有查询数据库、还原 DDL 或解释字符集。仍需核对日志时期及库表结构；相同物理描述且缺少提示的历史重命名/重排无法可靠识别。单个字段完整、结构合法也不证明其他事件的行值或事务语义有效。

## 格式和校验

COLUMN_NAME 是按物理列顺序排列的 packed-length UTF-8 字符串序列，名称数量必须恰好等于列数。支持单字节及 0xfc/0xfd/0xfe 长度形式，检查截断和 UInt64 长度后再窄化。拒绝空名、NUL、无效 UTF-8、超过 schema v1 的 256 UTF-16 单位及重复名称；字符串中的 BOM 保留为名称数据，转义字符交给 JSON 编码器。额外名称或尾部字节报错。依据为 [MySQL 写入逻辑](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/sql/log_event.cc)和[读取逻辑](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/libbinlogevents/src/rows_event.cpp)。

SIGNEDNESS 按符合条件的列计数，高位在前；占位类型为 DECIMAL(0)、TINY/SHORT/LONG/FLOAT/DOUBLE(1～5)、LONGLONG(8)、INT24(9)、YEAR(13)、NEWDECIMAL(246)。YEAR、浮点和小数也消耗位，导出的 unsigned 只用于五种整数，避免错移后续位。字节数必须等于 ceil(此计数/8)，末尾未使用低位忽略。依据为 [has_signedess_information_type](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/sql/field_common_properties.h)及上述写入/读取逻辑；[元数据类型定义](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/libbinlogevents/include/rows_event.h)说明字段标识及出现条件。

相同适用类型的 TLV 出现两次也会失败，不能通过后面的字段覆盖前面的字段。相关名字/符号信息在合并前完整校验；其他 TLV 的语义、字符集、枚举成员和主键尚不解释。实现独立编写，没有复制上游代码。

## 配额与验证

沿用最多 1024 张表、每表 1024 列及 1048576 UTF-16 单位紧凑输出预算；补齐名字后按新条目大小重新计费，不重复累加整张表，也不能用补齐绕过上限。超限或解析失败不输出草稿。单个名称在 UTF-8 解码前限制为 1024 字节，随后检查 schema 的字符串长度；该上限是内存校验边界，不是 MySQL 列名合法性声明。

新增 6 项独立 MoonBit 测试与 92 个 CLI 场景。六组实际捕获的自动配置直接参与行/事务输出对照；独立 Python 编码覆盖跨字节位图、混合 YEAR/浮点/小数、长 Unicode/转义/BOM 名称、多种 packed 长度、部分提示与增量补齐、冲突、重复/坏 TLV、缺失回退、参数及补齐后的输出配额。原六组 CLI 回归继续保留，新脚本 scripts/test_template_metadata_cli.py 加入统一 CI。
