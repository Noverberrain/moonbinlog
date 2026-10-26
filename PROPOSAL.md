# MoonBinlog 项目申报书

**基本信息**

- 项目名称：MoonBinlog：MySQL Binlog 解析库与离线工具
- 参赛者：Noverberrain
- 联系方式：2455251391@qq.com
- GitHub 仓库链接：https://github.com/Noverberrain/moonbinlog
- 项目方向：数据库协议解析基础库 / 后端开发工具
- 是否为移植项目：否，原创项目

**项目简介**

我平时做 Java 后端，这次想从熟悉的数据库方向入手，用 MoonBit 做一个能实际使用的工具。MoonBinlog 读取本地 MySQL Binlog，把二进制日志解析成带类型的行变化和事务结果。项目同时提供解析库和命令行工具，方便查看数据变化，也为后续的数据分析、离线排查和同步工具提供基础。

**核心功能范围**

- 读取 MySQL 8.0 Binlog，校验格式和 CRC32，解析表映射；可生成 schema 草稿，并从日志已有元数据中补齐列名和整数符号属性，缺失时留待人工确认。
- 解码整数、字符串、BLOB、小数、日期时间及普通完整 JSON，输出 INSERT、UPDATE、DELETE 的前后数据；保留大整数和小数精度，区分缺失列、SQL NULL 与 JSON null。
- 处理显式事务的提交、回滚和未结束状态，只在确认提交后导出该事务的行变化，损坏或超限时明确报错。
- 提供 native CLI，支持事件查看、JSON Lines 导出、统计和库表筛选；事务筛选保留完整事务，未选中的输入仍进行校验。

**预期验收产物**

- 可复用的 MoonBit 解析库和 native CLI，附 API 示例、运行说明、固定样本及支持范围文档，可按 README 命令复现。
- 截至 2026 年 10 月 27 日，已通过 307 项 MoonBit 测试、534 个 CLI 场景及本地统一 CI；六组真实 MySQL 8.0.43 日志已与官方 mysqlbinlog 输出对照，仓库提供 Windows native CI。

**移植或参考说明**

项目依据 MySQL 8.0 公开协议独立实现，协议依据和样本来源均在仓库记录，没有复制上游实现代码，采用 Apache-2.0 许可证。目前以离线解析为主；实时订阅、DDL 还原、多文件续接，以及 JSON 的 opaque 扩展和增量更新暂未实现。
