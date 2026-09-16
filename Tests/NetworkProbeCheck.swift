import Network
import Foundation

@main
struct NetworkProbeCheck {
    static func main() async {
        assert(NetworkStatus.errorCode(.posix(.ENETDOWN)) == "posix=50")
        assert(NetworkStatus.errorCode(.posix(.ECONNREFUSED)) == "posix=61")
        assert(NetworkStatus.errorCode(.dns(-65554)) == "dns=-65554")
        assert(NetworkStatus.errorCode(.tls(-9807)) == "tls=-9807")
        assert(NetworkStatus.proxyStatus(Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8)) == 200)
        assert(NetworkStatus.proxyStatus(Data("HTTP/1.0 502 Bad Gateway\r\n\r\n".utf8)) == 502)
        assert(NetworkStatus.proxyStatus(Data("HTTP/1.1 20".utf8)) == nil)
        assert(NetworkStatus.proxyStatus(Data("NOTHTTP 200 OK\r\n".utf8)) == nil)
        assert(NetworkStatus.proxyStatus(Data("HTTP/1.1 +20 OK\r\n".utf8)) == nil)
        let echo = await NetworkStatus.probeLoopback(host: "127.0.0.1")
        assert(echo.reachable, echo.details)
        assert(echo.details.contains("accepted=true verified=true"), echo.details)
        let restricted = await NetworkStatus.probeLoopback(host: "127.0.0.1", restrictListener: true)
        assert(!restricted.reachable, restricted.details)
        assert(restricted.details.contains("accepted=false verified=false"), restricted.details)
        if CommandLine.arguments.contains("--peer") {
            let started = Date()
            let peer = await NetworkStatus.probeLoopback(peerToPeer: true)
            assert(Date().timeIntervalSince(started) < 15, peer.details)
            if peer.reachable {
                assert(peer.details.contains("accepted=true verified=true"), peer.details)
                assert(peer.details.contains("clientPath=awdl0"), peer.details)
                assert(peer.details.contains("serverPath=awdl0"), peer.details)
            }
            print("P2P probe: \(peer.details)")
        }
        print("PASS: restricted listener rejects loopback while unrestricted echo succeeds")
        print("PASS: real local TCP challenge and response, bounded listener cleanup")
        print("PASS: probe errors preserve domain and code without peer descriptions")
    }
}
