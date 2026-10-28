# CLI GTID / 匿名 GTID 详情

```sh
moon run --target native cmd/moonbinlog -- --decode-gtid mysql-bin.000001
moon run --target native cmd/moonbinlog -- --decode-gtid --summary mysql-bin.000001
moon run --target native cmd/moonbinlog -- --chain --decode-gtid --decode-previous-gtids --decode-rotate mysql-bin.000001 mysql-bin.000002
```

`--decode-gtid` 只用于事件浏览，自动选择 JSON Lines。可与 --json、--summary、--chain、--decode-rotate、--decode-previous-gtids 和既有字节配额组合；与行/事务/schema 模式、元数据草稿及库表筛选互斥。重复选项、缺少文件或不支持的组合退出码为 2；`--` 后的同名文本仍是文件路径。

## JSON 协议

类型 33（GTID_EVENT）和 34（ANONYMOUS_GTID_EVENT）的 event 保留原字段及 schema_version=1，增加 gtid 对象。以下示例只展示新增 payload：

```json
{
  "gtid": {
    "anonymous": false,
    "identity": "00112233-4455-6677-8899-aabbccddeeff:4294967297",
    "sid": "00112233-4455-6677-8899-aabbccddeeff",
    "gno": "4294967297",
    "flags": 1,
    "may_have_sbr_statements": true,
    "last_committed": "5",
    "sequence_number": "6",
    "commit_timestamps": {"immediate": "1793013538890013", "original": "1793013538890000"},
    "transaction_length": "65536",
    "server_versions": {"immediate": 80043, "original": 80036},
    "commit_group_ticket": "31"
  }
}
```

SID 使用可逆的小写 UUID 分组文本，不要求某个 UUID 版本或 variant。已分配事件的 identity 为 `sid:gno`；匿名事件 identity 明确为 null，同时仍保留原始 sid、gno="0" 和 flags。消费方不能把匿名的这些原始字段当作可用 GTID 身份。

所有 UInt64 值使用十进制字符串，包括 GNO、两个逻辑时钟、提交时间、事务长度和 ticket，避免 JSON Number 丢失精度。服务端版本使用 UInt32 数值，flags 为字节数值，布尔值使用 JSON boolean。gtid.flags 是事件自己的标志，与 event 顶层的公共头 flags 分开。

四项可选扩展始终保留字段名：commit_timestamps、transaction_length、server_versions、commit_group_ticket；缺失时为 null。编码为零时保留 "0" 或零值对象，None 与 Some(0) 不会混淆。提交时间保留微秒数，不转换时区或格式化日期；logical clock 和 ticket 也不转换成时间。

非类型 33/34 事件不增加 gtid。其他详情选项只解析各自的事件类型，组合使用时互不替代：历史集合仍使用 previous_gtids，轮转仍使用 rotate。单独启用 --decode-gtid 不会解释类型 35 的 body。

## 校验、汇总和多文件

选项开启后，在计数/输出当前事件之前调用 [GtidEvent::parse](gtid-events.md)，验证当前类型的 42 字节 post-header、逻辑类型码 2、GNO、完整扩展阶段、CRC32/OFF 和精确尾部。max_event_size 接收 --max-event-bytes 的实际值；--max-file-bytes 和链模式的 --max-total-bytes 仍生效。

--summary 只抑制事件展示，仍完整解析 GTID body。坏 GTID 退出码为 1，不输出该事件或成功汇总，之前输出的完整事件可保留；summary 模式失败时没有 stdout 成功记录。未开启时，类型 33/34 仍只验证 framing/CRC，body 保持原来的不透明处理。

最终 summary / chain_summary 的字段和计数范围保持一致。链模式的 event 继续附带 source，offset 相对此文件；失败沿用包含文件序号、路径的 ChainFileFailure。各文件的已分配/匿名事件分别展示，不按 GTID 合并，也不验证它们与前一文件历史集合的连续关系。

本事件浏览选项不绑定事务。事务导出可另用 [--with-gtid](cli-gtid-transactions.md)，仍没有 GTID 去重/筛选、断点恢复或实时复制。GTID 事件不是提交证明，transaction_length 不用于跳过输入或核对实际事务字节；逻辑时钟、ticket 的关系也未校验。输入文件及 JSON 输出对象仍驻留内存，没有独立输出字节预算。

## 验证

新增 5 项独立 MoonBit 测试，覆盖参数组合/互斥、完整 payload 与原事件字段、空/零值扩展、UInt64 极值、匿名原始字段/空身份，以及六组真实事件和链来源。

`scripts/test_gtid_cli.py` 增加 620 个端到端场景：六组真实匿名事件的官方文本预期、22 种独立合成内容的 CRC32/OFF 输出、94 个无效 body 的明细/摘要失败和默认兼容性、错误 FDE/CRC、逐字节事件截断、未知事件/多个 GTID/FDE 切换、详情选项作用域、参数互斥、事件预算传递、显式文件链/来源和坏第二文件。已分配 GTID/ticket 的边界数据为合成样本，没有新增真实 GTID 模式日志。

脚本进入统一 CI，十一组 CLI 合计 1632 个场景；原始六组捕获的 SHA-256 保持一致。字段含义、底层格式和固定参考源码见 [库解析说明](gtid-events.md)。
