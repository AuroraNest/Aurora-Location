import Foundation
import CoreLocation

extension Coordinate {
    static func observedLocation(_ location: CLLocation, now: Date = Date()) -> Coordinate? {
        let coordinate = Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        guard coordinate.isValid, location.horizontalAccuracy.isFinite,
              location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSince(now)) <= 30 else { return nil }
        return coordinate
    }
}

struct Coordinate: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite &&
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    var label: String { String(format: "%.5f, %.5f", latitude, longitude) }
    static let timesSquare = Coordinate(latitude: 40.7580, longitude: -73.9855)
}

struct SavedPlace: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    let coordinate: Coordinate
    var createdAt = Date()
}

enum LocationCommand: Equatable, Sendable {
    case set(Coordinate)
    case clear

    init(url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "auroralocation",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty, parts.fragment == nil else {
            throw AuroraLocationError.invalidURL
        }
        let items = parts.queryItems ?? []
        switch parts.host {
        case "clear" where items.isEmpty:
            self = .clear
        case "set":
            guard items.count == 2,
                  items.filter({ $0.name == "lat" }).count == 1,
                  items.filter({ $0.name == "lon" }).count == 1,
                  let lat = items.first(where: { $0.name == "lat" })?.value,
                  let lon = items.first(where: { $0.name == "lon" })?.value,
                  let latitude = Double(lat), let longitude = Double(lon) else {
                throw AuroraLocationError.invalidURL
            }
            let coordinate = Coordinate(latitude: latitude, longitude: longitude)
            guard coordinate.isValid else { throw AuroraLocationError.invalidCoordinate }
            self = .set(coordinate)
        default:
            throw AuroraLocationError.invalidURL
        }
    }
}

enum AuroraLocationError: String, LocalizedError, Sendable {
    case invalidCoordinate, invalidURL, busy
    case pairingMissing, pairingInvalid, pairingFailed, pairingCancelled, pairingSaveFailed
    case wifiRequired, tunnelStartFailed, tunnelUnavailable, dvtConnectionFailed, developerImageUnavailable
    case locationSimulationFailed, clearSimulationFailed, storageFailed

    var errorDescription: String? {
        switch self {
        case .invalidCoordinate: return "坐标无效. 纬度须在 -90...90, 经度须在 -180...180."
        case .invalidURL: return "链接无效. 仅支持 auroralocation://set?lat=纬度&lon=经度 或 auroralocation://clear."
        case .busy: return "正在处理上一项操作, 请完成后重试."
        case .pairingMissing: return "请先在设置中完成设备配对."
        case .pairingInvalid: return "无法读取有效的配对凭据. 请解锁设备或重新配对."
        case .pairingFailed: return "配对未完成. 请检查本地网络权限, 返回 App 后重新配对."
        case .pairingCancelled: return "配对已取消或后台时间已到. 请返回 App 后重试."
        case .pairingSaveFailed: return "配对凭据保存失败. 未替换已有凭据, 请解锁设备后重试."
        case .wifiRequired: return "首次设备配对需要连接 Wi-Fi, 用于发现本机配对服务."
        case .tunnelStartFailed: return "本机中继未能启动. 请关闭其他占用本机 51820 端口的工具后重试."
        case .tunnelUnavailable: return "无法完成本机开发者握手. 请确认 Shadowrocket 已连接且本机中继配置匹配, 并允许本地网络访问. 若纯移动网络握手失败, 请连接 Wi-Fi 后重试."
        case .dvtConnectionFailed: return "开发者服务连接失败. 请确认 Developer Mode 已开启, DDI 已挂载且配对有效."
        case .developerImageUnavailable: return "开发者镜像或 LocationSimulation 服务不可用. 请用 Xcode 准备设备后重试."
        case .locationSimulationFailed: return "设置指令未完成. 系统定位状态未知, 请重试或恢复真实定位."
        case .clearSimulationFailed: return "恢复指令未完成. 系统定位状态未知, 请检查 Shadowrocket 本机连接后重试."
        case .storageFailed: return "本地数据读写失败. 已有数据未被覆盖, 请检查设备存储空间."
        }
    }
}
