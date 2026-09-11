import CoreLocation
import Combine

@MainActor
final class LocationMonitor: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: "backgroundLocationMonitoring")
    @Published private(set) var status = "未开始监测"
    // Core Location delivers delegate callbacks on this manager's creation run loop (main).
    private let manager = CLLocationManager()
    private var target: Coordinate?

    func recordDebugEvent(_ event: String) {
        #if DEBUG
        let defaults = UserDefaults.standard
        var events = defaults.stringArray(forKey: "locationDebugEvents") ?? []
        events.append("\(Date().timeIntervalSince1970) \(event) enabled=\(isEnabled) auth=\(manager.authorizationStatus.rawValue) target=\(target != nil)")
        defaults.set(Array(events.suffix(40)), forKey: "locationDebugEvents")
        #endif
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    func enable() {
        isEnabled = true
        UserDefaults.standard.set(true, forKey: "backgroundLocationMonitoring")
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
        updateMonitoring()
    }

    func disable() {
        isEnabled = false
        UserDefaults.standard.set(false, forKey: "backgroundLocationMonitoring")
        manager.stopUpdatingLocation()
        status = "已关闭监测"
    }

    func setTarget(_ coordinate: Coordinate) {
        target = coordinate
        updateMonitoring()
    }

    func stop() {
        target = nil
        manager.stopUpdatingLocation()
        status = "定位会话结束, 监测已停止"
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateMonitoring()
    }

    private func updateMonitoring() {
        recordDebugEvent("updateMonitoring")
        guard isEnabled else { status = "未启用"; return }
        guard manager.authorizationStatus == .authorizedAlways else {
            manager.stopUpdatingLocation()
            status = "需要始终允许定位; 点申请权限或在系统设置中开启"
            return
        }
        guard target != nil else { status = "已获权限, 设置模拟位置后开始监测"; return }
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        recordDebugEvent("startUpdatingLocation")
        status = "等待系统位置更新"
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        recordDebugEvent("locationCallback simulated=\(locations.last?.sourceInformation?.isSimulatedBySoftware == true)")
        guard let target, let location = locations.last,
              Coordinate.observedLocation(location) != nil else { return }
        let destination = CLLocation(latitude: target.latitude, longitude: target.longitude)
        let distance = location.distance(from: destination)
        let source = location.sourceInformation?.isSimulatedBySoftware == true ? "模拟来源" : "系统来源"
        status = "最近观测: 距目标 \(String(format: "%.0f", distance)) 米, 精度 \(String(format: "%.0f", location.horizontalAccuracy)) 米, \(source), \(location.timestamp.formatted(date: .omitted, time: .standard))"
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        recordDebugEvent("locationError code=\((error as NSError).code)")
        status = "系统位置更新暂不可用"
    }
}
