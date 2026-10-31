# Mooncakes 0.1.0 发布记录

2026 年 10 月 31 日，经参赛者确认，已正式发布 `Noverberrain/moonbinlog@0.1.0`。`moon publish` 完成包内验证后，服务器返回 200 OK，命令退出码为 0。

模块入口：[Noverberrain/moonbinlog](https://mooncakes.io/docs/Noverberrain/moonbinlog)。发布后已用浏览器确认文档页显示 0.1.0 (latest) 和公开 API 导航。本次发布只上传 Mooncakes 包，GitHub 新提交仍按用户要求等待推送确认。

## 发布快照

| 项目 | 记录 |
| --- | --- |
| 模块 / 版本 | Noverberrain/moonbinlog / 0.1.0 |
| 源码提交 | [d3fc1f7](https://github.com/Noverberrain/moonbinlog/commit/d3fc1f73cd0e3e1f3314bd03eba390745ca33881)；发布时该提交尚在本地 |
| 归档 | _build/publish/Noverberrain-moonbinlog-0.1.0.zip |
| 归档 SHA-256 | b633bd98ca654a78f73ae2eb27970ecf182ce69acaff3dad773b56df20c31966 |
| 包内容 | 284 个归档条目；包含解析库、CLI 源码、文档、许可证和固定样本 |
| 许可 | Apache-2.0 |

归档中没有项目构建目录、Git 目录或依赖缓存；九份真实 binlog 与原文件逐字节一致。发布前已在解包副本运行 native 严格检查、384 项 MoonBit 测试、CLI 构建及四步演示，全部通过。此前完整 3521 个 CLI 场景的结果见 [干净克隆记录](acceptance-checklist.md)。

0.1.0 的归档记录的是发布前快照，其中 README 的发布状态文字仍是当时的准备状态。本页及 GitHub 后续提交记录实际发布结果；没有覆盖或重复上传同一版本。

## 从 Mooncakes 安装

在自己的 MoonBit 项目根目录执行：

```powershell
moon add Noverberrain/moonbinlog@0.1.0
```

在需要调用解析库的包内，通过 moon.pkg 导入：

```text
import {
  "Noverberrain/moonbinlog" @binlog,
}
```

例如 `@binlog.validate_file_header(data)` 校验四字节文件标识；完整文件遍历可使用 BinlogFileReader，逐个完整事件输入可使用 BinlogEventStream。API 签名与更多示例见 [可执行文档](../README.mbt.md)。已验证后端为 native；本次没有新增其他平台的运行兼容性结论。

## 独立消费者验证

发布后新建了独立模块，通过 `moon add Noverberrain/moonbinlog@0.1.0 --no-update` 从注册表实际下载该版本。消费者没有使用本仓库的本地路径依赖，模块配置和下载后的依赖清单均指向 0.1.0。

消费者的普通代码调用公开的 validate_file_header；独立 smoke 测试导入 BinlogFileReader、BinlogEventStream、GtidEvent 和 PreviousGtidsEvent，解析发布包内真实日志：18 个事件、assigned GNO 2/3/4、历史区间 [1,2)，逐事件接口与文件遍历的偏移和事件头一致。严格 native 检查、该项测试（--deny-warn）和 moon info 均通过。

这 1 项是仓库外的安装验证，不计入原仓库 384 项测试或 3521 个 CLI 场景；消费者保存在已忽略的 _build/mooncakes-consumer-0.1.0。没有把测试模块作为新的生态包发布。

## 账号问题与命令返回值

此前 dry-run 返回 403 User mismatch，原因是认证账号与 Noverberrain 命名空间不匹配。参赛者重新登录后，dry-run 返回 202 Accepted，正文明确表示检查成功且未修改服务器，但当前 CLI 仍以非零退出。本次正式发布返回 200 OK 且退出码 0，并已用实际下载和消费者测试确认结果。

## 与赛事验收的关系

官网链接的 [章程验收段落](https://bxup9uklfcb.feishu.cn/wiki/Dx4Bwd6D1i3GfHkajQCcF7SznEd#doxcnhJF38hpDWBd4wNdweX6J5b)列有发布到 Mooncakes 的要求。该节仍残留 9 月日期，[十月官网](https://moonbitlang.github.io/Hackathon2026/)列出的截止日期是 10 月 31 日；本期最终提交方式仍按赛事组通知确认。

已查看的官网飞书入口标题是项目申报，没有确认独立验收入口。本次没有填写表单、上传附件或代为确认诚信承诺；包发布成功也不表示已完成赛事验收。

## 可用于验收沟通的进度说明

MoonBinlog 的离线解析库、native CLI、GTID 事务导出和单文件逐事件读取已经完成。项目有 384 项 MoonBit 测试、3521 个 CLI 场景和四步演示，九组真实 MySQL 8.0.43 日志与官方输出有对照记录。解析库 0.1.0 已发布到 Mooncakes，并在独立项目中完成安装和公开 API 验证；使用方法、支持范围和复现命令均在仓库记录。
