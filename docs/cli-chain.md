# 显式多文件事件浏览

```sh
moon run --target native cmd/moonbinlog -- --chain --decode-rotate mysql-bin.000001 mysql-bin.000002
moon run --target native cmd/moonbinlog -- --chain --summary --max-total-bytes 268435456 mysql-bin.000001 mysql-bin.000002
```

按时间顺序提供 2～128 份本地文件。`--chain` 自动输出 JSON Lines，可与 --json、--summary、--decode-rotate、--decode-previous-gtids、字节配额及 -- 文件名分隔符组合。未启用时仍要求一个 FILE，现有单文件协议保持原样。

本模式只浏览事件，与 --rows、--transactions、--include-rows、--schema、--schema-template、--use-table-metadata 和库表筛选互斥。跨文件行/事务导出尚未实现，不从轮转推断提交。

## 文件连接规则

1. 每份文件独立校验 magic，并从物理偏移 4 的 FDE 开始，建立自己的格式/CRC 上下文；事件偏移在新文件重新从 4 计算。
2. 中间文件必须以结构合法的 ROTATE_EVENT 结束，目标位置必须为 4；只支持从下一文件完整 FDE 开始，不支持从中间事件恢复。
3. ROTATE 的目标原始字节必须与下一条显式路径的 basename（按当前平台提取，再编码为 UTF-8）完全一致，区分大小写。链中不允许重复 basename；同名文件即使在不同目录也拒绝，避免重复读入。
4. 文件中的 ROTATE 后若仍有其他事件则失败；最后提供的文件可在正常事件边界结束，不要求有 ROTATE。若最后一个事件也是 ROTATE，只验证其结构，未提供的后继文件不会打开，目标位置也不用于继续读取。

只读取命令行显式给出的路径，允许这些路径来自不同目录。不从轮转标识拼接路径、扫描目录、自动补文件或尝试其他大小写。包含路径分隔符或无法匹配 UTF-8 basename 的标识不能连接到下一文件。

这些检查确认的是文件格式和声明的轮转连接，不证明所有文件来自同一服务端、包含连续 GTID/事务历史或没有被重新命名。其他事件仍只做文件层 framing/CRC 检查，不解释一般 SQL、GTID 或行 body。需要调用方提供正确、有序、已经关闭的日志文件。

## 事件与汇总

每条 event 沿用原事件 JSON，额外增加来源：

```json
{"source":{"index":0,"path":"mysql-bin.000001"}}
```

index 从 0 开始，path 保留调用方给出的路径文本；offset 始终相对此文件，不是整条链的累计偏移。使用 --decode-rotate 时类型 4 额外包含[轮转详情](cli-rotate.md)，未使用时不显示该字段，但仍执行连接所需的轮转验证。

全部输入成功后只输出一个 `kind: "chain_summary"`，没有逐文件的顶层 summary 记录。它包含：

| 字段 | 含义 |
| --- | --- |
| schema_version | 数字 1 |
| file_count | 文件数 |
| events / types | 全部文件的事件数及按类型码排序的计数，FDE 也计入 |
| event_bytes | 所有事件编码字节总和，十进制字符串 |
| file_bytes | 总输入字节数，包含每份文件各自的四字节 magic |
| files | 按输入顺序排列的文件统计数组，每项为 file_summary，含 source、events、types、event_bytes、file_bytes 及 schema_version |

因此 event_bytes 等于 file_bytes 减去 file_count×4。--summary 仅输出最终 chain_summary，仍读取并验证所有文件和轮转连接。

## 配额与失败

| 限制 | 默认值 | 允许范围 |
| --- | --- | --- |
| --max-event-bytes | 16777216 | 19～4294967295，含公共头和 CRC |
| --max-file-bytes | 67108864 | 1～2147483647，每份文件独立限制 |
| --max-total-bytes | 268435456 | 1～2147483647，仅用于 --chain，限制所有输入字节之和 |
| 文件数 | 最多 128 | --chain 至少需要 2 份 |

逐份文件读取，分配前取单文件上限与剩余总预算的较小值；不把全部文件同时拼进内存。仍会将当前整份文件读入内存，也保留最多 128 份文件统计；输出、转义及解析临时对象另占内存，没有独立输出字节配额。总输入不超过 Int32 上限，事件计数也受此限制约束。

参数错误退出 2，不读文件。读取、格式/CRC、轮转连接、重复文件名、截断或超限错误退出 1，stderr 带当前文件序号、路径及原始错误原因，不输出成功 chain_summary。前面已写出的 event 可能保留，消费者必须检查退出码和最终汇总。链内部状态错误后失效，不通过跳过坏文件继续处理。

## 验证

新增 7 项独立 MoonBit 测试及 78 个 CLI 场景，覆盖 CRC32/OFF 文件切换、来源与累计统计、轮转末尾/名称/位置检查、重复 basename、损坏中间文件、summary 验证、三层字节上限、参数、Unicode 路径及 128 份输入。

CLI 回归使用六组真实 MySQL 捕获的临时副本，按测试所需的轮转目标名命名，与各自单文件输出比较；这些副本用于测试格式切换和连接检查，不是新采集的真实连续日志链。原六组捕获和官方输出均未修改。独立构造的短链覆盖结构与边界，常规 CI 不启动数据库。

`python scripts/test_chain_cli.py` 已纳入统一 CI，根包 API 和依赖版本没有变化。basename 使用已有 moonbitlang/x 的平台路径接口；本批实际运行范围仍为 Windows/native。

开启 --decode-previous-gtids 时，类型 35 附带当前文件声明的历史 SID/GTID 区间，summary 同样验证；不会合并集合或证明历史连续性，见 [历史 GTID CLI](cli-previous-gtids.md)。
