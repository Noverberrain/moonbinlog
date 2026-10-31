# MoonBinlog 验收演示

我平时做 Java 后端，遇到数据库变化时，习惯先看日志里到底记录了什么。这个项目做的是其中一层：用 MoonBit 读懂 MySQL Binlog，输出有类型的行变化，再按显式事务边界区分提交与回滚。

下面四步使用仓库里的固定 MySQL 8.0.43 日志，正常情况下几秒内可以跑完，首次构建和下载依赖另计。无需安装或启动 MySQL，也不连接业务数据库。它展示当前离线工具的行为，不代表已经实现实时 CDC。

## 一条命令运行

已验证环境为 Windows x64、MoonBit/core 0.10.18+6c83a7f62、moon 0.1.20261028、MSVC 和 Python 3.13.9。先确保 `moon version --all`、`python --version` 可用，native 编译环境按 [CI 说明](ci.md) 准备。首次获取依赖需要联网；依赖齐备后的四步演示本身无需联网。

在仓库根目录运行：

```powershell
python scripts/demo_acceptance.py
```

脚本先执行 `moon build --target native`，随后调用构建出的 CLI 并核对结果。也可从其他目录用脚本路径启动，它会以仓库根目录作为子进程工作目录。

已构建好的 CLI 可跳过构建：

```powershell
python scripts/demo_acceptance.py --exe _build/native/debug/build/cmd/moonbinlog/moonbinlog.exe
```

四步都符合预期时，演示脚本退出码为 0；构建失败、命令返回码或输出不符时非零退出。第四步中的 CLI 返回 1 是预期行为，脚本确认这个错误后才算通过。

## 演示顺序

| 步骤 | 观察什么 | 固定样本的预期结果 |
| --- | --- | --- |
| 1. 事件详情 | 从文件格式和 CRC32 开始，查看历史集合、GTID 与轮转 | 18 个事件和 1 条摘要；GTID 为同一 SID 下的 2、3、4；历史区间为 [1, 2)，轮转到 capture.000004、位置 4 |
| 2. MINIMAL 行变化 | 查看 INSERT/UPDATE/DELETE 的 before/after，以及未写入日志的列 | 3 个行事件、6 条变化；同时出现 Absent、SQL NULL 和 JSON null；行记录标记 unconfirmed |
| 3. GTID 提交事务 | 将 GTID 前缀、事务范围和已提交行值放在一起 | 3 笔提交、6 条变化；身份与第 1 步一致，row_changes 中的行标记 committed |
| 4. 未完成事务 | 在第一笔事务的 XID 之前截断副本，再解析 | CLI 返回 1，stderr 包含 IncompleteGtidTransaction；stdout 没有待提交行或成功摘要 |

第 2 步中，JSON 值以 `json_text` 字符串输出，包含精确的 `18446744073709551615`。消费方再次解析这个字符串时仍需保留大整数精度；原始字符串/BLOB 字段则按 hex 输出。

第 4 步不修改原日志。脚本根据第 1 步输出中的首个 XID 物理偏移，生成一份截断副本。这个例子说明“已经看到行事件”与“已经确认事务提交”有不同含义。

## 单独查看每一步

如果希望边运行边讲解，可在仓库根目录执行以下命令。`moon run` 首次运行时可能构建；正常输出为 JSON Lines。

```powershell
moon run --target native cmd/moonbinlog -- --stream --decode-gtid --decode-previous-gtids --decode-rotate fixtures/gtid-real/crc32-full.binlog
moon run --target native cmd/moonbinlog -- --stream --rows --schema examples/mysql-8.0-json-schema.json fixtures/mysql-json/crc32-minimal.binlog
moon run --target native cmd/moonbinlog -- --stream --transactions --with-gtid --include-rows --schema examples/mysql-8.0-json-schema.json fixtures/gtid-real/crc32-full.binlog
```

运行一键演示生成副本后，可以单独复现第 4 步；此命令应失败：

```powershell
moon run --target native cmd/moonbinlog -- --stream --transactions --with-gtid --include-rows --schema examples/mysql-8.0-json-schema.json _build/acceptance-demo/unfinished.binlog
```

## 输出在哪里

所有产物位于 `_build/acceptance-demo/`，已被 Git 忽略。重复运行会覆盖这里的同名演示文件，不改动 fixtures 或 schema。

| 文件 | 内容 |
| --- | --- |
| events.jsonl | 18 个事件及文件摘要 |
| rows.jsonl | 6 条未确认行变化及行摘要 |
| transactions.jsonl | 3 笔 GTID 事务及事务摘要 |
| unfinished.binlog | 首笔事务缺少提交事件的副本 |
| unfinished.jsonl / unfinished.stderr.txt | 空 stdout 及预期 EOF 错误 |
| report.json | 四步命令、返回码、记录数量与原输入 SHA-256；全部成功后 status 为 passed |

每一步都保存对应的 `.stderr.txt`，正常步骤应为空。每次开始时 report.json 会先标为 running；只有当前这次完成全部检查后才写成 passed，因此失败后不能把目录里之前留下的输出当作本次成功结果。

## 讲解与验收边界

可以按这个顺序介绍：先用事件列表证明日志能被校验和切分，再用 MINIMAL 行镜像解释数据语义，接着展示 GTID 与提交结果，最后用未完成事务说明错误边界。样本来源及官方 mysqlbinlog 对照见 [JSON 捕获](../fixtures/mysql-json/README.md) 和 [真实 GTID 捕获](../fixtures/gtid-real/README.md)。

本演示只覆盖四条代表路径。全部格式、字段、配额及异常回归仍以 `./scripts/ci.ps1` 为准，目前有 384 项 MoonBit 测试和 3521 个 CLI 场景，另外执行本演示四步。

当前不支持实时订阅、自动跟随轮转、自动提交/DDL/XA 推断或跨文件事务续接。schema 必须匹配历史表结构；逐事件读取仍需完整事件和事务缓冲，默认文件上限 64 MiB、最大 2 GiB−1，详见 [流式读取范围](cli-stream.md)。这些固定小样本没有提供吞吐或内存峰值结论。

演示通过表示本地四步复现成功。按参赛者提供的验收指南，审核通过后无需再交表格，保持开发并将对应内容上传 GitHub 即可；脚本不会上传产物或代办赛事操作。

准备提交时可参考 [干净克隆复现结果与验收清单](acceptance-checklist.md)，检查所引用的提交版本及材料链接。
