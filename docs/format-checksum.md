# 格式描述与校验（功能 2）

## 公开接口

`FormatDescription::parse` 接受从事件头开始的完整字节视图、真实文件位置和可选大小上限，返回只读格式上下文。前面不包含四字节文件 magic；magic 使用已有接口独立校验。公共字段见生成的 `pkg.generated.mbti`。

上下文包含公共事件头、Binlog 版本、服务端版本、创建时间、公共头长度、事件类型的 post-header 长度表，以及后续事件的校验策略。

`FormatDescription::payload` 使用该上下文验证一条完整普通事件，并返回 body 视图。输入可以包含后续事件，但只消费本事件声明的范围。这个接口不保证未知 body 的语义正确，不替代后续的事件类型白名单或行解码器。

遇到新 FDE 返回 FormatContextResetRequired，调用者应使用 parse 建立新的格式上下文。上下文自身不被修改。

## 布局和边界

v4 公共事件头之后依次是：2 字节 Binlog 版本、50 字节服务端版本区、4 字节创建时间、1 字节公共头长度、可变长度 post-header 表、1 字节 checksum 算法、4 字节 CRC。

本版只支持 Binlog v4、MySQL 8.0.x 和 19 字节公共头。服务端版本必须为以 NUL 结束的可打印 ASCII，版本号含十进制 patch，可有非空的 `-suffix`。

post-header 表至少覆盖类型 15（FDE），索引为类型编号减一；FDE 自身长度项应等于 57 加表长。类型表与 checksum 描述字节、CRC 尾部严格分开。没有将合成样本的 41 项长度硬编码成所有 8.0 版本的要求。

先比较 UInt32 声明长度与可用输入，再转换为 Int32 切片，避免恶意高位长度溢出。继续使用默认 16 MiB 的事件上限；不会为声明长度直接分配 payload。

## CRC 规则

- 实现标准 IEEE CRC32，反射多项式为 0xedb88320，结果与 Python zlib 一致。
- 算法描述 0 表示后续事件 OFF，1 表示 CRC32；其他值明确拒绝。
- MySQL 8.0 的 FDE 自身始终有 CRC，即使算法描述为 OFF。
- FDE 的 CRC 覆盖除末尾四字节以外的事件数据；计算时只清除 flags 低字节中的 bit 0（in-use）。原始输入和解析出的 flags 保持原样。
- 普通 CRC32 事件不清除任何 flags，校验通过后从 body 去掉四字节 CRC。
- OFF 普通事件没有 CRC 尾部，不尝试猜测或去掉最后四字节。
- 错误中的 expected 是事件存储的 CRC，actual 是实际计算结果。

## 验证来源与限制

新增样本由 `scripts/generate_format_fixtures.py` 生成，使用 Python 标准库 struct 定义 wire layout、zlib 独立计算 CRC。样本与 SHA-256 清单一起提交，`--check` 验证可重现性。格式不合法的样本也计算正确 CRC，用来确保测试能够进入对应语义检查。

样本是自建合成数据，不是数据库导出的真实日志；37 项测试通过不能等同于已经验证完整 MySQL 日志兼容性。Java 客户端差分、真实服务器生成日志仍是后续交付要求。

查阅的 MySQL 8.0 源码固定在 commit `9fc8d60003b4eee32767c1e30942f222c3508c31`，只参考格式与行为，没有复制其实现代码：

- [FDE 固定字段及 post-header 表定义](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/libbinlogevents/src/control_events.cpp)
- [checksum 描述与 in-use 标志处理](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/libbinlogevents/src/binlog_event.cpp)
- [FDE 在 OFF 策略下仍写入 CRC 的规则](https://github.com/mysql/mysql-server/blob/9fc8d60003b4eee32767c1e30942f222c3508c31/sql/log_event.cc)
