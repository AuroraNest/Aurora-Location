import CoreLocation
import Foundation
import MapKit

enum WalkingRouteSource: Equatable, Sendable {
    case apple
    case openStreetMap
}

struct WalkingRoute: Sendable {
    static func canUseAlternateService(after error: Error) -> Bool {
        let failure = error as NSError
        return failure.domain == MKErrorDomain &&
            [Int(MKError.Code.serverFailure.rawValue), Int(MKError.Code.directionsNotFound.rawValue)].contains(failure.code)
    }

    static func planningErrorMessage(_ error: Error) -> String {
        let failure = error as NSError
        if failure.domain == MKErrorDomain {
            let reason: String
            switch MKError.Code(rawValue: UInt(max(0, failure.code))) {
            case .serverFailure:
                reason = "地图路线服务未能返回结果, 请检查网络后重试."
            case .loadingThrottled:
                reason = "地图路线请求过于频繁, 请稍后重试."
            case .directionsNotFound:
                reason = "地图服务未返回这两点的步行路线, 可能涉及服务覆盖或选点, 不代表实际没有道路."
            case .placemarkNotFound:
                reason = "地图服务无法识别起点或终点, 请重新选点."
            default:
                reason = "地图路线规划失败, 原因尚未确认."
            }
            return reason + " (MapKit \(failure.code))"
        }
        if failure.domain == NSURLErrorDomain {
            return "路线请求网络异常, 请检查网络或代理后重试. (URL \(failure.code))"
        }
        return "路线规划失败, 原因尚未确认. (code \(failure.code))"
    }

    let coordinates: [Coordinate]
    let distance: Double
    let source: WalkingRouteSource

    private let segmentDistances: [Double]

    init?(coordinates: [Coordinate], source: WalkingRouteSource = .apple) {
        guard coordinates.allSatisfy(\.isValid), let first = coordinates.first else { return nil }

        var compacted = [first]
        var distances = [Double]()
        for coordinate in coordinates.dropFirst() {
            let segmentDistance = Self.distance(from: compacted[compacted.count - 1], to: coordinate)
            guard segmentDistance.isFinite else { return nil }
            guard segmentDistance > 0 else { continue }
            compacted.append(coordinate)
            distances.append(segmentDistance)
        }

        let totalDistance = distances.reduce(0, +)
        guard compacted.count >= 2, totalDistance.isFinite, totalDistance > 0 else { return nil }
        self.coordinates = compacted
        self.source = source
        self.distance = totalDistance
        self.segmentDistances = distances
    }

    func coordinate(at distance: Double) -> Coordinate {
        guard distance > 0 else { return coordinates[0] }
        guard distance < self.distance else { return coordinates[coordinates.count - 1] }

        var remainingDistance = distance
        for index in segmentDistances.indices {
            let segmentDistance = segmentDistances[index]
            if remainingDistance >= segmentDistance {
                remainingDistance -= segmentDistance
                continue
            }

            let start = coordinates[index]
            let end = coordinates[index + 1]
            let progress = remainingDistance / segmentDistance
            let longitudeDelta = Self.shortLongitudeDelta(from: start.longitude, to: end.longitude)
            return Coordinate(
                latitude: start.latitude + (end.latitude - start.latitude) * progress,
                longitude: Self.normalizedLongitude(start.longitude + longitudeDelta * progress)
            )
        }
        return coordinates[coordinates.count - 1]
    }

    private static func distance(from start: Coordinate, to end: Coordinate) -> Double {
        CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
    }

    private static func shortLongitudeDelta(from start: Double, to end: Double) -> Double {
        var delta = end - start
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return delta
    }

    private static func normalizedLongitude(_ longitude: Double) -> Double {
        var result = longitude
        while result > 180 { result -= 360 }
        while result < -180 { result += 360 }
        return result
    }
}

enum WalkingPhase: Equatable, Sendable {
    case walking
    case paused
    case arrived
    case interrupted
}

struct WalkingSession: Sendable {
    let route: WalkingRoute
    let speedKmh: Double
    private(set) var distanceTraveled: Double
    private(set) var phase: WalkingPhase
    var coordinate: Coordinate { route.coordinate(at: distanceTraveled) }
    var progress: Double { distanceTraveled / route.distance }

    private var lastAdvancedAt: TimeInterval

    init?(route: WalkingRoute, speedKmh: Double, startedAt: TimeInterval) {
        guard (1...8).contains(speedKmh), startedAt.isFinite else { return nil }
        self.route = route
        self.speedKmh = speedKmh
        self.distanceTraveled = 0
        self.phase = .walking
        self.lastAdvancedAt = startedAt
    }

    mutating func advance(to uptime: TimeInterval) {
        guard phase == .walking else { return }
        guard uptime.isFinite else {
            interrupt()
            return
        }

        let elapsed = uptime - lastAdvancedAt
        // ponytail: Gaps over 8 seconds interrupt so a suspended app cannot catch up an entire route at once.
        guard elapsed >= 0, elapsed <= 8 else {
            interrupt()
            return
        }

        lastAdvancedAt = uptime
        let candidateDistance = min(route.distance, distanceTraveled + elapsed * speedKmh / 3.6)
        distanceTraveled = candidateDistance
        if candidateDistance == route.distance {
            phase = .arrived
        }
    }

    mutating func pause() {
        guard phase == .walking else { return }
        phase = .paused
    }

    mutating func resume(at uptime: TimeInterval) {
        guard phase == .paused else { return }
        guard uptime.isFinite else {
            interrupt()
            return
        }
        lastAdvancedAt = uptime
        phase = .walking
    }

    mutating func interrupt() {
        // The endpoint also needs a live session; failed holding must not remain marked as arrived.
        phase = .interrupted
    }
}
