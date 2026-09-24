# Aurora Location 无 Wi-Fi 定位问题: 第二意见请求

> 历史材料, 保留当时的实验条件与判断. 2026-09-24 已完成后续 Aurora VPN 联动, 用户确认双网络定位/代理和 Wi-Fi 到蜂窝会话保持. 当前路线见 [开发历程](JOURNEY.md), 本文的旧候选限制不作为当前开发边界.

整理日期: 2026-09-17. 供其他模型或技术审阅者独立分析, 不代表已有修复方案.

同日复核更正: `tunnel_create_rppairing` 内部已经包含动态 TLS 和 RSD 握手, 不能用旧外层 EOF 单独定位失败阶段. 随后已完成分层诊断和 Wi-Fi / 纯蜂窝 / 无镜像恢复 Wi-Fi 三组真机检查, 结果见 4.1. Roam-Control 实际连接仍使用固定 `10.7.0.1` 加发现的端口, 不能作为 AWDL/IPv6 新入口已经存在的依据.

## 1. 请解决这个问题

用户的目标是: iPhone 没有连接 Wi-Fi 时, 仍能使用系统级模拟定位, 同时保留 Shadowrocket 的外网代理能力.

**Wi-Fi 下直接使用 Shadowrocket 已经能够定位, 不需要 IKEv2. 不要推荐先连接 Wi-Fi 再启动 IKEv2, 也不要把 Wi-Fi 成功作为这个问题的解决方案.**

IKEv2 只是此前为解决蜂窝问题引入的实验手段, 不是必须保留的架构. 如果它无助于目标, 应明确建议停止投入.

请区分两种无 Wi-Fi 方案:

- 方案 A: 蜂窝保持开启, 能直接建立新的定位会话. 这是优先目标.
- 方案 B: 不需要 Wi-Fi, 但启动时短暂关闭蜂窝, 建立会话后恢复蜂窝和 Shadowrocket 外网. 这是需要明确说明限制的候选折中, 不能默认等同于 A.

仅换成 LocalDevVPN, 永久保留 Wi-Fi, 增加热点或常驻 USB 主机, 都改变了目标条件. 可以说明它们是对照或退路, 不要将其冒充原目标已经解决.

请先给可执行的技术判断, 不要直接生成一个大型新 VPN 工程. 对每个候选方案说明机制, 必要前提, 最小实验, 成功信号和失败后的停止条件. 如果没有足够证据支持可行性, 请直接指出.

## 2. 环境与证据时效

- 自有 iPhone 17 Pro Max, Developer Mode 和 Remote Pairing 已配置. 关键系统日志对应 iOS 27.0 / 24A437.
- 项目为 SwiftUI + idevice FFI, 调用 Apple 开发者服务的 LocationSimulation. 不是修改 Wi-Fi 定位查询响应的 MITM 方法.
- 公共仓库: [AuroraNest/Aurora-Location](https://github.com/AuroraNest/Aurora-Location).
- 本地基线提交: `f7956f1d20d0743c6c750d8d015f37b4cef4d061`, 其上新增未提交的阶段诊断改动. 本文包含关键逻辑, 不要求审阅者能访问本机或该提交.
- 历史结果来自 2026-09-11 至 09-17 的记录; 4.1 为本轮新做的真机验证. 本轮未操作 IKE 服务器或更改 Shadowrocket 配置.
- Wi-Fi, 蜂窝开关, iPhone Mirroring 是否运行会影响实验条件. 下文保留已知区别, 不把 `wifiAddress=false` 单独当作所有无线接口均已关闭的证明.

## 3. 当前实际连接方式

### 3.1 原本可工作的 Shadowrocket 路径

```text
Aurora Location 的 idevice 客户端
  -> 10.7.0.1:49152
  -> Shadowrocket 的本机 WireGuard peer
  -> UDP 127.0.0.1:51820, Aurora App 内的 emproxy
  -> 已认证 IP 报文的地址交换和回送
  -> Shadowrocket 收包并回注系统
  -> iPhone remotepairingdeviced
  -> RPPairing / 后续 TLS 隧道 / RSD / DVT LocationSimulation
```

本机 peer 仅接管 `10.7.0.1/32`, WireGuard 接口地址为 `10.7.0.10/24`. 普通外网仍由 Shadowrocket 的日常代理配置处理.

App 的连接入口逻辑如下, 为便于阅读省略了错误处理和 FFI 参数:

```swift
// 摘要, 不是建议修改.
let host = "10.7.0.1"
let port = 49152

if simulation == nil {
    // tunnel_create_rppairing(host, port, pairingRecord, ...)
    // remote_server_connect_rsd(...)
    // location_simulation_new(...)
}
// 后续 set 复用 simulation, clear 或 FFI 错误释放会话.
```

需要区分 Swift 的阶段标签与 FFI 内部协议阶段. 固定 idevice 版本 `e98264c4194e6980173c576ac79a58adce95492b` 的调用顺序是:

```text
tunnel_create_rppairing
  -> 初始 TCP connect
  -> rpc.connect, 包含 RPPairing 协议和认证
  -> finish_tunnel
       -> 请求动态 TCP listener
       -> 连接动态端口
       -> TLS-PSK 隧道和隧道参数
       -> Adapter 内层 TCP 连接 RSD 端口
       -> RsdHandshake::new
  -> 返回 adapter + handshake
```

Aurora 补丁给整个建立过程增加超时, 没有删除内部 RSD 握手. 因而外层 `tunnel.create-rppairing.failed` 不能单独区分上述子阶段; Swift 后面的 `rsd.connect` 也不是首次 RSD 握手. 已有 `connect:` 和 `TLS tunnel:` 错误前缀分别标记两个外层 TCP connect 的错误, 但未覆盖全部子阶段. [固定版本 FFI 源码](https://github.com/jkcoxson/idevice/blob/e98264c4194e6980173c576ac79a58adce95492b/ffi/src/tunnel_provider.rs)

- 首次连接前会启动本机 emproxy, 再探测同一固定地址和端口.
- 成功定位后, 定点保持约每 4 秒发送一次 set, 步行约每秒发送一次.
- App 没有在网络变化回调中主动销毁会话. 下一次指令失败时才清理, 停止维护并标记状态未知.
- 因此, "增加会话复用"不是缺失功能. "多加保活, 自动无限重连"也不能解决尚未建立连接的问题.
- 自建配对广播 `_remotepairing-pairable-host._tcp` 不等于发现系统已有的 `_remotepairing._tcp` 服务. 当前正式连接入口仍是固定 IPv4 + 49152.
- DVT set/clear 不等待这两个方法不会发送的回复. 方法返回成功仍需用新鲜定位样本验证实际设置或恢复, 不设计不存在的 clear ACK. clear 后释放会话, 再次 set 需要重新建连.

### 3.2 IKEv2 实验的实际范围

App 通过 `NEVPNManager` 管理原生 IKEv2 Personal VPN. 它没有自定义 Packet Tunnel extension. 未启用 On Demand 或 includeAllNetworks.

实验服务端只发布 `10.203.0.1/32`, 手机租约曾为 `10.203.0.2`. 服务端以 `10.203.0.1` 为源访问手机租约的 49152, 这是与原本机 WireGuard 路径分开的 TCP 对照.

合并后的 App 只是把 IKE 管理页和定位功能放在同一 App. IKE 页的"检测开发者连接"仍调用原来的 `checkConnection()`, 继续访问 `10.7.0.1:49152`.

**没有经 IKE 新建完整 RPPairing/RSD/DVT 的客户端实现, 也没有证据表明只把目标改成手机自身的 IKE 地址就能工作.** 同机自连可能有不同的路由与准入行为. 若建议新 IKE 通道, 必须画清连接发起端, 目的地址和后续动态端口路径.

## 4. 最有判别力的现场证据

| 编号 | 条件和观察 | 能证明什么 | 不能证明什么 |
| --- | --- | --- | --- |
| E1 | Shadowrocket, Wi-Fi 已连接, 曾完成真实 set, 换点, clear, 并有锁屏保持证据 | 现有配对, FFI, DVT 和本机 WG 方案在该条件可工作 | 无 Wi-Fi 可工作 |
| E2 | Shadowrocket, 无 Wi-Fi, 蜂窝开启, 预检查可 ready, 实际 `tunnel.create-rppairing` 很快 EOF; 聚合计数含解密和回送, 源端口 49152 的 RST, 未观察到 SYNACK | FFI 未成功返回完整 adapter + RSD handshake, 尚未执行 LocationSimulation 指令 | 仅凭外层 EOF 和聚合计数确定初始 TCP 未建立, RSD 未开始, 或 RST 的具体生成组件 |
| E3 | 同一蜂窝 + Shadowrocket 路径, 自有普通 TCP listener 的随机 nonce 挑战成功, 无镜像时也有成功记录 | 整条本机 WG 回环并非完全不可用 | 系统开发者 listener 也接受该路径 |
| E4 | LocalDevVPN, Wi-Fi 和蜂窝都关闭, 无镜像, 同一个 Aurora App/配对完成 RPPairing, RSD, DVT, set, clear | 不依赖 Wi-Fi, 完全离线建立真实定位会话至少曾经可行 | 蜂窝始终开启可直接建连, 或 Shadowrocket 能同时继续工作 |
| E5 | 用户反馈 LocalDevVPN 在临时关蜂窝启动后, 恢复蜂窝有初步保持效果 | 离线启动后恢复蜂窝值得作为机制对照 | 长期保持, 断线恢复, Shadowrocket 共存已验收 |
| E6 | Shadowrocket, Wi-Fi 和蜂窝都关闭, 原直连探测失败; 127.0.0.1:1082 HTTP 入口也失败, 某些回合 UDP=0; 镜像开关对照均有失败 | 在该组合下, 尚未复制出 LocalDevVPN 的离线本机入口 | 修改某个未经证实的开关一定可修复 |
| E7 | Wi-Fi 成功连接中, remotepairingdeviced 的 49152 连接参数和后续 TLS listener 都出现 `prohibited types: cellular loopback`; path 显示 utun / uses wifi | 系统服务确实带有接口排除参数 | 已完整定位纯蜂窝时的拒绝分支, 或所有 iOS/VPN 组合都不可能 |
| E8 | 给自有 listener 增加相同接口排除后, Wi-Fi 挑战成功, 切蜂窝后 listener 不接受连接并出现 RST 模式 | 接口排除足以在自有 listener 对照中复现类似差异 | 已修改, 绕过或精确还原了系统服务策略 |
| E9 | 无 Wi-Fi, 蜂窝开启, 无镜像, 自有 Bonjour/AWDL nonce 自回包成功; 对同一 peer 地址的 49152 探测仍 posix61 | 自有 P2P 自回包可以成功, 固定端口开发者探测仍失败 | 已发现并验证系统真实发布的开发者 endpoint, 或 AWDL 必然能承载它 |
| E10 | 单独 IKE, 蜂窝下服务端 ping 手机成功, 服务端访问手机租约 49152 返回 ECONNREFUSED(111) | 有可用 IPsec 数据路径, 但该 TCP 入口拒绝连接 | 完整开发者协议经 IKE 可工作 |
| E11 | 同一 IKE 会话, 开启 Shadowrocket 后 ping 和 TCP 变成超时, 只关 Shadowrocket 又恢复 ping; Wi-Fi 下也复现过 | 当前双 VPN 存在独立的数据面问题 | 解决双 VPN 冲突就能解决 E10 |

E7/E8 的关键采样有镜像活跃条件. 纯蜂窝失败瞬间的系统 Console 日志未完整取得, 不要把日志缺失解释成服务一定停止. E9 无镜像时的成功也不能排除先前 AWDL 状态的残留影响.

本机接收的 RST 源端口和 emproxy `reflected` 计数只是观测. `reflected` 表示 UDP 发送调用成功, 不保证内核最终回注成功; 当前计数也不足以逐流确认所有报文归属.

E2 的更正不撤销 E10: E10 是服务端针对确定手机租约和端口的独立 TCP connect 返回 ECONNREFUSED, 不依赖 Swift FFI 阶段标签. 有明确 connect 子阶段错误的历史回合, 也应与仅有外层 EOF 的回合分别分析.

### 4.1 2026-09-17 新增分层实测

本地诊断版本已增加同步 FFI 回调, 分开记录初始 TCP, RPPairing, listener 创建, 动态 TCP, TLS-PSK/CDTunnel, Adapter 内层 TCP 和首次 RSD handshake. 回调只含固定阶段编号和完成状态, 不记录报文或凭据. 错误保留原 code/sub_code, 并与当前 attempt ID 关联.

DEBUG 入口 `auroralocation://check-native` 只执行一次真实连接检查, 不并发运行额外 TCP 预检测, 不发送 set/clear. 必须用明确 Bundle ID 启动, 避免两个已安装 App 的同名 URL Scheme 歧义. 正常 UI 检测仍保留原预检测.

- 真机 iOS 27.0 / 24A437. 系统设置直接核对: Shadowrocket 已连接, Personal VPN 未连接.
- 16:56:11 Wi-Fi + Shadowrocket 基线: 初始 TCP 31ms, RPPairing 115ms, listener 270ms, 动态 TCP 272ms, TLS-PSK/CDTunnel 399ms, Adapter 433ms, RSD handshake 486ms, RemoteServer 867ms, DVT LocationSimulation 服务 1140ms 全部成功. 时间均为相对本轮开始的累计时间.
- 成功时中继快照: UDP142, authenticated141, reflected141, rejected0; SYNACK 来源49152为1, 来源49152的RST为0. 会话随后关闭. 本轮没有 set/clear.
- 17:04:36 纯蜂窝, 无镜像, USB 连接且 App 解锁前台: 用户确认 Wi-Fi 关闭, 蜂窝/SR 开启, IKE 关闭; 日志 `wifiAddress=false`, en0 无地址. 唯一 attempt 的初始 TCP 在累计68ms报告成功, RPPairing 在89ms以 EOF失败, 即该阶段约21ms. 原始 code1/sub0, 后续 listener/TLS/RSD/DVT 阶段未开始. 中继从零计数起, 仅 UDP3/auth2/reflected2/rejected0, SYN 来源其他端口1, RST 来源49152为1, SYNACK全为0. 检查162ms结束.
- 17:08:55 恢复 Wi-Fi, 继续无镜像, 同一 USB/App/配对/SR: `wifiAddress=true`, 全部阶段及 DVT 服务通过, 1076ms结束. 快照 UDP153/auth152/reflected152/rejected0, SYNACK49152=1, RST49152=0. 这排除了必须依赖镜像才能通过的解释.
- 17:08:55 同轮 Console 记录: remotepairingdeviced 的 C18 初始49152连接, L5动态TLS listener, C19动态TLS连接均含 `prohibited types: cellular loopback`. 这是无镜像恢复对照中的当前系统证据. Console 在纯蜂窝阶段断开, 未取得该次RST生成点的直接系统记录; 不能拿其他旧长连接的超时记录冒充本轮失败连接.
- 本地 `scripts/check.sh`, 最终 native 重建, App Debug build 和严格签名验证通过, 已覆盖安装原合并版. 构建工具实际为 Xcode 27.0 / iPhoneOS 27.0 SDK, Rust 1.93.1. 本轮只验证连接, 没有发送 set/clear, 没有修复蜂窝连接.

本轮直接确认: 客户端初始 TCP connect 返回成功后, RPPairing 未完成, 后续动态 listener/TLS/RSD/DVT 均未开始. 结合单次尝试的 SYN/RST 和零 SYNACK 计数, 高度支持反射后的开发者 TCP 入口未完成建连; 尚未取得完整逐流关联, 统计覆盖也有限, 不能把它写成直接确认的系统建连状态. 客户端 connect 成功与上述计数并存, 不足以证明 Shadowrocket 内部如何分段建连. EOF 也不能被解读为配对密钥验证失败. 历史 E3/E8 加本轮对照高度支持系统服务的路径准入限制; 具体 listener 不可用或内核输入过滤分支, 以及 RST 的精确生成点, 尚未直接取证.

## 5. 已经失败或不足以支持修复的方向

- 改 Tunnel IP, 飞行模式循环, 跳过预检测: 未解决初始真实连接失败. 绕过预检测后, native connect 仍会失败.
- 删配对, 重做签名, 增加超时: Wi-Fi 和 LocalDevVPN 对照已经证明配对和协议栈可工作, 目前没有证据应优先动这些部分.
- 给 App 客户端允许蜂窝, 或删掉自有测试 listener 的限制: 不能因此改变 remotepairingdeviced 的服务端参数. 正式连接客户端没有主动设置该 cellular 排除.
- 简单重复 AWDL 自回包或固定同一地址的 49152: 已做. 若建议再研究, 应证明是在发现不同的真实系统服务 endpoint, 而非重复 E9.
- Shadowrocket 的 includeAllNetworks 单项对照没有恢复离线入口, 已回退. 强制路由等开关排列不能当作有机制依据的新实验.
- IKE 内层服务端 /32 旁路, 外层服务器 /32 旁路, App 侧 `enforceRoutes=true`: 均未解决双 VPN 数据面冲突, 已撤回.
- IKE UDP4500 存在独立的传输问题, 但临时中转加高位端口已完成过 EAP/IKE/CHILD. 所以不应继续用认证, 分片或公网端口问题解释 E10/E11 的全部现象.
- 原始 TCP 在 Wi-Fi 单 IKE 条件下保持 180 秒, 不是纯蜂窝真实开发者会话保持. 旧 Shadowrocket 会话切蜂窝后换点也曾失败.
- "Wi-Fi 预建新 IKE 会话后再切蜂窝"目前既没有完整协议实测, 又要求先有 Wi-Fi. 它不能作为用户此次要求的无 Wi-Fi 启动方案.

## 6. 当前判断和真正需要第二意见的方向

子阶段诊断已完成. 当前最高置信的解释是: iOS 开发者服务排除 cellular/loopback 路径, Shadowrocket 的本机转发在纯蜂窝条件下不能向它提供可接受的接入路径. 配对, TLS, RSD 或 DVT 业务代码的修改没有针对这次实际断点. IKE 共存问题仍然独立, 继续修双 VPN 不会自动消除这个限制.

保留全部原条件时, 暂无已验证可用的配置修复. 继续工作需要一个能改变服务接入路径的新机制, 按以下顺序评估, 不先重写大型 VPN:

| 优先级 | 候选解决路线 | 必须先证明的条件 | 验收与停止条件 |
| --- | --- | --- | --- |
| 1 | H2: 使用同一已配对设备真实发布的非 cellular 开发者 endpoint, 如确有可用 P2P/scoped endpoint | 系统实际发布, 身份匹配, 地址/端口/interface区别于已失败的自有AWDL实验 | 先只发现, 有不同有效endpoint再试真实协议; 没有则停止, 不改固定IP碰运气 |
| 2 | H1/H3: Shadowrocket提供离线可用的本机开发者路径, 或公开可控的允许接口路径 | SR本身有实现或官方能力依据, 不依赖另一个VPN替换它; 恢复蜂窝后路径和会话仍有效 | 要同时验证冷启动/重新建连及外网; Aurora普通App不能凭自身NWParameters修改系统服务或SR私有实现 |
| 3 | 若接受改变条件, 使用LocalDevVPN离线启动后恢复蜂窝 | 允许短暂关蜂窝并不要求同时维持SR | 历史有完整离线成功和恢复蜂窝初步反馈, 长期保持需另验; 这不是当前全部条件下的修复 |

若前两条拿不出具体能力依据, 应明确停在技术前提限制, 而非继续改超时, 删除配对或扩展IKE. 保活只作用于已建立会话; clear/断线后需要重新建连, 因而离线引导方案必须说明这一点.

### H1. 提供无需物理上联网路的本机隧道, 离线启动后恢复蜂窝

这是有现场正向对照支持的机制: E4 证明 LocalDevVPN 能在完全离线时建立真实会话. 当前公开源码也直接从 packetFlow 读包, 交换 IPv4 地址并写回; Aurora + Shadowrocket 则额外依赖本机 WireGuard outer UDP 交付. 源码结构差异不能单独证明失败因果. [LocalDevVPN 实现](https://raw.githubusercontent.com/jkcoxson/LocalDevVPN/main/TunnelProv/PacketTunnelProvider.swift)

未解决的问题是: 如何在保留 Shadowrocket 的前提下得到这种离线启动能力, 并在恢复蜂窝后继续保有开发者会话和外网.

请回答: 是否存在有文档或源码依据的 Shadowrocket 能力, 可以不等待物理网络便处理本机 tunnel/UDP? 若需要改变 Shadowrocket 私有实现, Aurora 普通 App 能否触及它? 没有证据时, 不要编造一个开关或让用户重复离线切换.

停止条件: 不能提出与 E6 和已有失败配置不同的机制, 或只能靠另一个 enterprise VPN 替换 Shadowrocket, 则不能作为现有目标的可实施修复.

### H2. 寻找系统真实发布且允许当前接口使用的开发者 endpoint

当前 App 使用固定 IPv4/49152. 复核的 Roam-Control 源码中, `RemotePairingService` 只保留 `port`, `identifier`, `authTag`, 实际传给 native session 的 peer 仍是固定 `10.7.0.1`. 它支持发现端口和核验身份, 没有证明可直接使用 Bonjour 解析的 AWDL/IPv6 地址. 自有 AWDL listener 的地址也不自动等于系统服务的有效地址. [Roam-Control 连接实现](https://github.com/seanhowarthdev/Roam-Control/blob/main/RoamControl/Services/Tunnel/LocalDeviceSessionCoordinator.swift)

待验证假设: 无 Wi-Fi, 蜂窝开启时, 是否存在属于同一已配对设备的实际 Bonjour endpoint, 其地址族, 端口或 interface scope 与 E9 不同?

最小有价值的调查只应先确认系统真实发布的服务, 接口和身份匹配. 不扫描无关设备, 不把自建服务冒充系统服务, 不忽略 identifier/authTag 校验. 有有效 endpoint 后才考虑限时真实握手.

单轮发现预算为 15 秒, 到时取消. 先确认本地网络权限和服务类型声明有效; 权限/API 错误应记为实验无效, 不能记为没有 endpoint. 只保存候选编号, 端口/地址族/接口/scope, 本地身份匹配结果及新增/移除事件, 不导出完整 authTag 或配对材料. 分别记录 Wi-Fi 开关与是否关联 AP; 依赖开关开启但不关联 AP 的结果, 不等于完全关闭 Wi-Fi 也可用. 发现接口不能替代实际连接接口的验证. 本轮有限发现无候选仅说明这组条件下未发现, 不证明系统永远没有其他入口. 未来候选若成功, 还需补上脱离 USB 的最终验收.

停止条件: 没有符合身份的可用 endpoint, 发现结果没有区别于已失败的地址/端口/接口, 或其真实握手仍在相同子阶段被拒绝, 则停止该入口假设. 当前没有证据表明 Bonjour 发现本身能取消 cellular 限制. 若真有 IPv6 scoped endpoint, 后续动态 TLS 连接也必须保留正确地址与 scope, 不能只改初始连接.

### H3. 蜂窝保持开启时, 是否有合法可控的路径分类或新协议入口

E7/E8 支持"VPN 路径被服务认定为 cellular, 不满足准入参数"的解释, 但尚未证明全部拒绝机制. Apple 将 `prohibitedInterfaceTypes` 定义为连接, listener 和 browser 不使用的接口类型. [Apple 文档](https://developer.apple.com/documentation/network/nwparameters/prohibitedinterfacetypes)

Apple 公开 XNU 的 `necp_client.c` 在检查禁止接口类型时调用 `necp_ifnet_matches_type(..., TRUE)`, 会沿 `if_delegated.ifp` 检查下层接口, 并在匹配禁止类型时排除该候选接口. 因而仅看到 `utun` 并不表示它不受 cellular 类型限制. 这是公开实现提供的机制依据; 尚未取得本机 iOS 27 失败瞬间的对应分支证据, 不能据此声称已证明具体 RST 生成点. [XNU 接口匹配源码](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/necp_client.c)

最新第二意见提出的 `necp_socket_is_allowed_to_recv_on_interface` 也已独立复核: 满足 listener 标志, client UUID 等前置条件时, 它解析对应 client 参数, 用 `necp_ifnet_matches_parameters` 检查接收接口, 不匹配则返回不允许. 这说明公开实现中的接口策略也能作用于 listener 接收, 不仅是客户端选路; 不证明本机系统服务满足全部前置条件或本次 RST 来自该分支. [XNU listener 接收检查](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/necp_client.c#L3918-L3963)

请具体说明: 该排除如何作用于 utun 和其 underlying path? 有没有公开 API 或有版本证据的实现, 能在保持蜂窝外网的同时为系统服务提供允许的本机路径? 若主张更换 TCP/QUIC, IPv4/IPv6 或连接入口, 必须证明当前系统真实支持相应开发者协议.

只调整客户端 NWParameters, 网络 cost, 地址或路由, 不足以声称能覆盖另一个进程的接口策略. 也不能因暂未找到公开方案, 就断言所有软件方案永远不可能.

停止条件: 方案只依赖未经证实的私有能力, 或实际必须越狱, 外接设备, 替换 Shadowrocket, 应明确归入改变前提的路线, 不直接落地.

## 7. IKE 应该如何处置

本次问题的主线是 E10 对应的无 Wi-Fi 开发者入口, 不是让 Wi-Fi 用户使用双 VPN.

只有当候选方案说明 IKE 如何改变 E10 的限制, 才值得继续实现 IKE 定位通道. "再写个客户端试试"本身没有解释为什么原本拒绝的入口会接受连接.

即使解决 E11 的共存冲突, 也仍需单独解决 E10. Apple 允许 Personal VPN 和 enterprise VPN 共存, 同时明确冲突路由由 enterprise VPN 优先; 这不是本设备数据面或定位成功的承诺. [Apple VPN 配置模型](https://developer.apple.com/documentation/networkextension/netunnelprovidermanager)

## 8. 请返回这样的答案

1. 先判断现有证据最支持什么原因, 哪些仍无法区分. 请挑战本文可能错误的推断.
2. 给出最多 3 个按价值排序的候选方案. 每个方案写明: 机制和出处, 适用系统版本, 是否保留 Shadowrocket, 是否需要 Wi-Fi, 是否要短暂关蜂窝, 需要修改哪个组件.
3. 选择一个最小实验. 明确它与已失败实验的区别, 控制变量, 分层成功标准, 失败停止条件和回退. 不要以 VPN connected, ping, TCP ready 代替真实开发者握手或定位.
4. 分别评价冷启动, 重新连接, 换点, clear 和保持. 已有会话维持不等于无 Wi-Fi 新建会话.
5. 如果原条件下没有有依据的方案, 明确说暂无可确认修复, 并说明必须放宽哪个具体条件. 不要默认让用户接受 Wi-Fi, LocalDevVPN 替换或 USB 主机.

## 9. 补充参考和源码位置

- [Roam-Control Mobile-data flow](https://github.com/seanhowarthdev/Roam-Control/blob/main/Documentation/UserGuide.md#mobile-data-connection-flow): 当前说明要求临时关蜂窝启动 LocalDevVPN 会话, 再恢复蜂窝. 没有证明 Shadowrocket 组合可用.
- [Locus](https://github.com/ChrisMack32/Locus): 描述 LocalDevVPN 与 Wi-Fi 预建后蜂窝保持. 后者不满足本次无 Wi-Fi 启动要求.
- [Shadowrocket 官方公告](https://t.me/s/ShadowrocketNews?before=1598): 2.2.91 (3386) 声明支持 `10.7.0.1/32 loopback`, 没有在该条说明中承诺蜂窝/离线 DVT, 也没有披露可独立调用的包反射接口.
- [idevice 作者关于 iOS 26.4b1 的文章](https://jkcoxson.com/blog/i-made-apple-mad): 涉及 Lockdown 自连接和来源地址限制, 不能直接当作本机 iOS 27 / 49152 限制的实现证据.
- [LocationEngine.swift](https://github.com/AuroraNest/Aurora-Location/blob/f7956f1d20d0743c6c750d8d015f37b4cef4d061/AuroraLocation/Core/LocationEngine.swift): 会话复用/清理, 固定目标与协议建立.
- [AppState.swift](https://github.com/AuroraNest/Aurora-Location/blob/f7956f1d20d0743c6c750d8d015f37b4cef4d061/AuroraLocation/App/AppState.swift): 本机通道准备, 会话维护和失败停止.
- [NetworkStatus.swift](https://github.com/AuroraNest/Aurora-Location/blob/f7956f1d20d0743c6c750d8d015f37b4cef4d061/AuroraLocation/Core/NetworkStatus.swift): 固定 IP 与自有 listener 诊断. 测试 listener 的排除参数不是系统服务可被修改的证据.
- [PersonalVPNView.swift](https://github.com/AuroraNest/Aurora-Location/blob/f7956f1d20d0743c6c750d8d015f37b4cef4d061/AuroraLocation/Features/PersonalVPNView.swift): 检测按钮仍调用原 `state.checkConnection()`.

以上项目源码链接固定到本轮改动前的基线, 新增诊断尚未推送, 其行为和实测结果见 4.1. 本文已省略公网服务器地址, 设备 UDID, 账号, 密码, 密钥, PIN, 配对记录和实际位置; 保留的私网地址只用于解释协议路径. 本文仅生成在本机, 未发送给其他模型或维护者.
