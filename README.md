# Aurora Location

[English](README.en.md)

Aurora Location 是面向个人 iPhone 修改定位工具. 它以 SwiftUI 和 MapKit 选点, 通过 Apple DVT `LocationSimulation` 请求设置模拟坐标或恢复真实定位. 它不修改第三方 App, 不提供规避第三方检测的功能, 也不以 App Store 发布为目标.

项目实现了 iOS 27 本机 `Remote Pairing`, 并通过既有 Shadowrocket 单 VPN 配置建立开发者连接. 已有用户真机反馈确认 Aurora Location + Shadowrocket 单 VPN 的模拟定位成功, 系统配对列表和 App 配对保存也已确认. 这不等于所有场景均已验收: 完整的 set/换点/clear 矩阵, Apple Maps 复核, 前后台保持和纯蜂窝新连接仍须按 [测试计划](docs/TEST_PLAN.md) 在真机逐项验收.

## 功能

- iOS 27 本机 Remote Pairing 向导, 6 位 PIN, 取消和受保护的本地配对记录.
- 地图轻点或长按选点, 搜索, 反向地理编码和手动坐标.
- 本地收藏和最多 20 条去重的最近位置.
- 严格校验的 `auroralocation` URL Scheme, 中文错误提示和脱敏诊断.
- 为 Shadowrocket 导出设备生成的本地 WireGuard peer 配置和分流模块.

`最近操作` 只表示指令在 App 端完成, 不代表系统仍在模拟定位. 每次启动的状态均为未知, 请用 Apple Maps 或目标测试 App 人工验证.

## 要求

- macOS 和 Xcode. App deployment target 为 iOS 18.0. 已验证构建参考为 Xcode 26.6 和 iPhoneOS SDK 26.5, 不是最低版本承诺.
- 已启用 Developer Mode 的 iPhone. 当前首次本机 Remote Pairing 要求 iOS 27.
- 可用的 Apple Developer signing identity 和 provisioning. Xcode 必须先完成设备准备和 DDI 服务可用.
- Shadowrocket, 可在现有单 VPN 配置中导入本地 WireGuard peer 和模块. 已记录的兼容参考是 2.2.92 (3445), 不是最低版本承诺. 不需要第二个 VPN App.
- arm64 真机. Native 静态库不提供 Simulator slice.

## 获取源码和构建

```sh
git clone https://github.com/AuroraNest/Aurora-Location.git
cd Aurora-Location
sh scripts/check.sh
```

`scripts/check.sh` 运行 URL/坐标和本地存储模型检查, FFI 会话 stub 检查和 plist lint. 它不是设备协议或模拟定位验收.

在 Xcode 打开 `AuroraLocation.xcodeproj`, 选择 `AuroraLocation` scheme. 在 `Signing & Capabilities` 中选择自己的 Developer Team, 使用 `Automatically manage signing`, 并改为自己唯一的 Bundle ID. 仓库不包含 Team ID, signing certificate 或 provisioning profile. 如需本机 Team 配置, 创建未纳入 Git 的 `Signing.xcconfig`, 项目已有可选 include.

可做无签名 device build:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project AuroraLocation.xcodeproj -scheme AuroraLocation \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

随后连接并解锁设备, 开启 Developer Mode, 在 Xcode 选择设备并 Run. 签名、安装或启动成功只能证明安装链路, 不能证明 `set` 或 `clear` 已改变系统定位.

## 配置 Shadowrocket 本地 WireGuard 节点

配置使用 App 为当前设备生成的 key. 不要手写、复用或分享其他设备的配置.

1. 打开 Aurora Location > 设置, 点 `复制小火箭连接配置`.
2. 打开 Shadowrocket, 从剪贴板导入 WireGuard 节点. 将节点实际名称或备注改为 **`AuroraLocal`**. 模块按这个名称引用, 大小写必须一致.
3. 回到 Aurora Location 设置, 点 `复制本机分流模块`, 在 Shadowrocket 从剪贴板导入并启用模块:

```ini
#!name=Aurora Local
#!desc=Local developer connection only
[Rule]
IP-CIDR,10.7.0.1/32,AuroraLocal,no-resolve
```

4. 保持日常代理节点作为默认策略. 模块只将 `10.7.0.1/32` 指向 `AuroraLocal`, 不应接管普通流量. 启用模块后重新连接 Shadowrocket 系统 VPN. 不要覆盖已有订阅, 也不要默认修改 `skip-proxy`, `tun-excluded-routes` 或 `compatibility-mode`.
5. 回到 App 点 `重新检测`. TCP ready 仅表示端口可达, 不是新的 Remote Pairing 或 DVT 成功证明.

导出的 peer 使用本机 endpoint `127.0.0.1:51820`, client address `10.7.0.10/24`, `AllowedIPs = 10.7.0.1/32`. Native responder 只接受经认证且指向约定地址的 IPv4 TCP 动态端口流量. 动态端口是必要的, 不要把规则缩窄到初始端口 `49152`.

App 只在本机剪贴板暂存连接配置 2 分钟. 配置含该设备的 WireGuard private key, 虽不含 Apple pairing record, 仍不得上传到订阅、Git、日志或聊天记录.

## 首次 Remote Pairing

1. 确认 Shadowrocket 已连接, Developer Mode 已开启, 且 Xcode 已准备设备.
2. 连接 iPhone Wi-Fi. 首次 Bonjour 配对需要 Wi-Fi.
3. 在 Aurora Location > 设置点 `开始配对`, 允许本地网络和通知权限, 并保持 App 在前台.
4. 前往系统 `设置 > 隐私与安全性 > 开发者模式 > Pair with Host`, 选择 Aurora Location.
5. 先输入设备锁屏密码, 再输入 App 画面或本地通知显示的 6 位 PIN.
6. 返回 App, 确认显示已保存配对凭据, 然后点 `重新检测`.

配对最长等待约 3 分钟. App 进入后台时 iOS 只提供有限执行时间. 取消、超时或 PIN 错误后返回 App 重试. 不要把 PIN 复制到诊断或外部位置. 已配对后, `set`/`clear` 不会因 App 读取不到 Wi-Fi 接口地址而预先拒绝, 实际结果仍取决于握手.

## 设置和恢复定位

地图中轻点或长按选点, 也可搜索或输入坐标. 点击 `开启模拟定位`, 在 Apple Maps 检查目标位置. 点击底部固定的 `恢复真实定位`, 再次在 Apple Maps 检查恢复结果.

首次 `set` 会启动本机中继并建立 DVT 会话. 会话仍保留时, 后续 `set` 和 `clear` 复用该连接, 不会每次重新连接. `clear` 会关闭 DVT 会话和中继. 没有内存中会话时, `clear` 的实现会重新建立连接以发送恢复请求. 操作失败时会释放会话和中继, 下次操作重新连接.

这是实现行为, 不是设备验收结论. App 重启后 `clear` 的重新连接路径已实现, 仍需真机确认. 网络断开导致 `clear` 未完成时, 定位状态应视为未知.

## 快捷指令和 URL Scheme

在 Apple Shortcuts 中用 `URL` 动作建立链接, 再用 `Open URLs` 打开:

```text
auroralocation://set?lat=40.7580&lon=-73.9855
auroralocation://clear
```

`set` 只接受有限的 `lat` 和 `lon`. 纬度范围 -90 至 90, 经度范围 -180 至 180. 重复、缺失或额外参数, fragment, userinfo, port, 非法 path/scheme, `NaN` 和 `Infinity` 均会被拒绝. URL 与界面按钮共用同一配对和网络前置检查. 模拟期间每 4 秒重发已应用的坐标, 不跟随尚未应用的地图选点, 不重复写历史或振动. 恢复真实定位或保持失败后停止重发, 不无限重连. 当前没有 App Intents.

## 故障排查

| 现象 | 先检查什么 |
| --- | --- |
| `Pair with Host` 没有 Aurora Location | iOS 版本, Developer Mode, Wi-Fi, 本地网络权限和 App 是否停留前台. |
| PIN 不出现或配对超时 | 通知权限, 系统 Pair with Host 流程, 锁屏密码和 6 位 PIN 是否按顺序输入. 取消后重新开始配对. |
| 重新检测显示端口不可达 | Shadowrocket 是否作为系统 VPN 连接, 本地 WireGuard peer 是否导入, 模块是否启用. |
| 端口可达但握手失败 | 节点实际名称是否为 `AuroraLocal`, 模块是否引用同名节点. 检查 Shadowrocket 对本地地址的规则/连接记录. TCP ready 不能证明服务响应. |
| WireGuard 有统计但 DVT 失败 | 统计仅表示本地数据面收到、认证或回送流量. 检查 Developer Mode 和 Xcode 设备准备/DDI. |
| set/clear 后地图未变化 | 不要依据最近操作判断. 用 Apple Maps 验证, 检查 Shadowrocket 和开发者连接, 失败后按未知状态处理. |
| 切后台或锁屏后位置恢复 | 在设置启用后台位置监测, 并授予始终定位权限. 定期重发支持当前会话, clear 后停止. 2026-09-11 真机拔线后 Wi-Fi 锁屏至少 2 分钟仍保持目标位置; 更长时间仍须验证. 不使用后台音频. |

## 隐私和安全

- 配对记录和 WireGuard keys 位于 Application Support, 使用 Complete Data Protection, owner-only 目录权限, 并排除 iCloud/iTunes backup.
- PIN 不写入日志. 脱敏诊断只含版本、配对存在标记、网络/服务状态、中继统计和固定错误码.
- 收藏和历史仅存本机. 没有账号、analytics、自建服务器或云同步.
- 后台监测的观测位置不保存或上传; 会显示系统定位指示并增加耗电, 可在设置关闭.
- Debug 构建仅在本机保留最近 40 条权限、生命周期和指令状态事件, 不含坐标或配对数据.
- MapKit 搜索、地图和反向地理编码会使用 Apple 服务, 因此不是完全离线功能.
- 连接配置和配对记录是敏感材料. 删除 App 或清除数据可能删除本地凭据, 之后需要重新配对并重新导出 peer.

## 限制和验收边界

- 不承诺模拟位置可无限后台保持. iOS 挂起或终止 App 后可能恢复真实位置.
- 2026-09-11 真机纯蜂窝新建握手仍失败, 分类为 socket 提前关闭; Wi-Fi 切蜂窝后换点也失败. 蜂窝支持尚未解决. 无互联网 Wi-Fi 新会话, 重启后 clear 和全部目标 App 行为仍未验证.
- 已有用户真机反馈确认单 VPN 模拟定位成功, 但完整的 set/换点/clear、Apple Maps、重启、前后台和蜂窝网络验收矩阵仍未完成.
- 不自动下载或挂载 DDI. 开发者服务出错时先用 Xcode 重新准备设备.
- 不实现 joystick, GPX, 路线, 账号, 云同步, 反检测, 内置 VPN 或 Simulator DVT.

以 [docs/TEST_PLAN.md](docs/TEST_PLAN.md) 中未勾选项目作为实际验收清单. [docs/SHADOWROCKET.md](docs/SHADOWROCKET.md) 记录单 VPN 证据和限制.

## 重建第三方 native 库

仓库包含匹配的 arm64 iOS 静态库和 C header. 不要仅替换一个 artifact: `idevice.h` 和 `libidevice_ffi.a` 必须来自同一次构建.

重建 `Vendor/idevice` 需要 Git, Xcode/iPhoneOS SDK, Rust 1.93.1 和 `aarch64-apple-ios` target, 以及上游仓库和 Cargo registry 访问:

```sh
scripts/build-idevice.sh
```

脚本固定 upstream commit、lock file 和 patch, 在隔离 build checkout 中还原源码, 使用 `--locked` 构建并检查导出符号. 可通过 `IDEVICE_BUILD_DIR` 指定 disposable checkout. 脚本会 reset 该目录, 不要指向有未保存修改的目录.

重建本机 WireGuard responder 也需要 Rust 1.93.1、iOS target 和固定 `Cargo.lock`:

```sh
cargo test --locked --manifest-path Vendor/emproxy/Cargo.toml
scripts/build-emproxy.sh
```

这些命令只验证 native 组件, 不替代 iPhone 上的 Remote Pairing 或定位验收. 详见 [Vendor/idevice/SOURCE.md](Vendor/idevice/SOURCE.md)、[Vendor/emproxy/README.md](Vendor/emproxy/README.md) 和 [第三方声明](THIRD_PARTY_NOTICES.md).

## 许可和文档

- [架构](docs/ARCHITECTURE.md)
- [测试与真机验收](docs/TEST_PLAN.md)
- [Shadowrocket 单 VPN 说明](docs/SHADOWROCKET.md)
- [技术与许可证审计](docs/RESEARCH.md)
- [第三方声明](THIRD_PARTY_NOTICES.md)

Aurora Location 的部分实现源自 Locus, 依照 [MIT License](LICENSE) 保留声明. `idevice` 和 Rust 依赖的来源、锁定版本和许可证见 `Vendor/` 与第三方声明.
