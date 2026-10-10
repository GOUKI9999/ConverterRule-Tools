# subconverter：URL 参数 vs .ini 配置 怎么选

来源：`asdlokj1qpi233/subconverter` 的 `README-cn.md`(与上游 `tindy2013/subconverter` 一致),下面每条格式都是从 README 原文摘录,不是转述,避免再出现"想当然"的格式错误(exclude_remarks 曾经被错误地要求一行一个,已用 README 原文纠正)。

规则集(`ruleset`/`clash_rule_base`)部分你已经很熟,这里不重复。

## 1. 判断标准：什么放 URL,什么放 .ini

| 类型 | 放哪 | 原因 |
|---|---|---|
| 每个机场都不一样、一次性的 | URL 参数 | 比如 `udp=`、`sort=`、`scv=`、`list=`,这些描述的是"这一条订阅要不要开某个开关",天然是 per-request 的 |
| 所有机场共用、长期不变的规则 | `.ini` `[custom]` | 比如 `exclude_remarks`、`rename`、`emoji`、`custom_proxy_group`,写一次全局生效,不用在每个 `convert_url` 里重复贴一遍 |

判断口诀：**改的时候要不要动 `config.json` 里每一条 airport 的 `convert_url`？如果要动很多条,说明它该挪进 `.ini`。**

**关键前提**(README 第 1142 行原文):

> 由外部配置中所定义的值会**覆盖** 主程序目录中配置文件里的内容

也就是说 `.ini [custom]` 里写的东西,和 URL 参数是**同一优先级链条上的两层**,不是"URL 管一部分、ini 管另一部分"——**URL 参数如果出现,会整个覆盖掉 `.ini` 里对应的设置项**,不是叠加。所以现在我们把 `exclude=`/`emoji=` 从 `convert_url` 里去掉是对的,如果哪天又手滑在某条 `convert_url` 里加回 `exclude=`,会让那一个机场单独绕过 `.ini` 的规则,而不是"额外补充"。

## 2. 每个 key 的准确格式(摘自 README)

### `exclude_remarks` / `include_remarks` —— 单行一条正则,支持括号分组,不支持 `!!import:`

README 原文示例(第 494-505 行):

```ini
exclude_remarks=(到期|剩余流量|时间|官网|产品|平台)
include_remarks=(?<=美).*(BGP|GIA|IPLC)
```

一行就是一条完整的正则,`()`/`|` 分组随便用,**不是"一个关键词一行"**——这是我之前说错的地方,已经用官方示例改正。它也不支持 `!!import:外部文件`,想改必须直接编辑 `.ini` 本体。

### `rename` —— 支持 `原名@新名` 格式 + `!!import:`

README 原文示例(第 1209-1210 行,属于 `[custom]` 外部配置块,注意这里 key 是 `rename`,不是 `[common]` 段落里的 `rename_node`):

```ini
;rename=Test-(.*?)-(.*?)-(.*?)\((.*?)\)@\1\4x测试线路_自\2到\3
;rename=\(?((x|X)?(\d+)(\.?\d+)?)((\s?倍率?)|(x|X))\)?@$1x
```

我们现在用的 `rename=!!import:snippets/rename_node.txt` 这种外部文件导入写法,README 正文没有直接给例子,但对照源码 `[custom]` 段的 key 解析逻辑(多值 key,和 `ruleset`/`custom_proxy_group` 走的是同一套 import 处理),以及我们自己 `snippets/rename_node.txt` 目前确实在生效,可以确认 `rename` 支持 `!!import:`。规则条数多、要长期维护时用这种方式最合适,一行一条 `原名@新名`。

### `emoji` / `add_emoji` / `remove_old_emoji` —— 分成"总开关"和"规则表"两类 key

README 原文示例(第 1213-1216 行):

```ini
;add_emoji=true
;remove_old_emoji=true
;emoji=(流量|时间|应急),🏳️‍🌈
;emoji=阿根廷,🇦🇷
```

- `add_emoji=true/false`、`remove_old_emoji=true/false`——布尔总开关,直接写在 `.ini` 里,不需要外部文件。
- `emoji=关键词正则,表情`——具体的"名字含XX就加YY表情"规则,一行一条,条数多的话用 `emoji=!!import:snippets/emoji.toml` 整体导入(我们现在这条是注释掉的,因为已经切到 `add_emoji=true` 走默认表情逻辑,没有另外自定义规则表)。

### `custom_proxy_group` —— 分组规则,支持 `!!import:`

README 原文示例(第 986 行):

```ini
custom_proxy_group=!!import:snippets/groups.txt
```

我们现在直接把十几条 `custom_proxy_group=` 整段写在 `.ini` 里(没有拆到 snippets),等同写法,只是没用 import 而已——这个属于你说的"已经很熟"的规则部分,不展开。

## 3. URL 参数里,和上面这些 key 同名/同功能的对照

如果哪天想临时覆盖某一个机场的规则(不想动 `.ini`),可以用这些 URL 参数,效果是**完全覆盖**同名的 `.ini` 设置(README 第 314/315/320 行):

| URL 参数 | 对应 `.ini` key | 说明 |
|---|---|---|
| `exclude=` | `exclude_remarks=` | 需要 URLEncode |
| `include=` | `include_remarks=` | 需要 URLEncode |
| `rename=` | `rename=` | 需要 URLEncode |
| `emoji=true/false` | 无直接对应,控制的是"要不要显示 emoji"这个开关,和 `add_emoji` 不是同一个语义 | 别和 `add_emoji` 搞混 |

我们现在的做法(所有机场统一走 `.ini`,`convert_url` 里只留 `udp`/`sort`/`scv`/`list` 这几个天然 per-request 的开关)是对的,不需要再加这些参数。

---
来源:`https://raw.githubusercontent.com/asdlokj1qpi233/subconverter/master/README-cn.md`,整理时间 2026-07-02。

# UA 改写反代(解决机场 UA 门槛 + 流量信息丢失问题)

## 要解决的问题

部分机场(目前已知:PandaCloud)的订阅接口会检查请求 UA,只有 Clash 系客户端(如 Shadowrocket)的 UA 才返回 200 + 完整内容 + `Subscription-Userinfo` 头,其他 UA(浏览器、curl 默认、`clash-verge` 等)一律 403。实测确认(2026-07-02):

```
无 UA / 浏览器 UA / clash-verge UA → 403
Shadowrocket/2166 CFNetwork/1410.0.3 Darwin/22.6.0 → 200，带 Subscription-Userinfo
```

而 subconverter 自身**没有**"给某个订阅源配置固定 UA"的机制——它转发的永远是发起 `/sub?...` 请求的调用方自己的 UA(见前面章节)。如果直接用真实机场链接构造 subconverter 请求,大概率因为 UA 不对被机场拒绝;就算凑巧 UA 对了,一旦这条订阅走"落盘成静态文件再转换"的老路径(submgr 日常那套),`Subscription-Userinfo` 头也会在落盘那一步彻底丢失,没有办法找补。

## 方案:透明转发反代,按域名/IP 白名单决定要不要改 UA

**部署位置**:`/volume1/Public/subconverter/airport_proxy/`(NAS,和 subconverter 同机)

```
airport_proxy/
├── ua_proxy.py      # 反代本体
└── domains.json     # 白名单配置(域名/IP → 固定UA)，每次请求都实时读取，不需要重启进程
```

**监听端口**:内网 `8388`(绑定 `0.0.0.0`),对外通过路由器端口转发映射到 `38388`(见下方"端口转发"一节)。上游固定指向本机 subconverter:`http://127.0.0.1:25500`。

**工作方式**:

1. 收到 `/sub?...&url=<真实机场链接>&...` 请求
2. 解析 `url=` 参数里的域名/IP,查 `domains.json`
3. 命中白名单 → 把请求转发给 subconverter 前,把 `User-Agent` 头强制改成配置里指定的值
4. 没命中 → **完全透明转发,不改任何东西**(已用逐字节 diff 验证和直连 subconverter 的结果完全一致)
5. subconverter 返回的响应(包括 `Subscription-Userinfo` 头)原样转发回调用方

**关键设计原则**(踩过坑,记录下来避免以后重复纠结):

- 白名单里**只存域名/IP + UA 这种稳定不变的映射,绝不存具体订阅链接/token**——机场订阅的 token 会经常轮换,链接本身不适合写进配置。域名/IP 通常不变,拿它做匹配键是安全的。
- 只用**一个端口**服务所有机场,靠 `url=` 里的域名/IP 做区分,不搞"一个机场一个端口"或者"一个机场一个专属别名路径"——后者会导致你必须记住/替换成非真实链接才能使用,增加心智负担且容易出错。
- 反代插在 **subconverter 和机场之间**(subconverter → 反代 → 机场),不是插在用户和 subconverter 之间。这样它只需要监听 `127.0.0.1`,不用对外暴露,也不用理解 subconverter 那一整套查询参数——早期一版做成了"用户→反代→subconverter"，会导致反代要透明代理 subconverter 的全部接口且必须对外暴露，后来放弃。**(2026-07-02 内部曾反复调整了两版，最终定型为这版最简单。)**

## `domains.json` 格式

```json
{
  "441133.xyz": {
    "user_agent": "Shadowrocket/2166 CFNetwork/1410.0.3 Darwin/22.6.0"
  },
  "43.139.168.201": {
    "user_agent": "Shadowrocket/2166 CFNetwork/1410.0.3 Darwin/22.6.0"
  }
}
```

同一个机场如果域名和 IP 两种链接形式都可能用到,两个都要加(PandaCloud 就是这么处理的,因为实际使用中两种形式都在用)。以后新机场需要 UA 改写,直接在这个文件里加一条,不用重启进程,下一次请求就生效。

## 怎么构造请求(和平时一模一样,只是换个端口)

`url=` 参数照常填**机场的真实订阅链接**,不用做任何替换/编码成别名。唯一的区别是把发送目标端口从 subconverter 直连端口(内网 25500/外网 35500)换成反代端口(内网 8388/外网 38388)。

```
# 需要 UA 改写的机场(命中白名单)：
http://gouki9999.ddnsfree.com:38388/sub?target=clash&url=<真实机场链接的URLEncode>&config=config%2FGOUKI_Local.ini&udp=true&sort=false&scv=false&list=false

# 不需要 UA 改写的机场：继续用老端口，或者换成新端口也完全没问题（透明转发，无副作用）
http://gouki9999.ddnsfree.com:35500/sub?target=clash&url=<真实机场链接的URLEncode>&config=config%2FGOUKI_Local.ini
```

## 启动 / 部署

```bash
nohup /bin/python3 /volume1/Public/subconverter/airport_proxy/ua_proxy.py > /dev/null 2>&1 &
```

已加入 NAS 开机自启动(用户自行配置)。脚本用自身所在目录定位 `domains.json`,不依赖启动时的工作目录,可以用绝对路径从任何地方启动。

默认监听 `8388`,如果要换端口/换上游地址,启动参数是 `ua_proxy.py <port> <upstream>`。

## 端口转发(路由器 192.168.1.1)

UCI 配置(`/etc/config/firewall`,已 `commit` 并由用户手动 `service firewall restart` 生效):

```
firewall.@redirect[75].name='DIYNAS_UAProxy'
firewall.@redirect[75].src='wan'
firewall.@redirect[75].src_dport='38388'
firewall.@redirect[75].dest_ip='192.168.1.8'
firewall.@redirect[75].dest_port='8388'
firewall.@redirect[75].proto='tcp'
```

改动前的完整备份:`/etc/config/firewall.bak-20260702-164910`。

## 已验证的结果(2026-07-02)

- PandaCloud(域名形式 `441133.xyz` 和 IP 形式 `43.139.168.201`)经过反代:200 + 完整规则生成的 clash yaml + `Subscription-Userinfo` 头完整透传
- 未命中白名单的机场(threebrother.top 实测)：反代结果与直连 subconverter **逐字节一致**，确认透明转发无副作用
- 外网通过 DDNS 域名 `gouki9999.ddnsfree.com:38388` 实测成功


# 按请求选择是否插入自建节点

## 配置方式

- pref.toml 的 common 段保存统一的 insert_url。
- enable_insert = false：默认所有转换请求都不插入。
- prepend_insert_url = false：启用时把自建节点放在原订阅节点后面。
- 需要插入节点的请求显式增加参数 insert=true。
- 不需要插入的请求不设置该参数，或明确设置 insert=false。

## 与外部 INI 的关系

config/GOUKI_Local2.ini 等外部配置只负责规则、分组、过滤、重命名和 emoji，不能自行声明 insert_url。因此实际控制点是转换请求参数，而不是 INI 文件内容。

建议约定：

- 使用 GOUKI_Local2.ini 的转换链接增加 insert=true。
- 使用 GOUKI_Local.ini、GOUKI_Online.ini 等其他配置的链接保持不变。
- append_sub_userinfo = true 保持开启；原机场订阅在插入节点之后处理，继续提供最终的流量和到期信息。

修改 pref.toml 后需要重启或重载 subconverter，确保新的 insert_url 被读取。
