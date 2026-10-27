# ROTATE_EVENT 轮转信息

`RotateEvent::parse(format, data, file_offset~)` 解析 MySQL 8.0 ROTATE_EVENT（类型 4），返回当前事件头、目标日志内的 UInt64 position 和文件标识原始字节 next_binlog。它为多文件处理提供轮转信息；本批没有增加自动打开下一份文件或跨文件事务续接。

在已验证的文件遍历循环中，可按类型调用：

```moonbit
let reader = @moonbinlog.BinlogFileReader::new(data)
while reader.next() is Some(event) {
  if event.header.event_type == 4 {
    let rotation = @moonbinlog.RotateEvent::parse(
      event.format,
      event.raw,
      file_offset=event.header.file_offset,
    )
    // rotation.position 是目标文件中的位置；next_binlog 是文件名字节。
    consume_rotation(rotation)
  }
}
```

这里的 data 与 consume_rotation 由调用方提供，调用环境需要处理 DecodeError。解析入口与字段签名可用 `moon ide doc '@moonbinlog.RotateEvent'` 或根目录 pkg.generated.mbti 核对。

## 字段与边界

| 字段 | 含义 |
| --- | --- |
| header.file_offset | 此 ROTATE_EVENT 在当前输入中的物理位置，由调用方提供 |
| header.next_position | 当前事件公共头中的 UInt32 日志位置，原样保留 |
| position | 目标日志内的八字节小端 UInt64 位置，与上述两个位置分开 |
| next_binlog | 去掉公共头、post-header 位置和 CRC 后的全部剩余字节，复制为 Bytes |

UInt64 值完整保留，包括 0、4、超过 UInt32 范围及最大值。解析器只读取布局，不确认目标位置是否指向真实事件边界。零时间戳、零 next_position 和事件 flags 不改变本布局，也不据此推断事务提交。

文件标识不进行 UTF-8 转换、BOM/NUL 删除、路径拼接或规范化，也不按上游 C 字符串实现截短。即使包含非 UTF-8、NUL 或路径分隔符，也按原始非空字节返回；这不表示它是当前操作系统上合法、可打开的文件路径。调用方若需要显示或打开目标文件，需自行解释这些字节。

## 校验和错误

先检查公共头、事件类型和完整事件，再按传入 FDE 校验 CRC32/OFF。FDE 的类型 4 post-header 长度必须为 8；body 至少 9 字节，保证完整位置和至少一个文件名字节。只消费公共头声明的事件范围，后续输入不会混入文件名或 CRC 计算。

错误类型继续使用 TruncatedInput、TruncatedEvent、UnexpectedEventType、ChecksumMismatch、EventTooLarge、InvalidEventLimit，新增 InvalidRotateEvent(file_offset~, reason~) 表达不支持的 post-header 或缺少位置/名字。错误不修改格式上下文，也不返回部分结果。

可选 max_event_size 默认 16777216，包含公共头和 CRC；限制在复制文件名字节前检查。本层不另设文件名字节上限，因此可保留事件预算内的全部标识，也不承诺与 MySQL 参考程序对超长标识的截短策略一致。只支持本项目限定的 MySQL 8.0/v4 布局，不兼容旧版零长度 post-header。

## 验证与依据

新增 8 项独立 MoonBit 测试，覆盖 21 个独立构造的事件/FDE 向量、逐字节截断、CRC32/OFF、UInt64 极值、原始文件名字节、输入切片与尾部、配额、错误后格式复用。六组既有真实 MySQL 8.0.43 日志中的目标文件名与位置，与官方 mysqlbinlog 的 Rotate to / pos 输出逐一比较。

`scripts/generate_rotate_fixtures.py --check` 验证合成样本与六份官方对照，已由统一 CI 的生成器检查自动纳入。样本来源和摘要见 [轮转样本](../fixtures/rotate/README.md)。原有 CLI 输出和行/事务分发规则保持一致，本批 API 不改变这些模式对轮转 body 的既有处理范围。

协议依据固定到 MySQL commit `9fc8d60003b4eee32767c1e30942f222c3508c31` 的 [Rotate_event 定义](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/libbinlogevents/include/control_events.h)、[参考读取逻辑](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/libbinlogevents/src/control_events.cpp)和 [Rotate_log_event 写入逻辑](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/sql/log_event.cc)。实现与样本独立编写，没有复制上游代码。

CLI 可使用 --decode-rotate 显示这些字段，只有显式开启时才增加详情并验证轮转 body；默认输出及行/事务模式保持原样，见 [轮转 CLI](cli-rotate.md)。

CLI 另提供 --chain，显式按顺序读取多份文件并核对末尾轮转连接，见 [多文件事件浏览](cli-chain.md)。这不改变单文件遍历器/轮转解析器本身，也没有增加跨文件行或事务续接。
