import Foundation

@main struct AuroraVPNCheck {
    static func main() {
        var request = AuroraVPN.Request(id: UUID(uuidString: "D08F0841-62D0-4D1F-BA89-52765B966BB1")!, now: 0)
        assert(request.url.absoluteString == "auroravpn://connect?request=D08F0841-62D0-4D1F-BA89-52765B966BB1")
        let callback = URL(string: "auroralocation-vpn://callback?request=\(request.id.uuidString)&result=ready")!
        assert(request.consume(URL(string: callback.absoluteString + "&result=ready")!, now: 1) == nil)
        assert(request.consume(URL(string: callback.absoluteString.replacingOccurrences(of: "callback?", with: "callback/path?"))!, now: 1) == nil)
        assert(request.consume(URL(string: callback.absoluteString + "&lat=1")!, now: 1) == nil)
        assert(request.consume(URL(string: callback.absoluteString.replacingOccurrences(of: "auroralocation-vpn", with: "auroralocation"))!, now: 1) == nil)
        assert(request.consume(URL(string: callback.absoluteString.replacingOccurrences(of: request.id.uuidString, with: UUID().uuidString))!, now: 1) == nil)
        assert(request.consume(callback, now: 181) == nil)
        assert(request.consume(URL(string: callback.absoluteString.lowercased())!, now: 180) == .ready)
        assert(request.consume(callback, now: 180) == nil)
        for result in ["cancel", "error"] {
            var next = AuroraVPN.Request(now: 0)
            let reply = URL(string: "auroralocation-vpn://callback?request=\(next.id.uuidString)&result=\(result)")!
            assert(next.consume(reply, now: 1)?.rawValue == result)
        }
        print("PASS: Aurora VPN callback URL, expiry and replay validation")
    }
}
