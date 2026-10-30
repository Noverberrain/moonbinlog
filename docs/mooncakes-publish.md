# Mooncakes 发布预检查

状态更新：2026 年 10 月 31 日。模块为 `Noverberrain/moonbinlog`，拟发布版本 `0.1.0`。本轮完成了本地打包和包内代码验证，尚未完成实际发布，不能在验收材料里填写“已发布”。

## 为什么补这一项

官网链接的 [黑客松章程“项目验收”一节](https://bxup9uklfcb.feishu.cn/wiki/Dx4Bwd6D1i3GfHkajQCcF7SznEd#doxcnhJF38hpDWBd4wNdweX6J5b)将发布到 mooncakes.io 列为申请完成支持的要求之一。此前的干净克隆报告验证了代码复现，没有核对发布状态，这项应单独补齐。

该节标题仍写着 9 月日期，而 [十月官网](https://moonbitlang.github.io/Hackathon2026/)写的是 10 月 31 日截止。10 月发布要求和实际验收提交渠道应向赛事组确认，不把旧日期直接套用到本期。

本轮浏览器核对了官网的飞书入口，页面标题为“2026 MoonBit 国产基础软件开源大赛-10月黑客松 项目申报”，表单提示最多提交三次、可以修改；没有在已查看页面中找到独立验收入口。已通过初审的参赛者应先确认是修改原记录还是另行提交验收，避免重复报名。没有填写或提交表单。

## 已完成的发布准备

- 在 `moon.mod` 补齐 repository，指向实际 GitHub 仓库；模块名、版本、Apache-2.0 许可证和依赖保持原样。
- 执行 `moon package`，生成 `_build/publish/Noverberrain-moonbinlog-0.1.0.zip`。
- 核对归档包含源代码、包配置、许可证、README、CLI 及真实样本，没有混入 `_build`、`.git`、`.mooncakes`、`.repos` 或 target；九份 binlog 与源文件逐字节一致。
- 将归档解压到新目录，运行 native 严格检查、384 项 MoonBit 测试、CLI 构建和四步演示，全部通过。依赖使用本机缓存，不是全新机器安装测试。

这次没有修改解析实现或公共 API，没有把包上传成功。此前完整 CI 的 3521 个 CLI 场景通过记录见 [干净克隆检查](acceptance-checklist.md)；本轮解包验证运行的是 384 项测试和四步演示，没有再重复全部 CLI 回归。

## 当前阻碍

`moon publish --dry-run` 已通过本地打包和解包后的类型检查，但服务器返回 403，原因是当前认证用户与模块配置中的 `Noverberrain` 不一致。dry-run 不执行实际发布，但仍会请求服务器校验，不能作为无需账号的纯离线检查。

保留项目的 Noverberrain 命名空间。不要为了绕过账号错误改成另一账号，也不要把令牌写进仓库。需要参赛者在终端运行 `moon login`，登录或切换到拥有该命名空间的账号；认证由本人完成。

本轮 `moon search moonbinlog` 没有返回本模块，网页文档路径显示 Docs unavailable；这些现象不能单独证明模块从未发布。登录正确账号后还需核对版本记录，确认 `0.1.0` 可用，再决定是否发布该版本。

## 账号确认后的步骤

在仓库根目录执行，下面的最后一条才会实际上传包：

```powershell
moon login
moon package
moon publish --dry-run
moon publish
```

实际发布需要参赛者确认。若 dry-run 仍失败，应先处理具体错误；不能把失败当成发布成功。成功后应检查模块页/版本记录，并从另一个 MoonBit 项目安装该版本，核对公开 API 能导入使用，再将发布链接补回验收材料。

本机工具链的命令选项已通过 `moon package --help`、`moon publish --help`、`moon login --help` 核对。本轮没有执行不带 dry-run 的 `moon publish`，没有切换现有登录账号。

## 可用于验收沟通的进度说明

MoonBinlog 的离线解析库、native CLI、GTID 事务导出和单文件逐事件读取已经完成。远端代码通过 Windows native CI，包含 384 项 MoonBit 测试、3521 个 CLI 场景和四步演示，九组真实 MySQL 8.0.43 日志与官方输出有对照记录。Mooncakes 包已完成打包和解包验证，正在处理发布账号与命名空间不一致的问题，实际发布尚未完成。

验收材料可以使用已在远端的 [申报书](https://github.com/Noverberrain/moonbinlog/blob/62b7638d35eb3ca47a7756e43636b2ed344666d4/PROPOSAL.md)、[演示说明](https://github.com/Noverberrain/moonbinlog/blob/62b7638d35eb3ca47a7756e43636b2ed344666d4/docs/acceptance-demo.md)和 [CI 记录](https://github.com/Noverberrain/moonbinlog/actions/runs/41089733668)。这段说明不包含未完成事项的成功承诺。
