# 订阅维护与实时转换源码记录

2026-10-10 将部署中的 submgr 与 UA 反代统一纳入 `GOUKI9999/ConverterRule-Tools`。此前本仓库跟踪转换规则；`Allscript_backup` 保存旧 GPTsub 脚本，未跟踪这两项新服务。

| 仓库路径 | 部署位置 | 用途 |
|---|---|---|
| `submgr/submgr.sh` | 路由器 `/www/submgr/submgr.sh` | 定时拉取、转换、保存与 TG 报告 |
| `submgr/config.example.json` | 正式配置位于 `/www/submgr/config.json` | 可复制参考的配置结构，实际凭据只在正式配置中 |
| `airport_proxy/ua_proxy.py` | NAS `/volume1/Public/subconverter/airport_proxy/ua_proxy.py` | 实时转换请求的 UA 改写 |
| `airport_proxy/domains.json` | NAS 同目录 | 域名/IP 与 UA 配置 |
| `Subconverter/config/`、`Subconverter/base/` | NAS `/volume1/Public/subconverter/config/`、`base/` | 既有转换配置与模板 |

两条路径独立运行：submgr 使用落地原始文件转换；实时反代接收含机场真实 URL 的转换请求。统一 Git 记录不意味着改变它们的运行方式，也不表示本次重新同步全部既有规则到 NAS。

开发阶段：最低数量检查已实现并部署；10 项隔离测试通过，非法阈值拒绝、旧配置兼容、正式输出校验和未变化。覆盖零节点、单通知节点、空/少规则、少组、多个阈值同时失败、首次发布、正常轮换和坏旧版不覆盖 previous。

路由器变更前备份：`/root/submgr-backups/quantity-limits-20261010-142701/`。详细部署记录：`/www/submgr/VALIDATION-20261010.md`。阈值检查下次 cron 生效。

升级：先检查配置和语法，再备份目标文件，替换脚本，运行 `--check`。配置示例不能覆盖已有正式配置。反代代码本次只归档现行版本，无须重启服务。仓库提交后通过提交号定位对应源码。

统一归档工具见 `tools/deployment-snapshot/README.md`：在既有 ACL4SSR 上游同步和生产发布成功后，记录当前 NAS 配置、规则、反代、网页以及路由器脚本并提交推送。不会合并 ACL4SSR 的 PR 筛选分支，也不会部署网页新版本。

当前网页实际为 cmliu/SUBWEB 静态部署，归档在 `subweb/current-dist/`；NAS 的本地资源保留层在 `subweb/local-overlay/`。公开仓库的 base/配置/笔记已脱敏；实际认证配置仍只在服务器上，归档模板不能直接覆盖正式文件。
