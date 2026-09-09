# 测试与真机验收

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

用户已反馈旧版断开会话后恢复真实位置. 新版保留连接和中继, 不增加后台音频或自动重发; 切 App/锁屏须单独记录时长, 不将前台成功写成无限后台保持.

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
