# 历史 GTID 集合解析

`PreviousGtidsEvent::parse(format, data, file_offset~)` 解析 MySQL 8.0 的 PREVIOUS_GTIDS_EVENT（类型 35），返回事件头和 SID / GTID 区间列表。它表示日志声明的历史集合；事务自身的 GTID_EVENT、去重、断点恢复和日志历史连续性核对留待后续实现。

## 接口与数据

从 `BinlogFileReader` 得到事件后，类型为 35 时传入 `event.format`、`event.raw` 和 `file_offset=event.header.file_offset`。完整签名可查根目录 `pkg.generated.mbti`，或执行 `moon ide doc '@moonbinlog.PreviousGtidsEvent'`。

| 字段 | 含义 |
| --- | --- |
| PreviousGtidsEvent.header | 当前事件头，物理偏移由调用方提供 |
| PreviousGtidsEvent.sids | 按输入顺序保存的只读 SID 条目 |
| GtidSidIntervals.sid | 16 字节 SID，按原始字节保存，无 UUID 版本/variant 限制 |
| GtidSidIntervals.intervals | 当前条目的只读 GTID 区间列表 |
| GtidInterval.start | 包含在区间中的第一个 GNO |
| GtidInterval.end_exclusive | 不包含在区间中的结束 GNO |

例如 `[1, 5)` 表示 GNO 1～4；`[9223372036854775806, 9223372036854775807)` 只包含前者。返回值使用 UInt64 精确保留正整数，结束值最大为 INT64_MAX，实际 GNO 最大为 INT64_MAX−1。转换到 JavaScript Number 等类型时，消费方需自行保留整数精度。

条目之间保留乱序 SID、重复 SID，以及零区间条目；这与上游解码器可接受的输入一致。返回对象是 wire 数据的结构化表示，不会把重复 SID 合并为规范集合，也没有字符串规范化或集合运算接口。条目内部区间必须有序、非空、起点为正，且不能重叠或相邻；相邻区间在上游写入前已合并，上游解码器也拒绝这种输入。

## 校验和配额

先检查事件类型、完整 framing 和 CRC32/OFF，再要求 FDE 对类型 35 声明零长度 post-header。body 依次为八字节小端 SID 数量，以及每项的 16 字节 SID、八字节小端区间数量和各区间两个八字节小端端点。零 SID 集合也必须有完整的八字节零计数。

数量先与剩余字节及配额比较，再转换为 Int 或分配条目，不对攻击者提供的 UInt64 计数直接乘法或预分配。逐项消费时再次检查剩余字节，拒绝被前面区间占用的后续 SID 数据。声明 body 必须恰好消费完；声明事件之后的输入不会参与解析或 CRC。

| 参数 | 默认值 | 作用 |
| --- | --- | --- |
| max_event_size | 16777216 | 整个事件字节数，包含公共头和 CRC |
| max_sids | 1024 | 原始 SID 条目数，包括重复或空条目 |
| max_intervals | 65536 | 所有条目累计区间数 |

两项集合配额允许 0；负值产生 `InvalidGtidSetLimits`。超过集合预算产生 `GtidSetLimitExceeded(file_offset~, reason~)`。body 或 post-header 错误产生 `InvalidPreviousGtidsEvent(file_offset~, body_offset~, reason~)`，其中 body_offset 从 body 开头按零计数，校验失败时可能指向刚读取字段的末尾。其他 framing、CRC、类型和事件大小错误沿用已有 DecodeError。错误不返回部分集合，也不修改传入 FDE。

## 验证和范围

新增 10 项独立 MoonBit 测试，覆盖 CRC32/OFF 各 5 个有效集合、25 个无效 body、两种不支持的 FDE、坏 CRC、逐字节事件/body 截断（含重写长度的完整 OFF framing）、输入切片与尾部、UInt64 伪造计数、累计配额和失败后复用。六组既有 MySQL 8.0.43 捕获都只有空历史集合，逐一与官方输出的 `[empty]` 对照；非空历史集合使用独立 Python struct/zlib 合成样本，不能算作真实 GTID 事务捕获。

生成器已自动进入统一 CI 的 `generate_*_fixtures.py --check` 检查。可选本地对照命令：

```powershell
python scripts/generate_previous_gtids_fixtures.py --check --mysqlbinlog 'C:/Program Files/MySQL/MySQL Server 8.0/bin/mysqlbinlog.exe'
```

本地 MySQL 8.0.43 官方工具已对 8 组规范合成集合完成 CRC 验证和文本端点比较，包含空集合、多 SID、多区间与最大合法 GNO。该操作只读取临时合成文件，不启动数据库；常规 CI 无需安装或调用 MySQL。

协议依据为 MySQL commit `9fc8d60003b4eee32767c1e30942f222c3508c31` 的 [Previous_gtids_event 定义](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/libbinlogevents/include/control_events.h)及 [Gtid_set::encode / add_gtid_encoding](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/sql/rpl_gtid_set.cc)。代码和样本根据布局独立编写，没有复制上游实现。

库接口之外，CLI 可显式开启 --decode-previous-gtids 显示并校验历史集合，详见 [CLI 详情](cli-previous-gtids.md)。默认事件浏览及 TransactionDecoder 的历史包络处理保持原样；尚无 GTID_EVENT 事务绑定、GTID 过滤、实时复制或 MySQL 8.4 tagged GTID 支持。文件链的轮转连接核对仍不能证明 GTID 历史连续。
