import CoreLocation
import Foundation

enum OpenStreetMapWalkingRoute {
    enum Failure: LocalizedError, Sendable {
        case invalidCoordinate
        case rateLimited
        case network
        case serviceUnavailable
        case responseTooLarge
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidCoordinate:
                return "坐标无效, 无法规划步行路线."
            case .rateLimited:
                return "备选步行服务请求过于频繁, 请稍后重试."
            case .network:
                return "备选步行服务网络异常, 请检查网络后重试."
            case .serviceUnavailable:
                return "备选步行服务暂时不可用, 请稍后重试."
            case .responseTooLarge:
                return "备选步行服务返回的数据过大, 请调整起点或终点后重试."
            case .invalidResponse:
                return "备选步行服务未返回可用的步行路线, 请调整起点或终点后重试."
            }
        }
    }

    private static let minimumRequestInterval: Duration = .seconds(1)
    private static let maximumResponseBytes = 1_000_000
    private static let maximumCoordinateCount = 10_000
    private static let maximumSnapDistance: CLLocationDistance = 100
    private static let requestGate = RequestGate()

    static func fetch(from start: Coordinate, to end: Coordinate) async throws -> WalkingRoute {
        let request = try request(from: start, to: end)
        try Task.checkCancellation()
        try await requestGate.claim()

        let data: Data
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw Failure.serviceUnavailable
            }
            guard response.expectedContentLength < 0 || response.expectedContentLength <= maximumResponseBytes else {
                throw Failure.responseTooLarge
            }

            var collected = Data()
            collected.reserveCapacity(min(maximumResponseBytes, Int(max(0, response.expectedContentLength))))
            for try await byte in bytes {
                try Task.checkCancellation()
                guard collected.count < maximumResponseBytes else { throw Failure.responseTooLarge }
                collected.append(byte)
            }
            data = collected
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as Failure {
            throw failure
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw Failure.network
        }
        try Task.checkCancellation()
        return try decode(data, from: start, to: end)
    }

    static func request(from start: Coordinate, to end: Coordinate) throws -> URLRequest {
        guard start.isValid, end.isValid else { throw Failure.invalidCoordinate }

        let urlString = "https://routing.openstreetmap.de/routed-foot/route/v1/foot/\(coordinateString(longitude: start.longitude, latitude: start.latitude));\(coordinateString(longitude: end.longitude, latitude: end.latitude))?overview=full&geometries=geojson&steps=false&radiuses=100;100&generate_hints=false"
        guard let url = URL(string: urlString) else { throw Failure.invalidCoordinate }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("AuroraLocation/1.0 (https://github.com/AuroraNest/Aurora-Location)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func decode(_ data: Data, from start: Coordinate, to end: Coordinate) throws -> WalkingRoute {
        guard start.isValid, end.isValid else { throw Failure.invalidCoordinate }
        guard data.count <= maximumResponseBytes else { throw Failure.responseTooLarge }

        let payload: Response
        do {
            payload = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw Failure.invalidResponse
        }
        guard payload.code == "Ok",
              let geometry = payload.routes.first?.geometry,
              geometry.type == "LineString",
              geometry.coordinates.count >= 2,
              geometry.coordinates.count <= maximumCoordinateCount else {
            throw Failure.invalidResponse
        }

        let coordinates = geometry.coordinates.compactMap { position -> Coordinate? in
            guard position.count >= 2 else { return nil }
            let coordinate = Coordinate(latitude: position[1], longitude: position[0])
            return coordinate.isValid ? coordinate : nil
        }
        guard coordinates.count == geometry.coordinates.count,
              let first = coordinates.first,
              let last = coordinates.last,
              CLLocation(latitude: first.latitude, longitude: first.longitude)
                .distance(from: CLLocation(latitude: start.latitude, longitude: start.longitude)) <= maximumSnapDistance,
              CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude)) <= maximumSnapDistance,
              let route = WalkingRoute(coordinates: coordinates, source: .openStreetMap) else {
            throw Failure.invalidResponse
        }
        return route
    }

    private static func coordinateString(longitude: Double, latitude: Double) -> String {
        String(format: "%.7f,%.7f", locale: Locale(identifier: "en_US_POSIX"), longitude, latitude)
    }

    private struct Response: Decodable {
        let code: String
        let routes: [Route]
    }

    private struct Route: Decodable {
        let geometry: Geometry
    }

    private struct Geometry: Decodable {
        let type: String
        let coordinates: [[Double]]
    }

    private actor RequestGate {
        private var lastRequest: ContinuousClock.Instant?

        func claim() throws {
            let now = ContinuousClock.now
            if let lastRequest,
               lastRequest.duration(to: now) < OpenStreetMapWalkingRoute.minimumRequestInterval {
                throw Failure.rateLimited
            }
            lastRequest = now
        }
    }
}
