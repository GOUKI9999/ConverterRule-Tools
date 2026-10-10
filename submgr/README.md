# submgr：定时订阅维护

部署路径：路由器 `/www/submgr/submgr.sh`；正式配置为同目录 `config.json`。本目录记录实际部署源码和配置示例，订阅 token、TG token、节点凭据、日志、latest/previous 和运行状态不纳入版本控制。

首次安装可参考 `config.example.json`；升级仅替换源码，保留正式配置。脚本依赖 Bash、jq、curl 和 OpenWrt 常用文本工具。主流程为下载临时文件、原始格式/大小/污染检查、subconverter 转换、格式与数量检查、发布及报告。

| 机场 | 最低节点 | 最低规则 | 最低组数 |
|---|---:|---:|---:|
| Tladder | 5 | 10000 | 10 |
| Nerwo | 20 | 10000 | 10 |
| FubukiCloud | 10 | 10000 | 10 |

每机场配置 `min_nodes`、`min_rules`、`min_groups` 优先于全局 `options`。未配置时最低节点回退至 `node_min_keep`（默认 1），规则/组默认 0。节点阈值必须为正整数，规则/组阈值必须为非负整数。

任一数量不足时，不发布、不轮换 previous、不更新基线，报告列出实际数量与最低要求，错误结果留在 `/tmp/submgr_<机场>.rej`。首次发布同样检查。旧 latest 不满足当前阈值时，不用它覆盖 previous。下降 40% 继续只告警，通过最低数量检查的结果仍可发布。

数量检查不验证连通性、每个合并来源的完整性或完整 YAML 语法。合并输出中补充机场节点也参与总数量计算。

```sh
/www/submgr/submgr.sh --check
/www/submgr/submgr.sh --status
/www/submgr/submgr.sh --no-send
/www/submgr/submgr.sh --no-pull Nerwo
/www/submgr/submgr.sh --pull-only --no-send Tladder
/www/submgr/submgr.sh --send-report
```

`enabled: false` 暂停机场处理，新汇总报告按启用机场生成。`--no-pull` 使用现有原始文件重新转换；`--no-send` 保存报告；`--send-report` 汇总并推送各启用机场最后状态。默认完整运行会发送报告。

当前 cron：

```cron
0 5 * * * /www/submgr/submgr.sh --no-send >> /www/submgr/cron.log 2>&1
1 12 * * * /www/submgr/submgr.sh --send-report >> /www/submgr/cron.log 2>&1
```

测试在独立目录执行，使用转换桩函数，不访问机场、不发送 TG、不改正式输出：

```sh
TEST_DIR=/tmp/submgr-quantity-test bash submgr/tests/quantity-limits.sh
```

部署与反代对应关系见 [SUBSCRIPTION-DEPLOYMENT.md](../SUBSCRIPTION-DEPLOYMENT.md)。
