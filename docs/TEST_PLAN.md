# 测试与真机验收

## 2026-09-24 Aurora VPN 联动验收更新

- 用户确认 Wi-Fi 和蜂窝下修改定位均成功, Aurora VPN 在两种网络下正常使用.
- 用户明确确认 Wi-Fi 已建立的定位会话切换到蜂窝后能够保留. 此项记为用户实测通过, 未补采切换瞬间日志.
- 工具侧验证: Wi-Fi 受控请求在 VPN 内显示实际节点 chain/字节; Location 外部模式 URL 往返及真实 DVT 检测成功, 检测结束后 VPN 保持.
- set/换点/clear 由用户操作. clear 后持续传输、节点故障恢复、15 分钟锁屏和长期内存表现未逐项确认, 继续独立验收.
- 下文保留历史测试记录; 当前实现和经验见 [JOURNEY.md](JOURNEY.md).

## 2026-09-22 自动蜂窝回调

- 用户真机点击后停在准备网络. 首版日志显示回调被拒绝; 兼容系统 errorDomain 后, 连续 4 次均确认 prepare 返回 errorCode=4, 没有进入定位阶段.
- v2 使用普通 run-shortcut URL 传入阶段和随机令牌绑定的完成 URL, 由助手执行对应动作后主动打开该 URL. 不将错误码 4 或等待时长当作成功.
- sh scripts/check.sh 已通过 v2 协议检查, 包括禁止 x-callback 参数, 回调过期和重放拒绝, 坐标冻结, 取消恢复以及重启不重放定位.
- 待真机验收: 添加 Aurora 蜂窝助手 2, 点击一次蜂窝修改, 确认 prepare/offline/restore 回调依次成功, DVT set 完成且蜂窝恢复. 构建和签名不代表此验收通过.

## 2026-09-21 离线启动系统日志

- 用户导出的设备日志确认, 23:13:11、23:14:36、23:17:04 的 AL 本机 VPN 请求在 `NESMVPNSessionStatePreparingNetwork` 返回 `No network available`, 随即回到 disconnected, 没有进入扩展启动阶段. App 约 10 秒后读到 `NEVPNConnectionErrorDomain code=2`. 不是配对验证或定位指令失败.
- 同日蜂窝开启时 AL 扩展可启动, 但开发者 TCP 预检返回 `posix=61`. 不能通过增加 VPN 等待时间或调整包反射逻辑修复启动前的系统拒绝.
- 当前设备上的 LocalDevVPN 也无法在 Wi-Fi、蜂窝均关闭时新建 VPN. 用户确认先开启蜂窝连接 LocalDevVPN, 再关闭蜂窝, 10 秒后 VPN 仍显示已连接. 这只证明连接状态保留.
- 随后的只握手检测 run `C1DB3BF8-057B-482B-A0CF-36E44CBF6793` 在 `pairing-tcp` 返回网络不可达, code16/sub0, 没有进入 RPPairing 或发送 set/clear. 用户报告 LocalDevVPN 地址为 Tunnel `10.7.0.2/30`, Device `10.7.0.1/32`. USB 保持连接, 不等同于脱线验收.
- 原始系统日志由用户保留在本机临时目录, 未加入仓库. 后续须以 AL 自有通道的分步启动及真实开发者握手为依据, 不把历史 LocalDevVPN 成功记录当成当前离线冷启动成功.
- 用户在系统设置先用蜂窝连接 AL 自有 VPN, 再关闭蜂窝并点击蜂窝修改, 确认定位成功. run `2159B60F-4C55-4CE3-814A-0962A12A7F0E` 的预检 `path=satisfied, interfaces=other`, 7 个隧道阶段及 DVT 全部通过, 242ms 时 set 成功, 之后约每 4 秒重发成功. 当前证据包含 USB, 没有代替脱线与长期保持验收.
- App 调整为先准备本机 VPN, 用户关闭蜂窝后再继续定位. 准备及取消不调用开发者服务或 set/clear, 切后台保留已准备通道, 原默认路径仍先确认本机 VPN 关闭. 不改隧道地址、路由、签名权限或配对.
- `sh scripts/check.sh` 全部通过, 最终取消提示修订的 AppState 检查再次通过, Debug build、strict codesign、覆盖安装和启动通过. 用户确认新版两步 UI 定位成功. `E62B3C12-8781-4D11-B6B8-2B49A357B151` 在159ms完成 VPN 准备且没有开发者指令; 约8秒后用户继续, `2F11CAF9-A9E0-4CDD-AFAF-028895C28C67` 复用 connected 通道, 预检 interfaces=other, 257ms set成功, 后续至少约30秒保持重发成功. USB仍连接; 未验收脱线长期保持. 未提交推送.

## 2026-09-17 用户离线启动失败后的诊断修订

- 用户截图显示配置已经创建, 蜂窝关闭且 Wi-Fi 未连接时本机 VPN 启动失败. USB 只读取得旧版诊断: run `0B846867-30F4-457F-BEED-4C1759A55452` 约 10.14 秒超时, 未进入开发者握手或发送定位指令. 同组 run `544141C4-4EC8-4714-9EBD-9AD0D1ABAED7` 曾在蜂窝路径下启动 VPN, 随后开发者预检失败. 不能将扩展无法运行或未授权认定为根因.
- 旧版把系统错误统一替换成授权提示. 本次保留配置/启动阶段, 状态变化, 脱敏系统 domain/code, 并在停止清理前获取最近断开错误. 弹窗明确尚未发送定位指令. 不改变通道配置或 Wi-Fi 流程.
- Debug build 和严格签名校验通过. `sh scripts/check.sh` 在允许本机 listener 的权限下通过, 新断言检查错误细节显示且不误报授权. 沙箱内首次网络检查因监听权限失败, 不是回归失败.
- 无 LocalTunnel 匹配崩溃文件. 历史 VPN 系统日志导出需要本机 sudo 认证, 已请用户执行只读命令. 离线启动根因仍待该证据; 未代用户操作网络或真机定位测试.

## 2026-09-17 17:57-17:59 AL 户外本机通道

- 用户调整目标: Wi-Fi 下保留 Shadowrocket + AL 原流程; 户外允许手动关闭小火箭和蜂窝, AL 自带本机 VPN 完成定位后再由用户恢复蜂窝. 不做自动系统开关或快捷指令, UI 只增加蜂窝修改按钮, 操作弹窗和活动会话提示.
- 新增 LocalTunnel Packet Tunnel extension 和 LocalDeviceTunnel manager. 仅接管固定10.7.0.1/32开发者peer, 校验IPv4长度/协议/地址后交换源目的地址回注; 无外网服务或DNS接管. 主App保留原Bundle ID, 增加Packet Tunnel entitlement并嵌入已签名扩展.
- AppState区分默认和户外通道. 活动户外会话换点复用, 清除或失败停止本机通道; 已有默认会话禁止直接切换到户外. 默认新建会话前确认本App通道已停止, 不创建或改动小火箭配置. 尚未创建本机VPN配置视为已停止, 防止首次安装影响原流程.
- `sh scripts/check.sh`通过, 包含原功能回归, 户外路径选择/换点/清除/失败/切换, 固定IPv4双向反射和无效包拒绝. 最终Debug签名build及主包/appex严格codesign通过, 已覆盖安装至原物理iPhone.
- 17:57:33安装后Wi-Fi真实check-native run `29055E50-0262-4D35-B2E4-1CA9CB51907F`: 全部FFI阶段及DVT服务通过, 1140ms结束. UDP144/auth143/reflected143/rejected0, SYNACK49152=1/RST49152=0. 未发送set/clear.
- 17:59镜像UI核对: 原开启模拟定位按钮保留, 新蜂窝修改位于其下方, 操作弹窗完整显示. 在当前Wi-Fi条件确认户外入口, 明确提示先断开Wi-Fi并关闭小火箭/蜂窝, 未启动本机VPN或设置定位.
- 用户随后明确由自己负责真机测试, 已停止手机操作. 待用户验收: 首次系统VPN授权, 无Wi-Fi且蜂窝关闭时本机通道/完整握手/set, 实际换点/clear, 恢复蜂窝后的新鲜定位与普通外网, 脱USB及后台保持. 构建/安装/Wi-Fi回归不等于这些项通过. 配对/Places/Keychain保留, 未提交推送.

## 2026-09-17 16:56-17:08 native 分层诊断与蜂窝对照

- 固定 idevice commit 上新增同步阶段回调, 保留原 API, 超时, error code/sub_code 和资源所有权. 分开记录初始 TCP, RPPairing, listener 创建, 动态 TCP, TLS-PSK/CDTunnel, Adapter TCP 和首次 RSD handshake. 日志只含固定阶段和当前 attempt, 不包含原始 peer 数据.
- 新增 DEBUG `check-native` URL 入口, 明确指定合并 App Bundle ID 启动. 仅执行一次真实连接并关闭会话, 不额外探测 TCP, 不发送 set/clear. 正常 UI 检测仍保留预检测.
- `sh scripts/check.sh` 通过, 新检查覆盖阶段 2/7 的 EOF 归因, 原始错误脱敏, 失败后恢复, 诊断入口不发送定位命令且跳过额外探测. 最终 native 重建, Debug Xcode build, `codesign --verify --deep --strict` 和 `git diff --check` 通过. 沿用原 Bundle ID 覆盖安装, 未提交推送.
- 系统 VPN 页面直接确认 Shadowrocket 已连接, Personal VPN 未连接. 16:56:11 的 Wi-Fi 基线 run `C1590AAD-FA21-4473-964F-A5E064EA5BF9`: 全部 7 个内部阶段通过, RemoteServer 和 DVT LocationSimulation 服务通过, 约 1.15 秒后检查结束. 成功快照 UDP142/auth141/reflected141/rejected0, SYNACK49152=1, RST49152=0. 未发送 set/clear.
- 17:04:36 纯蜂窝, 无镜像, USB连接且App解锁前台, run `2325CCC9-B234-4A7A-A2E7-FBCE176BAC62`: 用户确认SR开/IKE关, 日志wifiAddress=false. 初始TCP累计68ms报告成功, RPPairing累计89ms以EOF失败(code1/sub0), 后续listener/TLS/RSD/DVT均未开始. 零起始计数下UDP3/auth2/reflected2/rejected0, SYNother=1/RST49152=1/SYNACK=0, 162ms结束. 客户端connect成功不能证明系统开发者TCP入口已接受连接.
- 17:08:55 只恢复Wi-Fi, 继续无镜像和同一USB/App/配对/SR, run `831B2C3C-FE58-4FF9-A42D-FA72953A721D`: 全部握手阶段和DVT服务通过, 1076ms结束, UDP153/auth152/reflected152/rejected0/SYNACK49152=1/RST49152=0. Console当前同轮C18(49152), L5(TLS listener), C19(TLS连接)均含 `prohibited types: cellular loopback`.
- 根因高度指向系统开发者服务的网络路径准入限制. 直接确认的是RPPairing未完成且后续阶段未开始; 反射后开发者TCP入口未完成建连是单次计数支持的高置信推断, 尚缺完整逐流关联及具体listener/内核拒收分支证据. Console在纯蜂窝时断开, 不用无关旧连接超时补齐缺失证据. 已停止临时采集, Wi-Fi恢复, IKE未启动, 配对/SR配置未改, 全程无set/clear. 原条件下尚无已验证配置修复, 下一步只接受能改变服务接入路径的具体新机制.
- 详细假设, 已失败路线和外部复核材料见 [CELLULAR_REVIEW_BRIEF.md](CELLULAR_REVIEW_BRIEF.md).

## 2026-09-17 15:24-15:28 定位与 IKEv2 App 合并

- 用户要求先合并两个 App. 原主 App 标识再次被 Apple 返回不可注册, 通配符 profile 缺少 Personal VPN 权限. 改为沿用已有 IKEv2Lab 标识升级完整 App, 保留原 VPN 配置和 Keychain 身份, 显示名称为 Aurora Location.
- 删除 PERSONAL_VPN_LAB 入口分支及独立实验包构建脚本. 定点/步行标签不变, 设置内保留独立 IKEv2 页面, 可在同一 App 检测开发者连接.
- 原主 App 的 Pairing、Places、Tunnel 文件经本机私有临时目录迁移, 回读三份文件与原文件逐字节一致. 只迁移后台监测和诊断开关这两个偏好, 不输出配对/密钥内容, 不导出或重填 VPN 密码. 原主 App 保留回退, 未卸载.
- 签名 Debug build、codesign --verify --deep --strict、原实验包覆盖安装通过. sh scripts/check.sh 初次被沙箱禁止回环 listener, 在允许本地网络环境重跑后全部通过. git diff --check 通过.
- 真机合并版: 配对已保存, Wi-Fi 开发者检测成功并关闭会话; 本机中继 UDP142/解密141/回送141/拒绝0. IKEv2 页保留原服务器及已保存密码引用, 状态已断开, 内嵌开发者检测入口可见. 模拟步行独立标签正常打开.
- 自动审批要求对合并版始终定位单独授权. 用户明确允许后完成系统授权, 页面显示已获权限. 未发送 set/clear, 本轮未重新连接 IKEv2 或验证蜂窝; 合并不代表蜂窝链路问题解决.
- 原主 App 与合并版暂时都注册 auroralocation, 实际定位验收前请直接使用当前打开的合并版, 不依赖 URL 打开目标. 用户验收后再移除旧 App. 未提交推送.

## 2026-09-17 14:35-15:00 新入口与剩余阻塞

- 用户明确授权自主执行 txy 中转实验. 首轮 Mac 探针两端口超时, txy 抓包和规则计数均为零. 腾讯云控制台确认该实例原有 16 条规则未放行 UDP500/4500. 仅新增带 `aurora-ike-trial-20260917` 标记的双端口规则后, Mac 绑定 en0 的初始协商 500/4500 均收到匹配响应, 171/230ms.
- 中转路径: 手机 -> txy UDP500/4500 -> bwg UDP500/14500 -> 既有 strongSwan4500. bwg 高位映射仅允许 txy /32 来源, 两端均为有时限的运行时规则, 不复制证书、密码或配对文件.
- 实验 App 仅将 serverAddress 改为 txy IPv4, 保留 Remote ID 和已存凭据. SR 暂停后, 手机显示已连接, bwg 记录 EAP_MSCHAPV2 成功及 IKE_SA70/CHILD10. Wi-Fi 下 ping2/2, 服务器绑定10.203.0.1到手机10.203.0.2:49152的无数据 TCP connect 返回0.
- 执行关闭 Wi-Fi 后, 同一 IKE70 经 MOBIKE 更新端点, ping2/2仍成功, 49152返回ECONNREFUSED111. 镜像随之断开, 本轮未取得切换后的独立5G截图或手机日志. 用户恢复Wi-Fi后, 同一IKE无需重建, ping2/2和49152连接立即恢复. 这是网络条件相关的端口接入差异, 尚不能单凭TCP结果区分监听取消与系统拒收.
- Wi-Fi下恢复SR Aurora-Auto后, IKE仍ESTABLISHED, ping2/2丢失、49152超时; 只停SR即恢复ping. 临时TUN旁路10.203.0.1/32, 保存及重连均无效, 已删除. 实验App增加 `enforceRoutes=true` 后新IKE74/CHILD11单独可通、开启SR仍失败; 再单独旁路外层txy/32并重连也无效. 这些结果不等于纯蜂窝完整定位成功.
- 两条SR旁路均恢复为空, `enforceRoutes` 已从源码撤回. 恢复实验包签名构建及系统环境 `codesign --verify --deep --strict` 通过, 覆盖安装后写回原bwg入口和默认参数, IKE已断开. txy带标记iptables规则、bwg14500映射均已清理; 云防火墙已恢复原16条规则, 服务端失联IKE74已精确终止, nginx/strongSwan/xray/caddy保持active. 无set/clear或凭据变更.
- 15:00最终恢复验证: 原Aurora Location在Wi-Fi + SR下重新检测, 设置页明确显示开发者服务检测成功、会话已关闭; 中继UDP149/解密148/回送148/拒绝0/TCP复位1/49152发出0. 配对仍有效. 这只验证连接, 不外推为本轮位置或后台验收.
- 后续应聚焦两个独立问题: SR开启时IPsec数据包在手机上的处理, 以及切换Wi-Fi后既有加密开发者会话能否保留. 原始TCP曾在Wi-Fi单IKE下保持180秒, 没有完成该连接的网络切换对照, 不能写成蜂窝保持通过. 不重复无新机制的分片、DIRECT/PROXY、上述旁路或重新配对.

## 2026-09-17 独立出口和高位端口对照

- NY mini直连与经bwg跳板的SSH均超时, rly SSH关闭连接, 没有修改两台主机. 从既有txy执行同一无凭据IKE_SA_INIT探针, 500收到457字节/137ms匹配回应, 4500两次4秒超时; bwg确认均收到并回应. 这排除了仅手机或仅当前Wi-Fi设备的问题, 不能定位具体丢包网络节点.
- bwg临时添加仅允许txy来源、120秒自动失效的UDP14500到既有4500的运行时映射. txy的14500初始协商收到461字节/136ms匹配回应. 测试后明确删除映射成功, 无持久防火墙修改. 换端口可以通过当前路径, 但不代表完成EAP或VPN认证.
- 当时准备txy临时UDP500/4500入口转发到bwg500/14500, 不复制凭据或证书. 入口脚本只作用于本机目的流量和固定bwg目标, 定时退出清理; mock验证正常到期及中途安装失败都会执行带唯一标记规则的清理. 用户随后已授权并执行, 结果及回退见上方14:35-15:00记录.

## 2026-09-17 13:49 手机 PROXY 规则对照未通过

- 用户授权交回手机. 将唯一 `67.230.174.234/32` 规则从 DIRECT 临时改为 PROXY, 保留 no-resolve; Aurora-Auto/配置模式不变. 首次及停止IKE、重连SR后再次尝试均未完成EAP认证. 服务端出现代理来源的初始请求, 但认证请求仍出现直连路径, 无ESTABLISHED会话.
- 真机 Console 13:48:29 的 NEIKEv2Provider C7明确记录4500路径为 `interface: en0[802.11], scoped`, 输出协议UDP-NAT-T. 13:48:33内核汇总: 同一源端口到500收521/发432字节, 到4500收0/发1116字节(0/3包). 说明本次4500实际仍走限定的Wi-Fi接口, 不能把Mac普通socket经代理成功外推到iOS系统IKE.
- 已停止IKE与Console采集, 精确规则已恢复DIRECT/no-resolve, 小火箭保持Aurora-Auto. 未改变Wi-Fi/蜂窝、账号、配对或定位. 本轮无App代码修改. 下一步应优先验证其他直连出口或不同服务器路径, 而非继续重复该PROXY规则实验; 蜂窝开发者入口限制仍未解决.

## 2026-09-17 UDP4500 路径对照, 未操作手机

- 用户提供 11:03-11:04 真机 RVI 文本: UDP500 请求432/响应521字节, 切换4500后只看到372字节请求重传, 没有入站回应. 同轮 bwg eth0 抓包显示收到请求并发送1240/1240/1240/120字节响应. 两端结合定位为该路径响应未到达手机RVI观察点, 尚不能指定是哪一跳丢弃.
- bwg IPv4出口未发现阻断规则, rp_filter=0, 无eth0全局IPv6地址及IPv6默认路由. 未修改防火墙或代理服务.
- Mac 最小无凭据 IKE_SA_INIT 探针: socket绑定en0, UDP500收到457字节匹配回应, UDP4500两次4秒超时; strongSwan确认收到并回应两端口. 沿已有系统路由(utun9)发送时, UDP500收到457字节/1032ms, UDP4500收到461字节/668ms, SPI及源端点匹配. 再次绑定en0复核, 500成功/4500两次超时. 这是初始协商, 不是EAP认证或VPN成功.
- 服务端脱敏来源分组确认: 直连与系统路由来源不同, 后者来源为bwg自身, 与代理转发路径一致. 支持下一步临时停用手机精确DIRECT规则做传输路径对照, 不能推断小火箭与IKE的数据面或开发者入口已修复.
- 未操作手机, 等待用户交回设备. 临时可复现探针保留在Mac `/tmp/aurora-ike-init-probe.py`, 只发初始协商, 无凭据/配对/业务数据. 服务器tcpdump已安装但无常驻采集, RVI已关闭.

## 2026-09-17 10:46 Wi-Fi 基线与 IKE 认证响应故障

- Wi-Fi 已连接且 Shadowrocket 关闭时, IKEv2 仍停在 IKE_AUTH. 服务端反复重传约 3600 字节认证响应, 未完成 EAP. 真机 Console 10:44:45 明确记录 `Failed to receive IKE Auth packet (connect)` 和 `NEIKEv2ErrorDomain Code=3 PeerDidNotRespond`. 该结果不等同于证书校验失败或开发者端口失败.
- 按 strongSwan 官方 `charon.fragment_size` 参数做一次 576 字节对照, 日志确认从 4 片变为 8 片, 仍重传失败. 已删除独立临时分片配置并重载, 恢复原值. 未更改证书校验、代理服务、节点或路由.
- 已恢复 Wi-Fi + Shadowrocket Aurora-Auto/配置模式. Aurora Location 点击重新检测成功, 页面显示开发者服务检测成功且会话已关闭; 中继 UDP139/解密138/回送138/拒绝0, TCP复位2且49152发出0. 未执行 set/clear 定位.
- 实验 IKEv2 已断开, 服务端无活动会话, Console 已停止采集. Wi-Fi IKEv2 尚未建立, 因此本轮未完成 VPN 地址49152的 Wi-Fi/蜂窝对照. 下一步先定位 IKE_AUTH 回程丢失或客户端处理原因, 不新增未经验证的 App 转发代码.

## 2026-09-16 Personal VPN 共存实验

- 新增原生 IKEv2 管理页, 使用 EAP 用户名/密码和 Keychain persistent reference, 不添加 Packet Tunnel extension, 不自动连接.
- `sh scripts/check.sh` 通过, 包括 URL/存储/会话/真实本机监听/步行回归及新增 IKEv2 地址与必填身份检查. 这些检查不验证系统 VPN 的凭据消费或真实握手.
- 正常 Aurora Location 的无签名 iOS 构建通过. 原 Bundle ID 无法在当前签名团队注册 Personal VPN 能力, 现有通配符 profile 不具备该权限; 未替换已安装原 App 的标识.
- 独立实验 Bundle ID 获得带 `allow-vpn` 的 provisioning profile, 签名构建和 `codesign --verify --deep --strict` 通过. `Aurora 连接实验` 已安装到原 iPhone; 它只显示 IKEv2 页, 不注册原 `auroralocation` URL Scheme, 原定位 App 的配对数据不迁移.
- 用户确认后, bwg 已从 EPEL 安装 strongSwan 6.0.6, 独立配置 aurora-lab 加载成功, UDP 500/4500 已运行时及永久放行. Xray, canary, Caddy, Hysteria2 均保持 active. 这不等于 iPhone 已成功握手.
- 实验服务只发布 10.203.0.1/32, 地址池 10.203.0.2-10.203.0.5, 不发布默认路由或 DNS, 不新增 NAT. 使用现有 wloc 公开证书, 完整中间链经系统 CA 验证通过; 证书副本有效至 2026-10-20, 长期保留前需接入续期. 不新增手机根证书或跳过服务器身份验证. 配置依照 [strongSwan iOS 互通要求](https://docs.strongswan.org/docs/latest/interop/ios.html).
- 服务端配置: /etc/strongswan/swanctl/conf.d/aurora-lab.conf; 独立 loopback 地址随 strongswan systemd 生命周期添加和移除. 凭据仅在服务端受保护文件及本机临时接入文件, 不入 Git. 回退先 systemctl disable --now strongswan, 再仅移除 public zone 的 UDP 500/4500 运行时和永久端口; 不 reload 防火墙或重启现有代理. 部署前备份位于 bwg:/root/aurora-ikev2-backup.
- 实机首次读取发现系统在无 protocol 的状态下仍提供默认 description. 已据 `protocol=nil, enabled=false, status=.invalid` 修复首次识别并增加回归, 临时状态采集代码已移除.
- [x] 实机初始页显示未配置, 点击空表单的保存并连接会显示地址校验错误, 未弹出添加 VPN 或启动连接. 最终包中未配置时点击断开和移除均无操作. 完整有效输入/连接操作仍待服务端.
- [ ] 用户授权系统创建配置, 正确凭据连接成功, 重启 App 后凭据仍可用; 错误身份和错误密码失败.
- [ ] 改密码保存失败保留旧有效配置, 断开和移除仅作用于本 App 的 VPN, 移除后 Keychain 凭据清理.
- [ ] 纯蜂窝下 IKEv2 和 Shadowrocket 同时连接, 既有外网与分流正常.
- [ ] 受限 listener 回包, RPPairing/RSD/DVT 真实握手及 set/clear 成功.
- [ ] 后台/锁屏持续保持和模拟步行分别验收; VPN connected 或普通 echo 不作为定位成功证据.

### 2026-09-17 IKEv2 连接中排查

- 用户已完成凭据保存和系统授权. 域名入口的手机重试收到服务端 IKE_SA_INIT 回应, 未进入 IKE_AUTH 后超时; 该请求源地址为 bwg 本身, 提示代理转发路径, 尚不能确认唯一原因.
- 只将实验 App 服务器地址改为 bwg IPv4, Remote ID 和已存凭据保持不变. 00:00:53 服务端记录一次 EAP_MSCHAPV2 成功, IKE_SA 和 CHILD_SA 建立, 随即收到客户端 DELETE; 同时新会话又来自 bwg 本身并停在初始握手. 不能将瞬时建立算稳定连接.
- 用户明确授权后, 已在 shadowrocket.conf 顶部添加临时 `IP-CIDR,67.230.174.234/32,DIRECT,no-resolve` 规则, 其余规则与节点不变. 00:09 重试仍在 EAP/IKE/CHILD 建立后被客户端 DELETE. 手机 Wi-Fi/蜂窝未切换.
- 00:18:55 真机 Console 的 nesessionmanager 明确记录 `Request to install personal session ... delayed due to exclusive enterprise session (...Shadowrocket...)`, 随后 `config request: failed to request install`. NEIKEv2Provider 报 `setTunnelNetworkSettings (Set) failed (en0): NEAgentErrorDomain Code=1`, 以 IKEv2ProviderDisconnectionErrorDomain 31 结束. 此次直接失败点是 iOS 拒绝在当前 Shadowrocket 独占会话旁安装 Personal VPN 网络配置, 不能只归因于密码/证书/端口.
- 小火箭设置中强制路由和包括所有网络均原已关闭, 只读检查未修改. DIRECT 规则仍保留, 可通过删除该精确规则回退. 未验证改变 TUN 路由是否解除独占, 不据此宣称所有共存方案不可能.
- App 增加原生 fetchLastDisconnectError 诊断入口, 仅显示固定错误分类与编号, 不输出 userInfo. focused Swift 检查, 签名构建, codesign 和安装通过. 本次真机 API 返回 nil, 页面如实显示系统未提供原因; 上述具体原因来自 Console, 不是该 API.
- 已停止 Console 流式采集并恢复 Info 选项. 实验页显示已断开, 无定位操作. 服务端无 tcpdump, 本轮无抓包证据; 蜂窝共存与真实 DVT 定位仍未通过.

### 2026-09-17 10:12 IKEv2 数据面与开发者入口对照

- 用户先连接 IKEv2 再开启 Shadowrocket 后, 系统两项均显示连接, 蜂窝 5G/Wi-Fi 未连接. 10:09 App check 为 UDP 3/auth 2/reflected 2/rejected 0, 收到源端口 49152 的 RST, RPPairing 提前关闭. 不能将双 VPN 状态等同于数据面或定位成功.
- bwg 同一 IKE_SA #37/CHILD #9, 在线租约 10.203.0.2, 只允许服务器 10.203.0.1/32. 服务器绑定 10.203.0.1 向手机 49152 做一次 5 秒 TCP connect, 不发送应用数据: 双 VPN 时超时, ESP out 增加 3 包/in 0; ping 2/2 丢失.
- 只暂时关闭 Shadowrocket, 不重连 IKEv2: ping 2/2 成功, 延迟约 217-260ms; 同一 TCP connect 明确返回 ECONNREFUSED(111), ESP in 增加 3 包. 恢复 Shadowrocket 后同一会话仍 ESTABLISHED, ping 再次 2/2 丢失. 已恢复原 Aurora-Auto/配置连接, 未改变节点或路由.
- 结论: 当前双 VPN 有可复现的数据面冲突; 单独 IKEv2 在蜂窝下数据面可通, 但手机 VPN 地址的 49152 不接受连接. 不能只靠将现有 App 流量改走 IKEv2 宣称可修复. TCP refusal 不能单独区分未监听和系统拒绝, 不宣称所有方案不可能. 没有新增服务/开放端口/传输配对凭据/执行定位.

## 2026-09-16 模拟步行

自动规划修复证据:

- 真机原纽约坐标请求 MapKit 2 的底层详情为 MKDirectionsErrorCode 8 / GEOError -7, 起终点均 OUT_OF_COVERAGE. US 国家字段和新 MKMapItem API 仍失败, 同一 App 北京路线成功 365 米. 手机 Apple Maps 的地标步行路线成功 900 米/12 分钟, 与第三方 SDK 覆盖分开记录.
- 新 FOSSGIS foot 服务在原手机原纽约坐标返回约 877 米/36 点并通过校验. 最终包正常页面重新选取附近终点后点击自动规划, 实际显示 809 米/约 11 分钟、沿道路蓝色折线、可用开始按钮及路线来源. 没有自动开启模拟定位.
- 最终包真机验证隐私链接可见; 发起规划后立即切到定点标签再返回, 不出现旧路线, 再次规划成功. 普通切标签保留已完成预览.
- `sh scripts/check.sh` 通过, 新增 foot 请求格式、fallback 分类、GeoJSON、非法坐标/远端吸附/错误几何拒绝检查; 签名 iOS Debug 构建及覆盖安装通过. 无第三方 SDK, 无无限重试, 公共服务限流和声明见 README.

- `sh scripts/check.sh` 通过, 包括路线折线/跨日期线插值、速度、暂停恢复、到达、长间隔中断, 以及真实 AppState 配合内存引擎的调度/失败/clear 回归. 内存引擎不证明真机 DVT 行为.
- 初版 generic/platform=iOS Debug 未签名完整构建及模拟器首页截图通过; 随后已完成上述真机路线规划与切标签交互验收. 真机定位移动和持续保持仍按下方清单分别验收.
- [ ] 在已验证可用的连接上规划步行路线, Apple Maps 观察位置沿路线推进.
- [ ] 暂停保持, 继续不跳点, 到达保持终点, 结束后恢复真实位置.
- [ ] 切标签不停止步行, 起终点弹窗/速度选择正常, 大字号和 VoiceOver 可操作.
- [ ] 切后台/锁屏观察实际持续能力, 超过 8 秒执行间隔后回前台显示中断.
- [ ] 断开连接后停止进度并显示未知状态, 重连可 clear. 蜂窝限制未由此功能修复.

记录日期: 2026-09-09. 未完成的项目不能视作通过.

## 本轮已验证

| 项目 | 结果 |
| --- | --- |
| Xcode | 26.6, build 17F113, iPhoneOS SDK 26.5 |
| 工程结构 | xcodebuild -list 能识别 AuroraLocation target/scheme, plist lint 通过 |
| 模型检查 | sh scripts/check.sh 通过 |
| URL 校验 | set/clear 正常路径, 边界值, NaN/Infinity/越界, 重复/额外/缺失参数, 非法协议/路径/userinfo/port/fragment 拒绝 |
| 本地模型 | SavedPlace Codable round trip, 最近位置去重与 20 项限制通过 |
| 已连接目标 | iPhone 17 Pro Max, iOS 27.0 (24A5430a), Developer Mode enabled, DDI services available |
| 完整 App build | Xcode 26.6 Debug iphoneos arm64 无签名 build 通过, App 约 11 MB. 全部 Swift 真实 SDK typecheck 零诊断 |
| 签名/安装 | 本地 Developer Team 自动签名 build 通过, codesign --verify --deep --strict 通过, devicectl 安装成功并报告已启动; 签名身份不随源码发布 |
| 本机 pairing / DVT | 系统 Developer Mode 列表已显示 Aurora Location, App 已保存凭据. 后续用户已反馈 Shadowrocket 单 VPN 定位成功; 完整 set/换点/clear/后台矩阵仍待逐项验收 |
| Shadowrocket 基线 | 2.2.92 (3445), 原配置开启后 TCP 探测 ready, Remote Pairing 握手失败; ready 不能当作服务可用 |

## 可重复命令

```sh
sh scripts/check.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project AuroraLocation.xcodeproj -scheme AuroraLocation \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Rust patch 检查和锁定源码构建见 `Vendor/idevice` 的记录. 不能使用 Locus 预编译二进制替换以绕过构建失败.

## First pairing

- [ ] 首次打开进入中文向导, 无凭据时 set/clear 被阻止.
- [x] 允许本地网络, 在 Developer Mode > Pair with Host 发现 Aurora Location.
- [ ] 设备锁屏密码和 6 位 PIN 分开输入, PIN 不进入日志.
- [ ] 配对成功, PIN 通知消失, 重启 App 后仍能使用已存凭据.
- [ ] 取消未连接的配对后可重新开始, 不累积 worker/listener.
- [ ] 在 PIN 阶段取消/输错/超时, UI 可恢复且不保存失败结果.
- [ ] 后台时间到期会取消, 返回 App 可重试.
- [ ] 拒绝本地网络/通知时有可理解的提示. 无通知时可回 App 查看 PIN, 不绕过权限.
- [ ] 配对文件为 Complete Data Protection, 目录排除备份; 锁屏不能读取. 不通过日志或导出泄露验证材料.

## Teleport / 换点

选中 Times Square: `40.7580, -73.9855`. 在开启 Wi-Fi + Shadowrocket 且本机连接检测通过后点击开启模拟定位.

- [ ] 命令发送完成, UI 只显示最近操作而非伪造实时模拟状态.
- [ ] Apple Maps 显示时代广场附近.
- [ ] 微信 / 高德 / 天气 / 美团 / 支付宝分别人工观察并记录, 不编写绕过第三方检测的代码.
- [ ] 搜索另一个位置并再次 set, 地图显示新位置.
- [ ] 手工越界输入被拒绝, 无效 URL 不改变位置.
- [ ] 收藏重启保留, 最近位置仅在成功 set 后新增, 最大 20 项.

## Network transition / 会话保持

- [x] FFI stub 回归: set 保留句柄、换点复用、检测不拆除、clear/失败有序释放、失败后重连. 此项不证明设备持续模拟.
- [ ] set 后前台保持 5 分钟, 核对目标坐标.
- [ ] 关闭 Aurora Location, 检查位置是否保持.
- [ ] 关闭 Wi-Fi 并切换 5G, 再次检查位置.
- [ ] 无互联网但保持关联的 Wi-Fi 可以建立新会话.
- [ ] 关闭系统 Wi-Fi 后, 仅蜂窝尝试新 set/clear, 不再被 App Wi-Fi 检查拦截; 记录实际握手和地图结果.
- [ ] 小火箭本机连接未就绪、断开、错误配对或 DDI 不可用时显示错误, 不伪造成功.

用户已反馈仅保留会话版仍会在刷其他 App 或锁屏后恢复. 用户已同意增加后台位置监测和始终定位权限. 2026-09-09 监测版启用 Core Location background location updates, 显示最近观测的目标偏差与精度; 当时未增加后台音频或自动重发. 2026-09-11 的定期保持验证见下文.

- [ ] 设置 > 启用监测 / 申请始终定位, 并在系统权限设置中确认始终允许.
- [ ] 设置坐标后, 监测显示最近观测及时间, clear 后停止更新.
- [ ] 切到其他 App 5 分钟、锁屏 5 分钟分别观察保持情况, 不将前台成功写成无限后台保持.
- [ ] 关闭后台监测能停止位置更新, 不主动清除仍保留的模拟会话.
- [ ] 无权限/无定位数据/过期观测时不伪造匹配目标; 观测坐标不存储或上传.

## Clear

- [ ] 当前 App 内点击固定底部的恢复真实定位, Apple Maps 恢复真实位置.
- [ ] 强制关闭并重新打开 App 后, 状态显示未知; 重新连接 Wi-Fi + Shadowrocket 后 clear 仍可成功.
- [ ] 没有此前 set 的新会话也能执行 clear, 不依赖内存句柄.
- [ ] `auroralocation://clear` 与按钮结果一致.
- [ ] 断网导致 clear 未完成时显示状态未知, 不清空为伪造的已恢复状态.

## UI 与生命周期

- [ ] 地图轻点、长按都更新 Pin, 平移和缩放可用.
- [ ] 搜索输入快速改变不会显示旧结果, 失败可重试.
- [ ] 反向地理编码不会把旧选点覆盖回来.
- [ ] VoiceOver 能操作手工坐标和恢复按钮, 大字号能滚动所有内容.
- [ ] 配对/DVT busy 期间禁用冲突操作, 配对取消仍可点击.
- [ ] 诊断只含版本、配对存在标记、网络/开发者检测状态与固定错误码.

构建注意: 沙箱内 actool 无法访问 CoreSimulator 服务时失败, 使用正常本机权限构建通过. 唯一构建 warning 为未引入 AppIntents 时跳过 metadata extraction, 与 Phase 1 不实现 App Intents 一致.

## 2026-09-11 后台保持与蜂窝对照

设备: iPhone 17 Pro Max, iOS 27.0 (24A435). 保留现有配对和 Shadowrocket 配置.

- 真机偏好开关为 true, Core Location 实际授权为 Always (3), startUpdatingLocation 已调用, 初始回调标记为模拟源. 不能再将回退归因为未开监测.
- 监测版在连接电脑时, 用户确认切后台约 40 秒和锁屏至少 1 分钟仍在时代广场. 该结果不能代表拔线使用.
- 新增每 4 秒重发已应用坐标, 新命令先取消旧任务, 保持失败后停止并显示错误. 不写重复历史, 不跟随未应用选点, 不使用音频或无限重连.
- 用户确认定期保持版拔线后, Wi-Fi 锁屏至少 2 分钟, 解锁直接查看地图仍在时代广场. 读回的保持事件约 4 秒一次, 未观察到超过 8 秒的间隔. 更长时间及强制退出不在此验收范围.
- 系统设置关闭 Wi-Fi 后, 旧会话换点失败. 新进程纯蜂窝握手约 0.2 秒返回 tunnelUnavailable / 连接提前关闭 / code 1, sub 0. Wi-Fi 无线功能开启但不连接网络的对照也失败. 省略 TCP 预探测仍失败, 已撤回该实验改动. 蜂窝问题未解决.
- sh scripts/check.sh 通过, 包括 EOF 固定分类与原始 peer 内容不泄露的回归; 签名 Debug build 和安装完成.

详细诊断在 Debug/Release 均默认关闭. 验证前在设置中手动开启 "记录详细诊断", 状态事件统一保存在 detailedDiagnosticEvents, 最多 500 条, 无坐标或配对数据. 结束后关闭开关即停止新增记录, 可导出或清空已有记录. UserDefaults 后台写盘可能延迟; 回到 App 后再导出偏好 plist 进行检查:

```sh
sh scripts/check-device-maintenance.sh /tmp/aurora-location-preferences.plist
```

该检查只证明读回的保持指令节拍, 地图结果仍需真机观察. 本轮 clear 后至少 12 秒未出现新的保持指令或错误, target 已清空; 不将该日志等同于 clear 后地图真实坐标的独立验收.
