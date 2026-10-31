# 提交前复现检查与验收材料

检查日期：2026 年 10 月 31 日。检查对象为公开仓库默认分支 main 的 [62b7638](https://github.com/Noverberrain/moonbinlog/commit/62b7638d35eb3ca47a7756e43636b2ed344666d4)，包含验收演示和更新后的申报书。本页记录这次复现结果；后续代码变更需要重新验证。

## 本次结果

已从 GitHub 新建克隆，更新包索引并运行完整 `scripts/ci.ps1`。384 项 MoonBit 测试、十六组 3521 个 CLI 场景和四步演示全部通过，检查结束后 `git status --porcelain` 无输出。本轮没有发现阻止 Windows native 离线演示的复现问题。

使用的环境是 Windows x64、MoonBit/core 0.10.15+943464bfa、moon 0.1.20261012、Python 3.13.9 和本机 MSVC。新目录没有复制原工作区的 `_build` 或 `.mooncakes`，但依赖使用了本机全局缓存；这次没有验证一台全新 Windows 系统的首次安装。

完整验证涵盖格式、严格检查、native 测试/构建、生成接口与 HEAD 一致、十七组合成样本、九组真实 MySQL 8.0.43 捕获及 schema 示例，再执行全部 CLI 回归与演示。构建时仍有官方 async 依赖已有的 EINVAL 宏重定义 C4005 提示，构建成功；没有修改依赖源码。

同一个提交的 [GitHub CI 运行](https://github.com/Noverberrain/moonbinlog/actions/runs/41089733668)在本次检查时已通过，结果可在运行页面核对。

## 申报范围与证据

| 申报内容 | 本仓库中的复现入口 |
| --- | --- |
| MySQL 8.0 格式、CRC32/OFF、表映射及 schema 草稿 | [CLI 用法](cli.md)、[格式校验](format-checksum.md)、[草稿生成](cli-schema-template.md)；统一 CI 检查相应样本与回归 |
| 带类型的 INSERT/UPDATE/DELETE，区分缺失列与 NULL | [行导出](cli-rows.md)、[JSON 字段](json-values.md)；演示第 2 步及官方 mysqlbinlog 行镜像对照 |
| 历史 GTID、前缀绑定、提交与回滚、EOF 错误 | [GTID 事务导出](cli-gtid-transactions.md)、[真实 GTID 样本](../fixtures/gtid-real/README.md)；演示第 1、3、4 步 |
| 库表筛选、多文件事件浏览、单文件逐事件读取 | [筛选规则](cli-filters.md)、[多文件浏览](cli-chain.md)、[逐事件读取](cli-stream.md)；对应 CLI 回归 |
| 可运行的解析库和 native CLI | [可执行文档](../README.mbt.md)、[四步演示](acceptance-demo.md)、[CI 入口](../scripts/ci.ps1) |

[申报书](../PROPOSAL.md)含空行共 30 行，验证数据已更新为 384 项测试、3521 个 CLI 场景和九组真实日志；四步演示另列，未计入 3521。声明的范围与当前文档相符。

根目录已有 Apache-2.0 [LICENSE](../LICENSE) 和 [NOTICE](../NOTICE)；真实样本目录提供采集过程、SQL、官方输出和摘要。Git 跟踪文件中没有 `_build`、`target`、`.mooncakes` 或 `.repos` 目录。

## 换一个目录再跑

准备好相同工具链、Python 和 MSVC 后，以下命令会新建 moonbinlog-acceptance 目录；已有同名目录时请换一个新名称。

```powershell
git clone --depth 1 --branch main https://github.com/Noverberrain/moonbinlog.git moonbinlog-acceptance
cd moonbinlog-acceptance
git fetch --depth 1 origin 62b7638d35eb3ca47a7756e43636b2ed344666d4
git checkout --detach FETCH_HEAD
git rev-parse HEAD
moon update
./scripts/ci.ps1
```

上述 fetch/checkout 固定到这次检查的快照，应确认 HEAD 是 `62b7638d35eb3ca47a7756e43636b2ed344666d4`。如果要验证最新 main，可省略这两步；本页发布后 main 可能包含后续文档或代码改动。

演示输出位于新克隆内的 `_build/acceptance-demo/`。`report.json` 的 status 应为 passed，四步 stdout 记录数为 19、7、4、0，子进程退出码为 0、0、0、1；最后一步的 1 是未完成事务的预期错误。各 JSON Lines、stderr 和截断副本可按 [演示说明](acceptance-demo.md)逐项查看。

## 提交时可直接引用

- 项目名称：MoonBinlog：MySQL Binlog 解析库与离线工具。
- 参赛者：Noverberrain。
- 项目仓库：[Noverberrain/moonbinlog](https://github.com/Noverberrain/moonbinlog)。
- 申报书：[PROPOSAL.md](../PROPOSAL.md)，30 行。
- 使用与复现：[README](../README.md)、[验收演示](acceptance-demo.md)、本页及对应提交的 GitHub CI。
- 简介：用 MoonBit 解析本地 MySQL 8.0 Binlog，提供事件校验、带类型的行变化、GTID 与显式事务导出，支持单文件逐事件读取。固定日志可按文档复现，不需要启动 MySQL。

## 当前验收指南与维护动作

以参赛者于 2026 年 10 月 31 日提供的验收指南为准：审核通过的选手，验收前不需要再提交任何表格，只需保持开发并将对应内容上传 GitHub。此前根据入口未确认而列出的表单、附件和回执步骤撤销。

- [x] Noverberrain/moonbinlog@0.1.0 已发布并在独立项目中安装验证；[模块链接](https://mooncakes.io/docs/Noverberrain/moonbinlog)。
- 工具链门槛为 moonc >= 0.10.16；已在固定的 0.10.18+6c83a7f62 下通过全部 384 项测试、3521 个 CLI 场景及四步演示，CI 在检查开始时强制验证下限。本批仍需按用户确认推送，让远端 CI 使用新版本。
- 保持公开仓库、清晰提交记录、README、可运行示例、检查/构建/测试 CI、核心路径测试与 Apache-2.0 许可证。

本页前面的 62b7638 干净克隆记录是旧工具链的历史证据，不代表已经用 0.10.18 验证。新工具链结果在 [进度记录](progress.md)本轮记录，不改写历史结果。

项目支持边界保持不变：离线、未加密的 MySQL 8.0 子集；不支持实时订阅、自动跟随轮转、自动提交/DDL/XA 推断、跨文件事务续接，以及 JSON opaque/partial diff。schema 必须匹配历史表结构，事务缓冲和文件/事件预算仍生效；未测吞吐或内存峰值。其他操作系统及未测试 MySQL 版本仍需单独验证。

## 按本期九项指南核对

| 要求 | 当前证据 |
| --- | --- |
| 1. MoonBit 为主，moonc >= 0.10.16 | 实现使用 MoonBit；本机回归与固定 CI 工具链均升级至 0.10.18，CI 设最低版本门槛，旧版拒绝行为已验证 |
| 2. GitHub 公开、提交清晰 | 公开远端 main 已验证可克隆，保留连续功能提交；本批新版工具链配置待用户确认推送 |
| 3. 结构清晰、核心功能有效 | 库、internal/cli 和 cmd 分层；支持边界写入 README，全部回归通过 |
| 4. README 可复现 | 源码安装、库依赖、CLI 用法和示例齐备；新版工具链完整运行通过 |
| 5. CI 覆盖检查/构建/测试 | Windows native 工作流执行统一脚本；此前远端运行已通过，本批新版本云端运行需在推送后确认 |
| 6. 至少一个可运行示例 | 四步离线演示及 README MoonBit 示例均通过 |
| 7. 核心路径测试 | 384 项 MoonBit 测试、3521 个 CLI 场景、固定真实样本对照；另有仓库外已发布包消费者验证 |
| 8. 发布到 Mooncakes | 0.1.0 已发布；独立项目安装后在 0.10.18 上严格检查及解析测试通过，无需重复发布同一版本 |
| 9. OSI 开源许可证及来源 | 根 LICENSE 为 Apache-2.0，NOTICE 和协议/样本来源文档可查 |

已审核通过的项目按这份指南无需再次填表或提供表单回执。保持开发内容在 GitHub 可访问并留意赛事组审核反馈即可；本页不保证官方审核结果。
