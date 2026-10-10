# subconverter UA 改写反代

源码来自 NAS 实际部署文件 `/volume1/Public/subconverter/airport_proxy/ua_proxy.py`。只使用 Python 标准库；`domains.json` 从脚本自身目录读取，每请求重新读取。

客户端向反代发送原本的 subconverter 转换请求。程序检查 `url=` 参数内的机场 hostname，命中域名配置后改写 User-Agent，再转发到本机 subconverter。未命中时保留客户端 UA；返回结果及非过滤响应头传回客户端，包含 `Subscription-Userinfo`。

```sh
nohup /bin/python3 /volume1/Public/subconverter/airport_proxy/ua_proxy.py 8388 > /volume1/Public/subconverter/airport_proxy/ua_proxy.log 2>&1 &
```

内网 8388，路由器外网 38388 映射到 `192.168.1.8:8388`；原 subconverter 内网 25500，外网 35500。转换链接其余参数不变，仅按需选择端口。

配置只保存域名/IP 与 UA，不存订阅 token 或固定的完整订阅地址。Shadowrocket UA 为 `Shadowrocket/2166 CFNetwork/1410.0.3 Darwin/22.6.0`。

本次仅将部署中的原代码纳入 Git，没有改变反代行为。当前实现使用 hostname 子串匹配，且合并多个 URL 时只解析第一个 hostname；转发到 subconverter 的 UA 是请求级别。此能力不等于逐个合并来源指定不同 UA。

实时机场 URL 的流量头可由 subconverter 转发，需启用 `append_info`。静态原始文件路径不包含机场 HTTP 响应头，不能由这个反代恢复流量信息。
