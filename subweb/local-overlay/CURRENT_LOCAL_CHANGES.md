# 本地修改记录

本目录是 **cmliu/SUBWEB** 的静态构建产物（dist），不是 git 仓库，也不是 CareyWang/sub-web。

- 当前站点：`/volume1/web/subweb`
- 上游：https://github.com/cmliu/SUBWEB
- 上游最近提交：2026-03-20（截至 2026-09-11 仍是最新）
- 本机部署：2026-07-15
- 本地默认值调整：2026-07-27

不要把本目录当成源码去 `git pull`。上游若有更新，应另开源码目录、在源文件上保留本地改动、build 后再覆盖 dist。当前决定维持现站不变，本文件只作记录。

## 项目辨识

CareyWang/sub-web 是另一套 Vue 2.7 + Vite 项目。本机历史上用过它的衍生版，但当前 Web 站点已经换成 cmliu/SUBWEB。

| 路径 | 实际项目 | 状态 |
| --- | --- | --- |
| `/volume1/web/subweb` | cmliu/SUBWEB dist | 当前在用 |
| `/volume1/web/subwebold` | CareyWang 系 Vue 构建 | 2022 旧站 |
| `/volume1/docker/subweb` + `stilleshan/subweb` | CareyWang 系 Docker | 容器已停 |

Docker 旧配置：`/volume1/docker/subweb/config/config.js`

- apiUrl：`http://gouki9999.ddnsfree.com:35500`
- 规则：`config/GOUKI_Local.ini`、`config/GOUKI_Local2.ini`

## 需要保留的本地设置

相对 cmliu 上游默认值：

| 项 | 本地 | 上游默认 |
| --- | --- | --- |
| Emoji | 开 | 开 |
| UDP | 开 | 关 |
| 信息节点 | 开 | 开 |
| 跳过 TLS (`scv`) | 开 | 关 |
| 节点类型 | 关 | 开 |
| 选项顺序 | Emoji → UDP → 信息节点 → 跳过 TLS → 节点类型 | Emoji → 节点类型 → 信息节点 → 跳过 TLS → UDP |
| 转换后端 | 公网反代 / 公网直连 / 内网反代 / 内网直连 | CM / 肥羊等公网后端 |
| 外部规则 | `config/GOUKI_Local.ini`、`GOUKI_Local2.ini` | ACL4SSR / CM 远程规则 |
| 后端探测 | 直接列出本地后端，不探测公网 | 探测公网后端并自动选择 |

生成链接默认参数：

```text
emoji=true&udp=true&append_info=true&scv=true&append_type=false
```

本地后端：

- 公网反代：`http://gouki9999.ddnsfree.com:38388/sub?`
- 公网直连：`http://gouki9999.ddnsfree.com:35500/sub?`
- 内网反代：`http://192.168.191.8:8388/sub?`
- 内网直连：`http://192.168.191.8:25500/sub?`

改动落在构建产物：

- `index.html`：勾选状态和显示顺序
- `js/main.js`：默认值、backendConfig、externalConfig、initializeBackends

若以后从 git 重建，源码对应位置：

- `public/index.html`
- `src/index.js`
- `src/config.js`

注意：`scv=true` 会降低 TLS 证书校验强度，只应向可信机场订阅使用。

## 2026-09-11：项目归属确认

核对结果：当前站点不是 https://github.com/CareyWang/sub-web ，而是 https://github.com/cmliu/SUBWEB 的 dist。

决定：维持 cmliu/SUBWEB 现站不变，暂不建立源码目录和 rebase 流程。本文件补充项目归属、与上游差异、以及本机其它旧部署路径。

## 2026-07-27：高级选项默认值与顺序

目标：

1. Emoji：第 1 项，默认开启。
2. UDP：第 2 项，默认开启。
3. 信息节点：第 3 项，默认开启。
4. 节点类型：第 4 项，默认关闭。

实现：

- 调整桌面端与移动端选项的显示顺序。
- 同步修改 HTML 初始状态与 JavaScript 状态默认值。
- 生成链接时继续显式携带这些布尔参数。

预期参数：

```text
emoji=true&udp=true&append_info=true&append_type=false
```

修改前备份：

```text
backup-20260727-120800/
```

上游项目：

```text
https://github.com/cmliu/SUBWEB
```

## 2026-07-27：默认跳过 TLS 证书验证

背景：

- DogCloud 原生节点要求 `skip-cert-verify: true`。
- SubWeb 原默认值会生成 `scv=false`，覆盖机场原始配置并造成 HY2/AnyTLS TLS 握手失败。

调整后的前五项：

1. Emoji：开启。
2. UDP：开启。
3. 信息节点：开启。
4. 跳过 TLS：开启。
5. 节点类型：关闭。

生成链接默认包含：

```text
scv=true
```

修改前备份：

```text
backup-20260727-145828-scv-default/
```

注意：`scv=true` 会降低 TLS 节点的证书校验强度。功能兼容风险较低，但只应向可信机场订阅使用。

## 2026-10-06：静态资源本地化

<!-- LOCAL_ASSET_OVERLAY -->

为避免 unpkg.com、Google Fonts 和 cdnjs 网络缓慢阻塞首屏，已将以下资源固定并本地托管：

- jQuery 3.6.4
- Font Awesome Free 6.4.0（CSS、WOFF2、TTF）
- Inter v20（本地 WOFF2）

线上资源目录：/volume1/web/subweb/vendor

独立保留层：/volume1/docker/subweb-local-overlay

独立保留层位于部署目录之外，包含资源文件、当前配置记录快照、升级说明和自动应用程序。以后拉取上游、重新构建并覆盖 dist 后，必须运行：

    python3 /volume1/docker/subweb-local-overlay/apply.py /volume1/web/subweb

程序可以重复运行；会复制本地资源、替换公网 CDN 引用，并在修改前备份 index.html。如果新版上游改变相关 HTML 结构，程序会明确报错并停止，避免悄悄恢复公网依赖。
