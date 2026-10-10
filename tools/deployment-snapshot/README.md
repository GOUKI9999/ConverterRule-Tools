# 生产订阅组件统一 Git 归档

现有 ACL4SSR 工具仍负责合并上游、验证和发布到 NAS。它成功后运行本工具，将部署中的自定义规则、配置、网页、反代与路由器脚本同步到同一个配置仓库。

源码在此，执行副本和配置位于 `D:\Temp\CodeTemp\subscription-git-sync-20261010\runtime`。需要 Git、Python 3.12、已有 PyYAML、用户登录以及 Y 盘映射。

```powershell
# 预览，查看 runtime/last-plan.json。
python -B D:\Temp\CodeTemp\subscription-git-sync-20261010\runtime\snapshot.py
# 归档并提交推送。
python -B D:\Temp\CodeTemp\subscription-git-sync-20261010\runtime\snapshot.py --apply --commit --push
```

只同步已登记的 364 个 ACL4SSR 文件，且必须与原同步工具的发布状态/本地提交一致；不修改 ACL4SSR PR 分支、不删除生产文件、不覆盖 NAS。不另行 fetch 上游。

候选内容读取并检查完成后才写仓库。拒绝脏工作区、错误分支、生产漂移或不可访问目录。Python/JSON/TOML/YAML 进行语法检查；网页确认仍使用本地字体/图标/jQuery。发布快照 `deployment-snapshot.json` 记录来源与 SHA256，不含时间戳，所以无变化不会重复提交。缺失的历史文件不自动删除。

由于 GitHub 仓库公开，DoH key、token、节点 URI 会被脱敏或拒绝导出；实际 pref 记录为 `pref.current.example.toml`，个人 insert_url 清空。`GOUKI_Base.yml` 内 `DOGCLOUD_DOH_TOKEN` 是模板占位，不能直接覆盖正式配置。运行时配置、缓存、程序二进制、日志和备份目录不纳入快照。

网页当前是 cmliu/SUBWEB 的静态部署，不是旧 CareyWang/sub-web 源码。归档于 `subweb/current-dist`；NAS 的独立资源保留层于 `subweb/local-overlay`。本次不自动更新网页上游或重新 build。

失败不回滚既有 Git 提交：写入失败可能留下待审查工作区；push 失败可能留下本地提交。修复后按日志人工检查，再继续推送。定时器只在 ACL4SSR 原发布任务成功后执行本步骤；原规则发布已成功时，快照失败也不会撤销它。

规则保持生产原文，不为消除上游注释末尾空格而重写；`Subconverter/.gitattributes` 对 rules 范围关闭 whitespace 风格检查，其他源码继续检查。URL 查询参数（含编码形式）和已知订阅路径 token 同样脱敏。

`run-pipeline.ps1 -Apply` 串行调用现有规则 runtime 的 `sync.py --apply`，成功后调用本工具 `--apply --commit --push`。不带 `-Apply` 时两阶段均只预览。现有每周日 04:00 任务保持频率、用户、权限不变，仅入口改为这个执行副本。
