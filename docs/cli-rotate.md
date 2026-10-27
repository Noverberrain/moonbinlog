# CLI 轮转事件详情

```sh
moon run --target native cmd/moonbinlog -- --decode-rotate fixtures/mysql-8.0/crc32-full.binlog
moon run --target native cmd/moonbinlog -- --decode-rotate --summary fixtures/mysql-json/off-full.binlog
```

`--decode-rotate` 是事件查看模式的可选增强，自动使用 JSON Lines，也可同时指定 --json。正常输出仍是一行一个 event 和末尾 summary，只有类型 4 的事件增加 rotate 对象。未启用时，原有 TSV/JSON 事件协议与轮转 body 的处理范围保持原样。

可组合 --summary、--max-event-bytes、--max-file-bytes 及 -- 文件名分隔符；不能组合 --rows、--transactions、--include-rows、--schema、--schema-template、--use-table-metadata 或库表筛选。重复选项和非法组合退出 2，不读取文件。

还可与 --chain 组合，按显式给出的文件顺序浏览并显示轮转详情；此时事件增加 source、最终汇总为 chain_summary，规则见 [多文件 CLI](cli-chain.md)。

## JSON 字段

例如，真实 MySQL 样本的轮转事件在既有 event 字段之外增加：

```json
{"rotate":{"position":"4","next_binlog_hex":"636170747572652e303030303034","next_binlog_utf8":"capture.000004"}}
```

| 字段 | 含义 |
| --- | --- |
| rotate.position | 目标文件中的 UInt64 位置，始终为十进制字符串，避免 double 丢失精度 |
| rotate.next_binlog_hex | 文件标识原始字节的小写 hex，始终提供 |
| rotate.next_binlog_utf8 | 整个文件标识可严格解码为 UTF-8 时的文本，否则为 JSON null |

UTF-8 文本仅供显示，不替换原始字节。BOM 和 NUL 保留为数据，引号、换行等进行 JSON 转义，不拆成额外记录；不使用替换字符掩盖非法编码。即使提供文本，也不表示它是合法或可信的本地文件路径。

原有 offset 指本事件在当前输入中的物理偏移，next_position 是公共头的 UInt32 位置，rotate.position 指目标文件内的位置，三者不可混用。文件标识原样展示，不自动打开目标文件，也不据此推断事务已提交或验证日志链。

其他类型仍输出原有 event 对象，没有 rotate 字段。summary 的字段、计数和 checksum 显示规则保持不变；--summary 省略全部事件明细，但仍执行轮转解码和校验。

## 错误和配额

通过[轮转库接口](rotate-events.md)验证完整类型 4 事件及八字节 post-header、非空标识、CRC32/OFF，支持传入的事件大小上限。本模式不额外解释 ROWS、QUERY、GTID 或未知事件的 body，不能把事件浏览成功当作行/事务语义已验证。

读取、CRC、轮转结构、配额或截断错误退出 1，不输出该失败事件的 rotate 对象，也不追加成功 summary。此前已输出的完整 event 可能保留；消费方必须检查退出码和末尾摘要。输出通道失败也可能留下不完整写入。

文件默认最多 64 MiB、事件默认最多 16 MiB。--summary 不构造明细字符串；显示明细时 hex、UTF-8 文本和 JSON 转义会增加输出/内存大小，没有独立的输出字节配额。更大的事件上限也会传递给轮转解析器，不能只提高文件层上限而被内部默认值误拒绝。

## 验证

新增 5 项独立 MoonBit 测试，覆盖参数、输出字段、精度、非法 UTF-8 与 NUL，以及六组真实事件。148 个 CLI 场景对照六份官方 Rotate to / pos 输出，核对既有 event/summary 字段，覆盖 CRC32/OFF/FDE 切换、UInt64 极值、Unicode/BOM/转义、未知事件、多个轮转、参数互斥、坏结构/CRC/逐字节截断、两层配额及提高上限后的 summary 验证。

`python scripts/test_rotate_cli.py` 已加入统一 CI，原七组 CLI 回归保留。此功能不更改根包解析 API、生产依赖、行/事务分发或 schema 草稿逻辑。
