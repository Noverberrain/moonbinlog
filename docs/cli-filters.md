# CLI 按库表精确筛选输出

--database NAME 和 --table NAME 仅用于 --rows / --transactions，控制输出选择。整个文件、schema 绑定、字段解码、CRC、配额和事务结束检查继续执行，不会通过筛选恢复或跳过非法输入。

## 参数与匹配

```text
moon run --target native cmd/moonbinlog -- --rows --schema examples/mysql-8.0-schema.json --database moonbinlog_fixture --table sample fixtures/mysql-8.0/crc32-full.binlog
moon run --target native cmd/moonbinlog -- --transactions --include-rows --schema examples/mysql-8.0-schema.json --table sample fixtures/mysql-8.0/crc32-full.binlog
```

| 形式 | 匹配规则 |
| --- | --- |
| 仅 --database shop | 名字严格等于 shop 的库中的任意表 |
| 仅 --table orders | 任意库中名字严格等于 orders 的表 |
| 两者同时指定 | 库名与表名必须同时匹配（AND） |
| 都不指定 | 沿用已有行为，摘要不增加筛选字段 |

每项最多指定一次，名字要求 1～256 个 UTF-16 单位且不含 NUL；重复、空值、超长或用于默认事件模式均退出 2。选项可放在文件名前后，-- 仍结束选项解析。

按精确字符串、区分大小写匹配，不模拟数据库排序规则、大小写转换或 SQL 标识符解析；点号、星号、引号和反斜杠都是名字中的普通字符。库表分别存储和比较，不把 shop.orders 拆成二元组，不做通配符、正则或多选。包含空格或 shell 特殊字符时按 shell 规则引用参数。

## 行模式

每个 ROWS 事件先完整解码，再按其 TABLE_MAP 快照的库表名决定是否输出其中的全部变化；多行与 UPDATE 配对顺序保持不变，单笔输出形状和 unconfirmed 标记不变。

只有启用筛选参数时，row_summary 增加：

- filter：含 database、table 和 scope 的对象；未指定的名字为 null，scope 固定为 row_events。
- selected_row_events：匹配的 ROWS 事件数。
- selected_changes：匹配的变化数；一对 UPDATE 镜像计一条。

原有 events/event_bytes/types 和 row_events/changes 均是全文件扫描总量。--summary 省略所有行记录，但 selected_* 仍统计匹配数量；没有匹配时输出一个成功摘要、选中计数为零。成功 EOF 仍不确认事务提交，详见[行模式边界](cli-rows.md)。

例如真实样本没有匹配到指定表时，新增字段的形状为：

```json
{
  "filter": {"database": null, "table": "other", "scope": "row_events"},
  "selected_row_events": 0,
  "selected_changes": 0
}
```

此示例仅展示附加字段，实际摘要仍包含 row_events=4、changes=4 及全部既有字段。

## 事务模式：以整笔事务为单位

显式 BEGIN 到 XID/COMMIT/ROLLBACK 区间中，只要任一成功解码的 ROWS 匹配，整笔完成的事务就被选中。选择状态跨语句保留，在事务边界清理；FDE 切换和任何错误也不能保留旧的命中状态。

**选中后输出完整事务。** 其范围、XID、事件数、各表计数及 --include-rows 导出的 row_changes 全部保持原值，包含同一事务中的其他表。例如一笔事务修改 sample 和 second，--table sample 会保留该笔事务及两张表的变化。这保证导出对象仍代表完整的已验证区间。

ROLLBACK 按区间中成功解码的 ROWS 判断是否命中，只报告整笔丢弃数量，不导出被丢弃的行值。空事务、仅出现 TABLE_MAP 而没有 ROWS 的区间，在启用筛选时都不命中；未启用筛选时继续输出它们。

只有启用筛选时，transaction_summary 增加：

| 字段 | 含义 |
| --- | --- |
| filter | database/table 为名字或 null；scope 固定 whole_transactions |
| selected_committed_transactions | 选中的完成提交笔数 |
| selected_rolled_back_transactions | 选中的完成回滚笔数 |
| selected_committed_row_events | 选中提交内的全部 ROWS 事件数 |
| selected_committed_changes | 选中提交内的全部变化数，包含其中其他表 |
| selected_discarded_changes | 选中回滚内的整笔丢弃数量 |

所有 selected_* 为数字，原有 committed_*、rolled_back_transactions、discarded_changes 仍统计全文件全部完成区间。--summary 仍统计选中集合，即使不输出单笔记录。单笔 transaction 本身不新增或裁剪字段，协议版本仍为 1，输出规则见[事务 CLI](cli-transactions.md)。

## 校验与错误边界

schema 必须覆盖扫描经过的所有 TABLE_MAP，包含未选中的表。未选中事件的字段类型、列数、CRC、映射生命周期和配额仍会报错；筛选不增加解码器的协议支持范围，也不降低整文件读取或事务缓存的预算。

事务模式未结束的区间即使不匹配，也必须在 EOF 报 IncompleteTransaction；新 FDE、未知事件或截断均不能被筛选掩盖。失败不输出成功摘要，之前已输出的完整选择结果可能保留。消费者仍须检查退出码及最后的摘要，不能仅凭已选中的输出前缀判断全文件成功。

## 验证

```text
moon test --target native --filter "CLI filter*"
python scripts/test_filters_cli.py
```

新增 7 项 MoonBit 测试和 89 个子进程场景，覆盖三个真实捕获的行/事务/导出与摘要、大小写、AND、Unicode/标点、参数长度和重复、同 table_id 换表、多表事务完整性、空区间、回滚、状态清理、无匹配结果以及未选中内容仍须失败。脚本已加入 scripts/ci.ps1，核对固定输入未改变，不启动数据库。
