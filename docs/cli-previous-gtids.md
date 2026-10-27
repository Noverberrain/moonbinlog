# CLI 历史 GTID 详情

```sh
moon run --target native cmd/moonbinlog -- --decode-previous-gtids mysql-bin.000001
moon run --target native cmd/moonbinlog -- --decode-previous-gtids --summary mysql-bin.000001
moon run --target native cmd/moonbinlog -- --chain --decode-previous-gtids --decode-rotate mysql-bin.000001 mysql-bin.000002
```

`--decode-previous-gtids` 用于事件浏览，自动输出 JSON Lines；可组合 --json、--summary、--decode-rotate、--chain 和已有字节限制。它与行/事务/schema 模式、元数据草稿和库表筛选互斥，重复出现或参数不合法时退出码为 2。`--` 之后的同名参数仍被当作文件路径。

## JSON 协议

类型 35 的 event 保留原有事件字段，增加一个 previous_gtids 对象：

```json
{
  "previous_gtids": {
    "sids": [
      {
        "sid": "00112233-4455-6677-8899-aabbccddeeff",
        "intervals": [
          {"start": "1", "end_exclusive": "5"},
          {"start": "8", "end_exclusive": "10"}
        ]
      }
    ]
  }
}
```

示例只展示新增 payload，不是完整 event。SID 为全部 16 字节的标准分组、小写十六进制 UUID 文本；任意 SID 字节都可逆表示，不要求符合特定 UUID 版本或 variant。端点均为十进制字符串，保留大整数精度；区间为左闭右开，`1..5` 表示 GNO 1、2、3、4，结束值不是已执行的 GNO。

空集合输出 `{"sids":[]}`。原始 SID 顺序、重复 SID 和空区间条目保持原样，不合并、不排序，也不把匿名 GTID 事件转为集合项。该结构是日志声明的数据，不能据此认为整份日志已通过事务语义验证。

非类型 35 事件不增加 previous_gtids。组合 --decode-rotate 时，两种详情分别出现在对应类型的 event 上；轮转字段沿用原协议。使用 --chain 时，每条 event 继续保留 source，offset 相对此文件；每个文件独立解析自己的集合，不进行跨文件集合合并或包含关系核对。

最终 summary / chain_summary 的结构和计数范围不变。`--summary` 抑制事件明细，仍完整解析并校验所有历史集合。

## 校验和资源范围

调用既有 [PreviousGtidsEvent::parse](previous-gtids.md)，验证 FDE 零长度 post-header、CRC32/OFF、计数、完整 body、正整数和区间顺序/重叠/相邻约束。SID 条目最多 1024 项，所有条目累计最多 65536 个区间；这些集合上限固定使用库默认值，没有新增命令行调整选项。重复或空条目同样占用 SID 预算。

--max-event-bytes 被传递到集合解析器；--max-file-bytes 和链模式的 --max-total-bytes 仍有效。提高事件字节预算不会提高集合数量上限，也不会让坏 body 通过。输入完整文件和当前解析结果仍驻留内存，JSON 报告还会分配对象及文本；没有独立输出字节预算。

错误退出码为 1，不输出失败事件或成功汇总，之前完整输出的 event 可以保留。多文件错误沿用 ChainFileFailure，附当前文件序号和路径。summary 模式下发生错误时无 stdout 成功记录。

未开启该选项时，类型 35 在事件浏览中仍只验证 framing/CRC，body 保持不透明；行/事务模式的原有包络分发也保持原样。该选项不增加事务 GTID_EVENT 绑定、GTID 去重/筛选、实时订阅、断点恢复或历史连续性证明。

## 验证

新增 5 项独立 MoonBit 测试，覆盖参数、完整事件字段、SID 格式、精确半开区间、空/重复条目、最大合法 GNO、OFF 和链来源信息。

`scripts/test_previous_gtids_cli.py` 提供 252 个端到端场景：六组真实捕获的空历史集合、独立合成的非空集合、两种 checksum、坏计数/区间/FDE/CRC、逐字节事件截断、固定配额边界/累计超限、参数、提高事件预算、summary、未知事件、多个集合及单文件 FDE 切换、显式文件链与坏第二文件。原始捕获 SHA-256 保持一致，非空样本属于合成数据。该脚本进入统一 CI，十组 CLI 合计 1012 个场景。
