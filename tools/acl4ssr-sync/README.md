# ACL4SSR 上游更新与生产发布

目标：持续获取 ACL4SSR 更新，保存未被上游接受的个人修改，更新当前已部署的规则。采用 Git merge，不改写历史。

## 分支与目录

- 正式规则仓库：`D:\Temp\Gitpath\ACL4SSR`，日常维护分支 `local-production`。
- `review-rules-20260917` / `update-ruleset-2026-07` 保留 PR #410 的筛选版本，自动维护不提交或推送到 PR 分支。
- `D:\Temp\Gitpath\ACL4SSR-1` 是原有脏工作区，保留不动。
- 工具源码：本目录。运行前复制到 `D:\Temp\CodeTemp\ACL4SSR-upstream-maintenance-20261010\runtime`；所有日志、状态、备份与测试输出留在 CodeTemp。
- 生产目标：`Y:\Public\subconverter\rules\ACL4SSR\Clash`；其兄弟目录 GOUKI 不在发布范围内。

首次登记现有 364 个生产文件。只更新登记文件，不补齐上游缺失的 196 个文件，不删除、改名生产文件。现有 `.list`、`Providers/*.yaml` 的变化可自动发布；配置文件变化需人工审查。

`local-production` 从 2026-09 上游基线建立，先保存生产的 8 个个人修改（包括最新 Twitter），再合并新上游。它反映实际部署需要，与 PR 筛选内容不同；GOUKI 里的 Claude/Gemini/HBO/NaSDDNS 仍按原配置优先使用。

## 手动执行

依赖现有 Git、Python 3.12/PyYAML、Mihomo，无新增常驻服务。不要在正式源码目录直接运行脚本；脚本会拒绝在 CodeTemp 外写日志。

```powershell
$runtime = 'D:\Temp\CodeTemp\ACL4SSR-upstream-maintenance-20261010\runtime'
# 只读预览：fetch 和 merge-tree 写 Git 对象/远端跟踪引用，但不改工作区和生产内容。
python -B "$runtime\sync.py"
# 预览、验证、合并本地维护分支并发布。
python -B "$runtime\sync.py" --apply
```

`config.json` 指定仓库、生产目录、分支、上游 URL 和 Mihomo 路径。`state.json` 保存登记文件清单及最后成功发布的 SHA256；不要删除后重新扫描来掩盖错误。它和本地分支一起构成更新基线。

执行顺序：

1. 获取进程锁，检查分支、工作区、Git 操作状态、生产目录与所有登记文件哈希。
2. `fetch upstream`，明确使用 `upstream/master`；上游改写/回退历史时停止。
3. 用 `merge-tree` 模拟合并；冲突时停止，不留下半完成的 merge 工作区。
4. 保存候选和差异清单，验证变化文件的内联规则与 classical Provider 语法。
5. 重新检查生产和 Git 状态，执行 merge，并核实结果与验证过的树一致。
6. 先备份全部待更新文件；逐文件写入同目录临时文件，回读后替换，再回读确认。
7. 全部成功才更新状态。日志为 `sync.log`，每次详情、候选、备份和发布进度在 `runs/<时间>/`。

语法检查不验证域名归属、地区解锁或实际节点行为。每次值得关注的服务规则更新后，应重新生成订阅并抽查实际分流。subconverter 的规则缓存行为取决于具体入口与配置，不应仅凭 `update_ruleset_on_request=false` 判断是否必须重启。

## 后续个人修改

生产目录被手动编辑后，自动发布会停止。这是为了保留新改动。

1. 在 `local-production` 上将该生产文件复制到对应 `Clash/` 路径。
2. 审查 `git diff`，确认规则、顺序和影响范围后提交。
3. 对该文件重新登记，例如：

```powershell
python -B "$runtime\sync.py" --record-live Ruleset/Twitter.list
```

重新登记只接受已经提交且与生产内容一致的文件，并检查其余登记文件没有变化；不自动吸收未审查内容。多个生产文件同时变化时，一次审查并提交全部差异，再将这些相对路径一起传给 `--record-live`。

若合并上游发生冲突，在本地人工 merge 并检查后再发布。禁止用 `reset --hard`、强推或整目录覆盖解决。上游最终接受了相同修改时，Git 通常会自然消除对应差异，但仍需审查规则顺序与重复项。

## 失败与恢复

- Y 盘是 RaiDrive 映射。只有映射可用时才运行；Windows 登录会话不可用时应跳过，不能假设 SYSTEM 能访问 Y 盘。
- 多文件发布不具备全局原子性。网络中断可能使部分文件已更新，查看 `publish.json` 的 completed/pending/failed 和备份。状态未推进时，下一次会拒绝覆盖已变化文件。
- 恢复前先比较生产哈希、候选和备份，确认没有新的人工修改，再逐文件恢复备份或完成剩余发布；不要盲目整目录回滚。
- 失败可能留下 `.文件名.acl4ssr-<id>.tmp`，确认无运行任务后人工处理。
- 本地 Git 合并成功但生产失败时，保留该提交；修复生产状态后重试，无需撤销 Git 历史。
- GOUKI 自定义规则应在个人配置项目另行版本化；当前工具不会修改它，也不会把它提交到 ACL4SSR 上游。

## 定时安排

2026-10-10 已注册并启用 Windows 任务 `\ACL4SSR-Weekly-Upstream-Sync`：

- 每周日 04:00，北京时间；首个计划时间为 2026-10-11 04:00。
- 使用 `SWIFT3-470016G\gouki` 的交互登录会话和普通权限，不保存登录密码。
- 启用错过时间后补跑；不唤醒计算机。用户未登录或 Y 盘不可用时不能完成更新。
- 单实例运行，最多执行 15 分钟；失败后间隔 30 分钟最多重试 2 次，仍失败则保留日志待排查。
- 允许电池供电时运行，切换为电池供电不会主动中断正在发布的文件。

任务入口应使用 `C:\Program Files\PowerShell\7\pwsh.exe`，不存在时使用 `C:\Users\gouki\AppData\Local\Microsoft\WindowsApps\pwsh.exe`。不要引用随升级变化的 Store 安装目录。运行脚本见 `run-sync.ps1`，任务应指向 CodeTemp 的执行副本。

当前使用 WindowsApps 稳定别名，参数为 `-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File "D:\Temp\CodeTemp\ACL4SSR-upstream-maintenance-20261010\runtime\run-sync.ps1" -Apply`，工作目录为同一 runtime。任务在后台运行，不弹出终端窗口。

```powershell
# 查询下一次时间和上次退出码，0 表示成功。
Get-ScheduledTaskInfo -TaskName 'ACL4SSR-Weekly-Upstream-Sync'
# 按需手动触发同一任务。
Start-ScheduledTask -TaskName 'ACL4SSR-Weekly-Upstream-Sync'
# 需要暂停自动更新时执行；恢复使用 Enable-ScheduledTask。
Disable-ScheduledTask -TaskName 'ACL4SSR-Weekly-Upstream-Sync'
```

清理 CodeTemp 时须保留上述 runtime，它包含在用的执行文件、部署状态、日志和备份。任务定义备份为同一任务目录下的 `scheduled-task.xml`；注册记录与试运行结果也保存在该目录。改变运行路径前需要同步调整任务入口并重新验证。

长期离线无人登录也需要更新时，应另做 NAS 上的计划任务；当前 Windows/RaiDrive 方案不能提供这种保障。

## 测试和实施记录

2026-10-10：先编写测试，再实现；11 项测试通过，包含真实 Git 仓库中的干净合并、冲突停止、脏工作区拒绝、预览不发布、二次幂等、个人规则保留及已提交生产编辑登记。模拟写失败确认旧文件保留。测试从 CodeTemp 副本执行，测试夹具留在那里。

同日启用每周任务，通过任务调度器在 14:22:37 发起实际试运行，14:23:43 完成，退出码为 0。全部 364 个登记文件通过检查，0 个待发布变更，Git 工作区干净。验证记录见 `scheduled-trial-result.json`，最新状态与运行日志已更新。

生产候选与最终发布结果见同日任务目录的 PLAN.md / REPORT.md，以及 runtime/runs。首次候选仅包含 ProxyGFWlist 的 list/Provider 和 UnBan Provider。其余个人规则按原样保留。
