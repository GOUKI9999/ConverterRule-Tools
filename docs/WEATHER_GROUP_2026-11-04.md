# Weather 组纠正与维护

## 当前设计

用户要求继续沿用 Weather，不接受独立 Polymarket 命名、单一 fallback 入口及巨型生成正则。本批撤回上一轮独立分组方案，只改变相关 Weather 配置。

- Weather 的 select 第一项为既有 Fallback_Weather，随后是香港、日本、韩国、欧澳、小众国家、Proxies、ProxiesFree、DIRECT，共9项。
- 第一项负责专用自动切换；其余8项仅为手动入口，不会因自动池故障就自动改走DIRECT。
- 规则统一放回 Weather.list，删除独立 Polymarket.list 和对应ruleset/分组。已有其他分组和规则不改。
- INI中自动池只保留一条原生脚本引用，不再包含重复的大段排除正则：

```ini
script:snippets/weather_filter.js
```

## 手动维护

编辑 `Subconverter/snippets/weather_filter.js`（运行源为Y:/Public/subconverter/snippets/weather_filter.js）。

- BLOCKED每个地区一行：ISO代码和名称匹配正则。代码和国旗自动匹配，不必再改三个巨大正则或Python生成器。
- PARTIAL只维护加拿大、乌克兰等部分受限地区；不把整个国家一律排除。
- 保留原顺序：未带标签香港优先，其余未带标签其次，带方括号标签最后。香港不是必需条件。
- 日本/韩国/爱尔兰/荷兰等仅前端受限地区不因名称整体排除。名称不是实际出口或账户资格证明。
- SS协议标签不误判为南苏丹；国家全名与旗帜仍排除；空候选时INI中显式REJECT兜底。
- 手动选通用/混合地区组可能进入受限出口，它们不经过专用自动池过滤。不应绕过应用侧地区拒绝。

这是subconverter已有的script组筛选功能，不新增服务、依赖或cron。当前25500服务已用真实合成转换验证脚本可执行；如果迁移到禁用JS或未授权本地脚本的服务，必须先验证，不能只看INI语法正确。

本地测试：

```sh
node tools/weather-fallback/test_filter.js
```

## 健康检测与部署

- 保留API专用HEAD探针 `https://clob.polymarket.com/?weather-health=1`，间隔300秒、超时5000ms、lazy=false、严格HTTP200。
- 不用/time作原生探针：GET成功但HEAD=405。GET/time只用于业务读取验证。
- `openclash/weather_health_override.rb` 只补齐Fallback_Weather的健康字段；191.1原覆写钩子保留SubFetch逻辑，改为调用该助手。
- INI经典语法不输出expected-status，其他客户端没有此覆写不能宣称严格过滤403。
- 看节点 `extra[完整探针URL].alive`，不能用顶层alive或控制器返回正延迟代替状态码验证。
- 原生fallback全部探针失败时仍会尝试首成员，末尾REJECT不是严格全失败停流开关。

## 已完成验收

- 本地8类筛选行为和模板约束通过。
- 实际subconverter生成50组、107537条规则；混合14节点样本选择正确，全受限4节点样本仅REJECT；非目标组和规则与纠正前一致。
- 从实际路由器导出的无凭据节点名称运行新脚本，得到17个候选加REJECT，与实际运行池完全一致。
- 源与运行YAML非目标内容一致性、核心语法和热加载通过。运行配置中独立Polymarket分组已消失，46个可保留Selector选择保持。
- 生产主机GET CLOB/time=200；生产代理地区检查country=HK、blocked=false。未发测试订单，不声称已验证成交。
- WebDAV使用独立文件替换，避免文件缩短后的旧尾部残留；INI与暂存部署文件SHA256一致。

## 备份与回滚

本次纠正前的Y盘模板、规则和记录保存在 `D:/Temp/CodeTemp/weather-group-correction-20261104/before/`；验证与日志在同任务目录。

路由器纠正前源配置、运行配置、旧覆写钩子保存在 `/root/weather-group-20261104-v1/`，权限700。恢复纠正前状态（会恢复上一轮独立组）时执行：

```sh
python3 /root/weather-group-20261104-v1/router_switch.py rollback
```

完整回滚还需从本地before目录恢复Y盘模板和规则（包括被移除的独立规则文件），否则后续更新订阅会再次应用新结构。这不是回到半年前的交易配置，也不改变交易参数；勿使用旧任务的回滚脚本覆盖本次工作。

## 依据

- [subconverter原生组筛选脚本](https://github.com/tindy2013/subconverter/blob/master/README-cn.md)
- [平台API地区限制](https://docs.polymarket.com/api-reference/geoblock)
- [Mihomo健康检测字段](https://wiki.metacubex.one/en/config/proxy-groups/)
