import Foundation
import MapKit

func approximatelyEqual(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.000_001) -> Bool {
    abs(lhs - rhs) <= tolerance
}

@main
struct WalkingRouteCheck {
    static func main() {
        let serviceError = NSError(domain: MKErrorDomain, code: Int(MKError.Code.serverFailure.rawValue))
        assert(WalkingRoute.planningErrorMessage(serviceError).contains("服务未能返回"))
        let noRoute = NSError(domain: MKErrorDomain, code: Int(MKError.Code.directionsNotFound.rawValue))
        assert(WalkingRoute.planningErrorMessage(noRoute).contains("不代表实际没有道路"))
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        assert(WalkingRoute.planningErrorMessage(offline).contains("网络异常"))
        let unknown = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "private detail"])
        assert(!WalkingRoute.planningErrorMessage(unknown).contains("private detail"))
        assert(WalkingRoute.canUseAlternateService(after: serviceError))
        assert(WalkingRoute.canUseAlternateService(after: noRoute))
        assert(!WalkingRoute.canUseAlternateService(after: offline))
        assert(!WalkingRoute.canUseAlternateService(after: NSError(domain: MKErrorDomain, code: Int(MKError.Code.loadingThrottled.rawValue))))

        let routeStart = Coordinate(latitude: 40.758, longitude: -73.9855)
        let routeEnd = Coordinate(latitude: 40.75945, longitude: -73.97858)
        let request = try! OpenStreetMapWalkingRoute.request(from: routeStart, to: routeEnd)
        assert(request.url!.host == "routing.openstreetmap.de")
        assert(request.url!.path.contains("/routed-foot/route/v1/foot/-73.9855000,40.7580000;"))
        assert(request.value(forHTTPHeaderField: "User-Agent")?.contains("AuroraLocation") == true)
        let goodJSON = #"{"code":"Ok","routes":[{"geometry":{"type":"LineString","coordinates":[[-73.9855,40.758],[-73.982,40.758],[-73.97858,40.75945]]}}]}"#
        let decoded = try! OpenStreetMapWalkingRoute.decode(Data(goodJSON.utf8), from: routeStart, to: routeEnd)
        assert(decoded.source == .openStreetMap && decoded.coordinates.count == 3)
        assert(decoded.coordinates.first == routeStart && decoded.coordinates.last == routeEnd)
        for badJSON in [
            #"{"code":"NoRoute"}"#,
            goodJSON.replacingOccurrences(of: "LineString", with: "Point"),
            goodJSON.replacingOccurrences(of: "[-73.9855,40.758]", with: "[0,0]"),
            goodJSON.replacingOccurrences(of: "[-73.982,40.758]", with: "[200,40.758]"),
            goodJSON.replacingOccurrences(of: "[-73.982,40.758]", with: "[40.758]")
        ] {
            do {
                _ = try OpenStreetMapWalkingRoute.decode(Data(badJSON.utf8), from: routeStart, to: routeEnd)
                assertionFailure("Invalid or distant route must not start a walk")
            } catch { }
        }
        do {
            _ = try OpenStreetMapWalkingRoute.request(from: Coordinate(latitude: .nan, longitude: 0), to: routeEnd)
            assertionFailure("Invalid coordinates must not be sent")
        } catch { }
        let start = Coordinate(latitude: 0, longitude: 0)
        let corner = Coordinate(latitude: 0, longitude: 0.001)
        let end = Coordinate(latitude: 0.001, longitude: 0.001)
        let firstLeg = WalkingRoute(coordinates: [start, corner])!
        let route = WalkingRoute(coordinates: [start, corner, end])!
        let afterCorner = route.coordinate(at: firstLeg.distance + 10)
        assert(approximatelyEqual(afterCorner.longitude, corner.longitude, tolerance: 0.000_001))
        assert(afterCorner.latitude > 0)

        var session = WalkingSession(route: route, speedKmh: 3.6, startedAt: 100)!
        session.advance(to: 102.5)
        assert(approximatelyEqual(session.distanceTraveled, 2.5))
        session.advance(to: 107)
        assert(approximatelyEqual(session.distanceTraveled, 7))
        let pausedCoordinate = session.coordinate
        session.pause()
        session.advance(to: 150)
        assert(session.phase == .paused && session.coordinate == pausedCoordinate)
        session.resume(at: 200)
        session.advance(to: 202)
        assert(approximatelyEqual(session.distanceTraveled, 9))

        let shortRoute = WalkingRoute(coordinates: [start, Coordinate(latitude: 0, longitude: 0.00001)])!
        var arriving = WalkingSession(route: shortRoute, speedKmh: 3.6, startedAt: 0)!
        arriving.advance(to: 2)
        assert(arriving.phase == .arrived)
        assert(arriving.distanceTraveled == shortRoute.distance)
        assert(arriving.coordinate == shortRoute.coordinates.last)
        assert(arriving.progress == 1)
        arriving.interrupt()
        assert(arriving.phase == .interrupted && arriving.progress == 1)

        assert(WalkingRoute(coordinates: [Coordinate(latitude: 91, longitude: 0), start]) == nil)
        assert(WalkingRoute(coordinates: [start, start]) == nil)
        let deduplicated = WalkingRoute(coordinates: [start, start, corner])!
        assert(deduplicated.coordinates == [start, corner])
        assert(WalkingSession(route: route, speedKmh: 0.99, startedAt: 0) == nil)
        assert(WalkingSession(route: route, speedKmh: 8.01, startedAt: 0) == nil)
        assert(WalkingSession(route: route, speedKmh: .nan, startedAt: 0) == nil)

        let datelineStart = Coordinate(latitude: 10, longitude: 179.9)
        let datelineEnd = Coordinate(latitude: 10, longitude: -179.9)
        let datelineRoute = WalkingRoute(coordinates: [datelineStart, datelineEnd])!
        assert(datelineRoute.coordinate(at: 0) == datelineStart)
        assert(datelineRoute.coordinate(at: datelineRoute.distance) == datelineEnd)
        assert(abs(datelineRoute.coordinate(at: datelineRoute.distance / 2).longitude) > 179.95)

        var interrupted = WalkingSession(route: route, speedKmh: 3.6, startedAt: 0)!
        interrupted.advance(to: 3)
        interrupted.advance(to: 12)
        assert(interrupted.phase == .interrupted && approximatelyEqual(interrupted.distanceTraveled, 3))
        var invalidTime = WalkingSession(route: route, speedKmh: 3.6, startedAt: 0)!
        invalidTime.advance(to: .nan)
        assert(invalidTime.phase == .interrupted && invalidTime.distanceTraveled == 0)
        var reversedTime = WalkingSession(route: route, speedKmh: 3.6, startedAt: 0)!
        reversedTime.advance(to: 2)
        reversedTime.advance(to: 1)
        assert(reversedTime.phase == .interrupted && approximatelyEqual(reversedTime.distanceTraveled, 2))

        print("PASS: walking route interpolation, timing, pause/resume, arrival, invalid inputs, dateline and interruption")
    }
}
