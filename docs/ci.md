# Windows native CI

[工作流](../.github/workflows/ci.yml) 名称为 CI，检查任务名称为 Windows native。触发范围为推送 main、目标为 main 的 pull_request，以及 workflow_dispatch 手动触发；没有路径过滤，文档和脚本改动也会检查。相同分支有新运行时取消旧运行，单次最多 30 分钟。

手动触发入口需要工作流已存在于默认分支。首次基线提交 19102ce 的[GitHub 托管运行](https://github.com/Noverberrain/moonbinlog/actions/runs/40107571568)已经通过；后续提交以仓库 [Actions 页面](https://github.com/Noverberrain/moonbinlog/actions) 的各自结果为准。

## 固定环境

| 项目 | 配置 |
| --- | --- |
| 托管镜像 | windows-2022，x64；镜像内系统补丁和 MSVC 小版本由 GitHub 维护，并非完全冻结 |
| 编译环境 | ilammy/msvc-dev-cmd 初始化 x64 MSVC |
| MoonBit / core | 0.10.15+943464bfa；对应 moon 0.1.20261012 |
| Python | 3.13.9，仅使用标准库 |
| 解析库依赖 | 沿用 moon.mod 中 async 0.21.3、x 0.5.5 |

checkout、setup-python 和 msvc-dev-cmd 均固定到已核对的完整提交 SHA。工作流仅申请 contents: read，并关闭 checkout 凭据持久化；不使用额外密钥，不发布包、推送提交或修改仓库保护规则。

[安装脚本](../scripts/install_ci_moonbit.ps1) 从官方地址获取固定版本 Windows x64 和 core ZIP，校验脚本内的 SHA-256 后解压。工具链放在 runner 临时目录的 moonbinlog-moonbit，不替换用户现有 .moon；若目标目录已存在则失败。二进制 ZIP 哈希已与官方 .sha256 对照，core ZIP 哈希从该版本官方归档下载后计算并固定。

安装后构建 core 的打包产物，再更新包索引，最后执行统一检查。归档、索引和依赖下载需要联网。暂未缓存编译产物或上传可执行文件，避免首批 CI 引入额外的缓存/发布行为。

## 检查内容

[scripts/ci.ps1](../scripts/ci.ps1) 逐条执行，任一外部命令非零退出即失败：

1. 输出工具链/Python 版本，检查 MoonBit 格式及 native 严格类型检查。
2. 运行全部 native 测试并构建 CLI；当前为 292 项 MoonBit 测试。
3. moon info 重新生成接口，检查所有 .mbti 相对 HEAD 的差异，并拒绝未跟踪的新接口文件。
4. 检查十四组合成样本、六组真实 MySQL 日志（含三组 JSON 捕获）及 schema 示例的一致性。
5. 运行事件、行变化、事务、筛选和 JSON CLI 脚本，当前共 360 个场景，并核对官方行镜像。
6. git diff --check 检查工作区补丁中的空白错误。

所有日志均为仓库固定样本，不启动 MySQL 或连接业务服务。MSVC 编译官方 async 依赖时既有 EINVAL 宏重定义 C4005 警告仍可能出现；本项目的 MoonBit 警告按错误处理，没有修改依赖源码。

## 本地复现

Windows 已有对应 MoonBit、Python 和 MSVC 环境时，在仓库运行：

```powershell
moon update
if ($LASTEXITCODE -ne 0) { throw 'moon update failed' }
./scripts/ci.ps1
```

统一脚本自动切换到仓库根目录。它会生成接口，但不会提交或暂存文件；新增/修改公共 API 后应先确认生成接口并提交，再以 HEAD 为基准执行完整 CI。

如需单独安装固定版本，指定一个不存在的新目录：

```powershell
./scripts/install_ci_moonbit.ps1 -InstallDir 'E:/temp/moonbinlog-toolchain'
```

脚本在当前 PowerShell 进程前置安装目录的 bin 到 PATH；GitHub Actions 中同时通过 GITHUB_PATH 供后续步骤使用。初次本地验证在忽略的 _build/ci-toolchain 中独立安装并运行相同检查入口，使用 actionlint 1.7.12 及 PowerShell AST 检查语法；上述首次云端运行也已成功完成。

## 更新与排查

升级工具链时同时更新安装脚本中的版本与两个哈希，核对官方归档，再重新安装并执行全套检查；不要仅把版本替换为 latest。修改 Actions 版本时核对上游标签对应的完整提交 SHA。升级 Python 或 runner 镜像也应重新验证 native 构建和五组 CLI。

失败日志会显示实际版本及失败命令。下载/索引失败先检查网络与归档可用性；接口漂移应本地执行 moon info 并审查差异；协议/CLI 失败应按脚本输出定位，保留损坏样本及错误退出码，不能通过跳过检查掩盖失败。

配置依据：[GitHub 工作流语法](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)、[MoonBit 官方下载和校验说明](https://www.moonbitlang.com/download/)、[官方 Windows 安装脚本](https://cli.moonbitlang.com/install/powershell.ps1)。本项目只对安装步骤做隔离目录、固定版本及哈希处理，解析器运行逻辑未变。
