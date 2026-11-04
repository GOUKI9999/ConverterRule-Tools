# Polymarket API 专用 fallback

> 历史记录：本方案已按用户要求撤回，当前统一使用Weather，不再有独立Polymarket分组。请以[Weather组纠正与维护](WEATHER_GROUP_2026-11-04.md)为准，不照本页部署或执行旧回滚。

## 目标与范围

- 独立 Polymarket/Fallback_Polymarket，不再要求仅香港；Weather 及其他应用代理选择保持。
- 只排除官方明确限制 API 新增订单的地区标签，保留日本/韩国/爱尔兰/荷兰等仅前端受限候选。
- 以 CLOB API 根端点做 HEAD 探针，HTTP 200、300 秒、5 秒超时、lazy=false。
- 仅靠节点名称及 HTTP 探针不能证明实际出口或账户资格，不宣称可保证所有节点交易成功。
- 先备份、合成节点转换测试，再修改模板和 191.1 的相关 YAML；不重新下载机场、不改其他分组。

## 验证计划

1. 混合地区、英文简称、带标签、混合出口名称、全受限池，验证候选及 REJECT。
2. 通过当前 subconverter 生成真实配置，比较非目标组和非目标域名规则保持一致。
3. 路由器内核配置测试通过后热重载，保存源配置/运行配置/覆写钩子及组选择备份。
4. 确认实际成员、选中节点、API 探针及 1.253 请求链；只读业务检查，不发测试订单。

## 实现与验证结果

- 生产源为 Y:/Public/subconverter；本仓库是公开脱敏归档且整体快照较旧，本批只同步 Polymarket 相关变更，不覆盖整份生产模板。
- 新增 Polymarket.list，并在 Weather 之前引用；移除 Weather.list 中的 Polymarket 后缀。其他天气域名及旧 Weather 分组不改。
- 节点从仅香港 7 个扩大为香港、日本、韩国、马来西亚、印度 17 个候选，另保留 REJECT。候选不等于实时可用。
- 优先未带方括号标签的香港候选，再其他未带标签候选，再其他符合排除条件的候选；保持原节点顺序、去重。香港仅优先，不再是准入条件。
- 当前 subconverter 实际生成混合 15 节点配置：52 组、107537 条规则；非目标组和非目标规则与修改前一致。全受限 4 节点样本仅剩 REJECT。
- Mihomo 配置验证通过，热加载后原 46 个 Selector 选择保持。未刷新机场订阅或重启服务。
- 8 项单元测试全部通过；Ruby 覆写助手的局部修改、重复执行幂等、无目标组不写文件三项在路由器验证通过。
- 13:02 左右按专用 URL 的 extra.alive 实测 6 个候选可用，当前香港移联01。数量随网络波动，不能当成持续 SLA。
- 实际主机 192.168.1.253 的 clob/data-api/gamma-api 请求已确认命中新链 Polymarket -> Fallback_Polymarket -> 香港节点。GET /time 与 Gamma markets 返回 200；零地址 Data API 请求为参数拒绝 400，不计业务成功。
- 经生产代理的地区接口返回 country=HK、blocked=false。未发送测试订单，不据此宣称已验证下单/成交。

## 两个重要陷阱

1. Mihomo URLTest 使用 HEAD。实测 /time GET=200，但 HEAD=405，不能用于严格 200 的原生健康探针；最终使用 `https://clob.polymarket.com/?polyclaw-health=1`，HEAD=200。GET /time 仅用于独立 API 验证。
2. 控制器 delay 返回正数、或节点顶层 alive=true，都不代表指定状态码匹配。必须看节点 `extra[完整探针URL].alive`。状态按 URL 隔离而非按分组隔离，因此使用独立查询参数，避免旧 Weather 同 URL、expected-status=* 的检查污染新组。

subconverter 的经典 custom_proxy_group 不输出 expected-status。因此路由器覆写钩子调用本仓库 `openclash/polymarket_health_override.rb`，在每次生成后补齐 URL/status/timeout/lazy；仅改 INI 不能获得严格状态校验。新客户端没有该覆写时，不能宣称自动过滤 403。

安装时保留原钩子所有内容，在最终 exit 0 前调用：

```sh
ruby /etc/openclash/custom/polymarket_health_override.rb "$CONFIG_FILE" >> "$LOG_FILE" 2>&1
```

## 限制与待观察

- 名称过滤不能证明实际出口；纯数字、被转换器去掉国旗后丢失地区信息的名称仍可能被收入。需要结合实际地区检查，不能把正则作为交易资格授权。
- 官方当前区分 API 受限与仅前端受限，日本/韩国/爱尔兰/荷兰不因名称被整体排除。但隔离实测日本节点 GET /time=200、地区接口 blocked=true，韩国某节点 GET /time=451。不能把这些候选都标为已验证可交易，交易端遇到地区拒绝仍应停止该请求，不绕过资格限制。
- 加拿大和乌克兰仅指定部分地区受限，按已知省/地区名称排除；仅写国家的名称不能判断具体出口。
- REJECT 确保生成时零候选不会自动改为 DIRECT。Mihomo 原生 fallback 在全部成员探测失败时会尝试首成员；末尾 REJECT 不是严格的“所有失败必拒绝”保证。
- 生产主机直接 curl polymarket.com 曾 DNS 解析失败，但通过生产代理地区接口成功，交易 API 子域可访问。本批未擅自修改 DNS；后续监控需单列 DNS、HTTP、地区拒绝。

## 回滚与证据

- 路由器原始源配置、运行配置、旧覆写钩子和组选择保存在 `/root/polymarket-proxy-20261104-v2/`，目录权限 700，不导出代理凭据。
- 路由器执行 `python3 /root/polymarket-proxy-20261104-v2/router_switch.py rollback`，恢复源/运行 YAML 和原钩子并热加载。新安装 helper 未删除但不再被钩子调用。
- 模板原件备份与合成验证证据在 `D:/Temp/CodeTemp/polyclaw-proxy-rewrite-20261104/`。恢复模板时使用独立新文件替换，不直接缩短 WebDAV 原文件。本次确认直接缩短会残留旧尾部，已用替换和 SHA256 比对修正。
- 重新部署后需复验非目标配置一致、组选择、核心语法、指定 URL 状态以及业务请求路由，不能只看配置文件写入成功。

## 依据

- [Polymarket 官方地区限制](https://docs.polymarket.com/api-reference/geoblock)
- [Mihomo 策略组与 expected-status](https://wiki.metacubex.one/en/config/proxy-groups/)
- [Mihomo REST API](https://wiki.metacubex.one/en/api/)
- [Mihomo URLTest 源码：HEAD 与每 URL 状态](https://github.com/MetaCubeX/mihomo/blob/Meta/adapter/adapter.go)
- [Mihomo fallback 源码：全部失败行为](https://github.com/MetaCubeX/mihomo/blob/Meta/adapter/outboundgroup/fallback.go)
