# Aurora Location 技术与许可证审计

审计日期: 2026-09-09. 本文保留初始技术调查, 历史 LocalDevVPN 路径已由 Shadowrocket 单 VPN 路径替代. 当前使用步骤以 [README](../README.md) 为准, 验收范围以 [TEST_PLAN](TEST_PLAN.md) 为准.

## 结论与固定来源

- Locus: `ChrisMack32/Locus@83c8fb324983728e8f44759cfd834dc637ee38b5`, 根 LICENSE 为 MIT. 复用其 Swift 层连接顺序和 NWListener 中继思路, 不复制整套产品.
- idevice: 使用 `jkcoxson/idevice@e98264c4194e6980173c576ac79a58adce95492b` 源码及本项目可审计 patch 构建. 最终来源、锁文件、SHA-256 和重建方式见 [Vendor/idevice](../Vendor/idevice/).
- Locus 附带 `.a` 未采用. 其 header 的 pairing ABI 与公开 idevice 不同, 缺少对应 commit/Cargo.lock/patch. 上游 README 的 MIT 声明无法解决二进制来源问题.

## Locus 架构

`MapHomeView -> SpoofSession -> LocationEngine -> idevice FFI`. `PairOnDeviceService` 提供后台 worker 与 PIN, `PairableHostAdvertiser` 通过 Network.framework 广播 Bonjour, `PairingStore` 保存凭据. 原产品还带 joystick/routes/GPX、周期重发、后台定位和静音音频, Aurora Phase 1 不引入这些功能.

证据:

- [LocationEngine.swift](https://github.com/ChrisMack32/Locus/blob/83c8fb324983728e8f44759cfd834dc637ee38b5/Locus/Engine/LocationEngine.swift)
- [PairOnDeviceService.swift](https://github.com/ChrisMack32/Locus/blob/83c8fb324983728e8f44759cfd834dc637ee38b5/Locus/Engine/PairOnDeviceService.swift)
- [PairableHostAdvertiser.swift](https://github.com/ChrisMack32/Locus/blob/83c8fb324983728e8f44759cfd834dc637ee38b5/Locus/Engine/PairableHostAdvertiser.swift)

## iOS 27 本机配对

1. idevice `PairableHostInfo` 生成本次主机标识与认证信息, Rust 在 `127.0.0.1` 的随机端口监听.
2. Swift `NWListener` 广播 `_remotepairing-pairable-host._tcp`, TXT 包括 identifier/name/model/authTag/flags/ver/minVer.
3. iOS 的 Developer Mode > Pair with Host 浏览并连接该服务. Swift 双向转发字节到 Rust loopback listener.
4. 用户先授权设备锁屏密码. idevice `PairableHost` 执行 SRP/远程配对, 回调产生 6 位 PIN, 用户在系统提示中输入.
5. 成功后序列化 RPPairing, Swift 原子保存到 Application Support/Pairing, 使用 Complete Data Protection 并排除备份.

Aurora 不实现新的 SRP 协议, 只给上游协议增加 Native Bonjour 的回调桥接、取消和总超时. 不采用 Locus 无法取消底层 accept 的 teardown. 配对仅申请有限的 `beginBackgroundTask`, 不声明 audio/location/processing 后台模式. 如果系统不给足时间, 操作会取消并允许重新开始. 这条最小后台路径需要目标 iPhone 验证, 不以源码支持代替验收.

[Apple 后台时间边界](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time).

## Developer Tunnel / RSD / DVT

```text
LocalDevVPN loopback 10.7.0.1:49152
 -> tunnel_create_rppairing
 -> TCP + RemotePairing pair-verify
 -> developer tunnel adapter + RSD handshake
 -> remote_server_connect_rsd
 -> LocationSimulation DTX channel
```

LocalDevVPN 提供到本机设备服务的可路由 loopback 路径. Aurora 的 TCP probe 只证明该地址端口可达, 不等同于 VPN 已认证或 DVT 已连接. DVT 探测单独打开完整通道后关闭.

Wi-Fi 状态检查读取 `en0` 的 UP/RUNNING 与 IP 地址, 不请求互联网. 这是接口状态推断, 不是 SSID 关联状态的权威 API. 当前仅首次配对要求 Wi-Fi; 已配对后的 set/clear 按实际连接结果判断. 无互联网 Wi-Fi 与蜂窝切换仍需真机验证.

## Set 完整路径

`RootView / URL Scheme -> AppState.execute(.set) -> pairing + loopback probe -> LocationEngine.perform -> tunnel_create_rppairing -> remote_server_connect_rsd -> location_simulation_new -> location_simulation_set -> simulateLocationWithLatitude:longitude:`. 已有会话时复用 DVT 句柄.

所有坐标再次验证 finite 和合法范围. FFI 在串行工作队列执行, 不阻塞主线程. 成功后记录最近位置与最近操作, 不宣称可靠查询到了系统当前状态. 无自动重发, set 保留会话, clear 或失败后释放.

## Clear 完整路径

`AppState.execute(.clear) -> 同样的连接前置检查 -> 复用会话或按需新建 -> location_simulation_clear -> stopLocationSimulation -> 释放会话`.

Aurora 的 clear 不要求此前存在内存句柄, 无会话时重新连接, 因而重启后仍可请求恢复. `stopLocationSimulation` 采用不等待回复的语义, 与 [pymobiledevice3 LocationSimulation](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/services/dvt/instruments/location_simulation.py) 对照. 已发送恢复指令仍须在地图确认真实位置.

句柄按 `simulation -> remoteServer -> RSD handshake -> adapter` 释放. 可追溯 idevice FFI 的 `location_simulation_new` 借用 server, 不转移所有权; Locus 的置空 server 注释不能照搬.

## DDI

Locus 的 set/clear 调用链没有自动下载、个性化或挂载 Developer Disk Image 的步骤. Aurora Phase 1 同样依赖设备已由 Xcode 准备好. 服务创建失败时提示检查 Developer Mode/DDI, 不将所有连接失败伪装成确定的 DDI 缺失.

本轮只读 `devicectl` 已确认目标 iPhone 17 Pro Max 为 iOS 27.0 (`24A5430a`), Developer Mode enabled, `ddiServicesAvailable=true`. 没有改动设备定位或系统 VPN.

## 许可边界

- Locus MIT: 保留原 LICENSE 和逐文件 attribution. 两个 pairing Swift 文件的排除比对未发现与受限项目有实质逐行复制证据, 不将这一检查当作法律保证.
- idevice MIT: 不使用不明 binary; 锁定源码、patch、Cargo.lock、依赖许可证与本次编译产物.
- `truongkma/t-location@5e57f815e5958f133dfbaae8252473054adeccf0`: AGPL-3.0, 仅核对 README/LICENSE, 不复制实现.
- `StikDebug/StikPair@d9661c505130a7b710225fb8ed61128527b46c7e`: MIT 文本附 Non-Commercial 限制, 不复制实现.
- pymobiledevice3: 只对照 DVT selector 和回复语义, 不打包 Python 代码.
- LocalDevVPN: 外部安装运行前提, 不打包或复制其代码.

完整随附清单见 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

## Xcode 26.6 能否编译

本机实测 Xcode 26.6 (`17F113`), 可用 iPhoneOS SDK 为 26.5. 默认 xcode-select 指向 CommandLineTools, 所有命令以 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 指定工具链, 不修改全局选择.

Aurora 使用已有 SwiftUI/MapKit/Network.framework API 和 C FFI, iOS 27 pairing 在 Rust 协议层实现. 因此没有仅因设备运行 iOS 27 就要求 Xcode 27 SDK 的依据. 最终可编译结论以 [TEST_PLAN.md](TEST_PLAN.md) 中实际 build 结果为准.
