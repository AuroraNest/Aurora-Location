# Shadowrocket 单 VPN 验证

用户要求: Shadowrocket 持续承担日常代理, 不安装或切换到另一款 VPN. 记录日期: 2026-09-09.

## 已确认

- 真机验证版本为 Shadowrocket 2.2.92 (3445), 使用既有日常代理配置.
- 系统 Developer Mode 的配对列表包含 Aurora Location, App 也保存了本机配对凭据.
- [Shadowrocket 官方公告](https://t.me/s/ShadowrocketNews?before=1600) 记录 2.2.91 (3386) 新增 `10.7.0.1/32 loopback`.
- 未修改配置时, 开启 Shadowrocket 后 TCP 探测变为可达, 但 Remote Pairing 握手仍失败. TCP ready 不等同于设备服务响应.
- [SideStore #1486](https://github.com/SideStore/SideStore/issues/1486) 是用户报告, 提到该地址与 EMProxy, 同时报告 nightly 回归. 它不构成 Aurora Location 的兼容性证明.

## 正在实现与验证

App 内使用 `boringtun` 的 BSD-3-Clause 实现承载最小 IPv4 回送, 不复制或链接 AGPL EMProxy 源码. 不新增 Network Extension 或系统 VPN 配置.

- 中继仅绑定本机 `127.0.0.1:51820`. set 成功后与 DVT 会话一起保留, clear 或失败后停止并等待 worker 退出; 无模拟会话的连接检测结束后停止.
- server/client Curve25519 密钥在设备生成, 保存在 Complete Protection 且排除备份的目录. 读取损坏时不自动重置已有密钥.
- 用户主动复制的配置仅包含 client private key 和 server public key, 不包含 server private key 或 Apple pairing. 使用 localOnly 剪贴板, 2 分钟过期, 仅供导入自己的小火箭, 不进入远程订阅/Git/诊断.
- Native 仅接受约定 IPv4 地址和 TCP 动态端口范围 49152...65535, 覆盖初始 Remote Pairing 及协商后的端口. 拒绝分片、无效包、UDP 和低端口; 不识别允许范围内的具体服务.
- 诊断只包含 UDP 接收、解密、回送和拒绝计数. 不能将计数或 WireGuard 握手当成定位成功.

普通 WireGuard 节点是否可将响应注入 iOS TUN 尚待验证. 不默认改 `skip-proxy`、`tun-excluded-routes` 或 `compatibility-mode`, 不覆盖现有订阅. 在匹配配置经真机验证之前, 导出配置只代表候选连接参数.

## 19:07 真机结果

用户已保存并启用 `Aurora-Local.module`, 引用导入节点的实际名称 `127.0.0.1:51820`, 并重新连接 Shadowrocket 后检测. App 显示配对已保存、Wi-Fi 接口有地址、TCP 端口可达, 但开发者握手失败; UDP/解密/回送/拒绝均为 0. 本次尝试没有到达 App 的 UDP 中继, 尚不能判断是规则未匹配、被绕过还是节点连接没有发出. 不要求用户重复配对. 下一项证据是 Shadowrocket 对 `10.7.0.1:49152` 的实际连接/规则记录.

## 验收目标

19:22 更新: 用户将本机节点备注设为 `AuroraLocal` 并修改模块引用后, 日志实际策略从日常代理变为 `AuroraLocal`. App 收到 UDP 26、解密 25、回送 20、拒绝 5; 日志新增动态端口 54673. 已确认 WireGuard 数据面, 原生过滤器仅允许 49152 的限制会拒绝动态端口, 已添加回归检查并修正.

后续结果: 用户已反馈修复后单 VPN 定位成功. 以下完整验收矩阵仍未全部完成; 历史握手失败记录用于解释排障过程, 不是当前必然失败的结论.

- [ ] 仅 Shadowrocket 系统 VPN 连接, 正常网页仍可访问.
- [ ] 本机中继计数确认数据面, Remote Pairing 和 DVT 检测成功.
- [ ] set 后 Apple Maps 显示目标位置.
- [ ] 换点有效, clear 恢复真实位置.
- [ ] App 退出/重启后 clear 有效, 中继不残留或占用后台.
- [ ] 失败保留配对/密钥/代理配置, UI 能重试.
