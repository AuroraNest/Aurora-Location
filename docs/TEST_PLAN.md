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

Debug 的 locationDebugEvents 仅保留最近 40 条状态事件, 无坐标或配对数据. UserDefaults 后台写盘可能延迟; 回到 App 后再导出偏好 plist 进行检查:

```sh
sh scripts/check-device-maintenance.sh /tmp/aurora-location-preferences.plist
```

该检查只证明读回的保持指令节拍, 地图结果仍需真机观察. 本轮 clear 后至少 12 秒未出现新的保持指令或错误, target 已清空; 不将该日志等同于 clear 后地图真实坐标的独立验收.
