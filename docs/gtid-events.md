# GTID 与匿名 GTID 事件

`GtidEvent::parse(format, data, file_offset~)` 解析 MySQL 8.0 的 GTID_EVENT（类型 33）和 ANONYMOUS_GTID_EVENT（类型 34），返回标识字段、逻辑时钟及可选扩展。它可供 [GTID 事务绑定](gtid-transactions.md) 使用；GTID 事件自身不表示事务已提交。

在 `BinlogFileReader` 的循环中，类型为 33/34 时传入 `event.format`、`event.raw` 和 `file_offset=event.header.file_offset`。接口签名可通过 `moon ide doc '@moonbinlog.GtidEvent'` 或根目录 `pkg.generated.mbti` 核对。

## 字段含义

| 字段或方法 | 含义 |
| --- | --- |
| header | 原事件头，包括当前输入的物理偏移 |
| flags | GTID 自己的一字节标志，不是公共头 flags；未知位保留 |
| sid | 16 字节原始 SID，无 UUID 版本或 variant 限制 |
| gno | 类型 33 为 1～INT64_MAX−1；类型 34 必须为 0 |
| is_anonymous() | 当前事件是否为类型 34 |
| may_have_sbr_statements() | flags 的位 0，表示可能包含基于语句的记录 |
| last_committed / sequence_number | 各八字节小端逻辑时钟，使用 UInt64 保留位值 |
| commit_timestamps | 可选 GtidCommitTimestamps，含 immediate / original 微秒时间戳 |
| transaction_length | 可选 UInt64 事务长度，来自 MySQL packed integer |
| server_versions | 可选 GtidServerVersions，含 immediate / original 数值版本 |
| commit_group_ticket | 可选 UInt64 提交组 ticket，保留原始位值 |

匿名事件的 SID 和零 GNO 只是保留 wire 字段，不分配事务标识，不作为去重键。已分配 GTID 的 SID/GNO 也不用于自动查询历史集合。

逻辑时钟只读取布局，不验证 sequence_number 与 last_committed 的关系或跨事件连续性；也不把 last_committed 当作当前事务已提交的证据。transaction_length 不用于跳过输入，不与实际事务字节数比对；ticket 不用于排序或同步。调用方若要解释这些值，需要相应事务和服务端上下文。

## 布局与扩展

FDE 必须对当前类型声明 42 字节 post-header。body 前 42 字节依次为 flags、SID、GNO、逻辑时钟类型码 2，以及两个逻辑时钟。不支持 25 字节旧布局或未知逻辑类型码，也不假设两个事件类型的 post-header 描述相同。

后续字段按以下顺序解析，可在任一完整阶段结束：

1. immediate 提交时间为七字节小端；位 55 指示是否紧接另一份七字节 original 时间。移除 immediate 的标志位；没有第二份时两值相同。original 完整保留七字节，不把其高位当作第二个标志。
2. 事务长度使用单字节或 0xfc/0xfd/0xfe 加 2/3/8 字节的 packed integer。允许非最短编码并保留完整 UInt64；0xfb（NULL）和 0xff（保留）拒绝。
3. immediate 服务端版本为四字节小端，位 31 指示是否紧接四字节 original 版本。只移除 immediate 标志；没有第二份时两值相同。版本数值原样保留，不据此改变 FDE。
4. 可选八字节提交组 ticket，之后必须恰好到事件末尾。

缺失扩展返回 None，编码为零返回 Some(0) 或包含零值的结构，两者不会混淆。没有时间戳时后续阶段也缺失；即使原始字节碰巧可解释为其他字段，也只按上述顺序读取。字段指示了 original 时必须有完整对应数据。

本接口对完整阶段边界采用严格策略：已开始但截断的可选字段、未知后缀和 ticket 后的额外数据均报错。上游兼容旧事件的读取器有时会忽略不足一个字段的可选尾部，本项目不复刻这种宽松行为，也不声称支持所有历史 MySQL GTID 编码。

## 完整性和错误

先验证公共头、类型和当前 FDE 下的完整 CRC32/OFF 事件。`max_event_size` 默认为 16777216，包含公共头/CRC；预算在读取字段和保留 SID 前应用。事件以外的后续输入不参与解码或 CRC。

类型不支持时返回 `UnsupportedGtidEvent(file_offset~, event_type~)`；布局、GNO、类型码、packed marker、字段截断或尾部错误返回 `InvalidGtidEvent(file_offset~, body_offset~, reason~)`。body_offset 从 body 开头按零计数；读完后才能识别的错误可能定位到字段末尾。其他事件截断、预算和 CRC 错误沿用 DecodeError，不返回部分结果，也不修改 FDE。

解析结果有固定上界，不根据 transaction_length、逻辑时钟或 ticket 的值分配输入缓冲区；仅 SID 需要保留 16 字节。没有新增生产依赖或 FFI。

## 验证与来源

新增 9 项独立 MoonBit 测试，使用 Python struct/zlib 独立生成的 44 个有效事件（22 种内容 × CRC32/OFF）、94 个无效 body，覆盖扩展阶段、缺失/零值区别、两类 GNO、任意 SID/flags、64 位边界、所有 packed 宽度与非最短编码、错误 post-header/类型/CRC、逐字节 framing 截断、重写长度后的 body 前缀、切片/后续输入和事件预算。

六组既有 MySQL 8.0.43 日志均包含一个匿名 GTID 事件，逻辑时钟、提交时间、事务长度及服务端版本与官方 mysqlbinlog 输出逐一核对。ticket 等边界样本仍为合成数据；现在另有三组 [真实 assigned GTID 捕获](../fixtures/gtid-real/README.md)，覆盖 9 笔真实事务及非空历史。另用本机官方 mysqlbinlog 8.0.43，对 8 组合成 assigned/anonymous 事件核对标识、时钟和可用的时间/长度/版本文本；ticket 位值主要由独立合成预期验证。

`scripts/generate_gtid_fixtures.py --check` 自动进入统一 CI；可选官方工具对照命令为：

```powershell
python scripts/generate_gtid_fixtures.py --check --mysqlbinlog 'C:/Program Files/MySQL/MySQL Server 8.0/bin/mysqlbinlog.exe'
```

协议依据固定为 MySQL commit `9fc8d60003b4eee32767c1e30942f222c3508c31` 的 [Gtid_event 定义](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/libbinlogevents/include/control_events.h)、[事件读取逻辑](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/libbinlogevents/src/control_events.cpp)及 [Gtid_log_event 写入逻辑](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/sql/log_event.cc)。实现和样本根据布局独立编写，没有复制上游代码。

库接口之外，CLI 可显式使用 --decode-gtid 展示并校验类型 33/34，见 [GTID CLI](cli-gtid.md)。默认事件浏览和 CLI 事务包络分发保持原有范围；库层另提供 [显式事务绑定](gtid-transactions.md)，尚无 GTID 去重/过滤、断点恢复、历史连续性证明、实时复制或 MySQL 8.4 tagged GTID 支持。
