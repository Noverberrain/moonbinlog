# MoonBinlog

纯 MoonBit 的 MySQL Binlog 解析库，正在按功能逐步开发。

第一批已实现未加密 Binlog 的文件标识校验及 v4 公共事件头解析。
输入使用 `BytesView`，不依赖数据库连接或第三方解析程序。

## 使用示例

```mbt check
///|
test "validate a file signature and decode a common header" {
  @moonbinlog.validate_file_header([0xfe, 0x62, 0x69, 0x6e])
  let header : Bytes = [
    0x78, 0x56, 0x34, 0x12, 0x1e, 0x01, 0x00, 0x00, 0x00, 0x13, 0x00, 0x00, 0x00,
    0x17, 0x00, 0x00, 0x00, 0x00, 0x00,
  ]
  let decoded = @moonbinlog.EventHeader::parse(header, file_offset=4)
  assert_eq(decoded.event_size, 19U)
  assert_eq(decoded.next_position, 23U)
}
```

## 当前接口与边界

- `validate_file_header` 校验前四字节 `FE 62 69 6E`，不据此确认 Binlog 版本。
- `EventHeader::parse` 读取前 19 字节，保留时间、类型、服务端 ID、事件长度、日志位置和标志。
- 调用者传入真实 `file_offset`；它与日志头中的 `next_position` 分开保存。
- 事件长度下限为 19 字节；默认上限为 16 MiB，可显式调整。
- 数据截断、错误文件标识、非法事件长度及上限配置通过 `DecodeError` 返回。
- 当前仅解析头部，允许输入尚未包含负载；完整事件、格式描述、CRC 和行解码尚未实现。
- 测试数据是依据协议手工构造的字节序列，尚未完成真实 MySQL 文件集成验证。

## 验证

```text
moon check --warn-list +unnecessary_annotation --deny-warn
moon test
moon build
moon fmt --check
moon info
```

公共接口由 `moon info` 生成在 `pkg.generated.mbti`。

## 协议依据

- [MySQL 8.0 事件头偏移与长度定义](https://github.com/mysql/mysql-server/blob/8.0/libbinlogevents/include/binlog_event.h)
- [MySQL 8.0 事件头字段](https://github.com/mysql/mysql-server/blob/8.0/libbinlogevents/include/control_events.h)

实现根据格式独立编写，当前没有复制上游实现代码或测试数据。

## 开发节奏

每次完成一个功能后暂停，报告行为变化、验证结果和新增行数。
源码、测试、生成接口及文档/配置分别统计；行数包含空行与注释，不作为有效代码量或完成度指标。

下一批拟实现 FORMAT_DESCRIPTION_EVENT 与校验上下文，等待用户继续指令。
