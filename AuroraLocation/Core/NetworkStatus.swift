import Foundation
import Network

enum NetworkStatus {
    static let tunnelIP = "10.7.0.1"

    struct ProbeResult: Sendable {
        let reachable: Bool
        let details: String
    }

    static func errorCode(_ error: NWError) -> String {
        // Keep diagnostics independent of localized descriptions or peer data.
        switch error {
        case .posix(let code): return "posix=\(code.rawValue)"
        case .dns(let code): return "dns=\(code)"
        case .tls(let code): return "tls=\(code)"
        default: return "unknown"
        }
    }

    static var hasWiFiAddress: Bool {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return false }
        defer { freeifaddrs(addresses) }
        var current = addresses
        while let entry = current {
            let item = entry.pointee
            if String(cString: item.ifa_name) == "en0",
               item.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
               let address = item.ifa_addr,
               address.pointee.sa_family == sa_family_t(AF_INET) ||
                address.pointee.sa_family == sa_family_t(AF_INET6) {
                return true
            }
            current = item.ifa_next
        }
        return false
    }

    static var interfaceSummary: String {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return "unavailable" }
        defer { freeifaddrs(addresses) }
        var current = addresses
        var entries = Set<String>()
        while let entry = current {
            let item = entry.pointee
            if let address = item.ifa_addr,
               address.pointee.sa_family == sa_family_t(AF_INET) || address.pointee.sa_family == sa_family_t(AF_INET6) {
                let family = address.pointee.sa_family == sa_family_t(AF_INET) ? "v4" : "v6"
                entries.insert("\(String(cString: item.ifa_name)):\(family):flags=\(item.ifa_flags)")
            }
            current = item.ifa_next
        }
        // Interface names and families are enough to compare paths without recording IP addresses.
        return entries.sorted().joined(separator: ",")
    }

    static func probeTunnel(viaLocalProxy: Bool = false) async -> ProbeResult {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(viaLocalProxy ? "127.0.0.1" : tunnelIP),
                                          port: viaLocalProxy ? 1082 : 49152, using: .tcp)
            let queue = DispatchQueue(label: "com.auroraleelabs.AuroraLocation.probe")
            // All completion paths run on this queue, so the continuation resumes once.
            var completed = false
            var states: [String] = []
            let recordState: (String) -> Void = { states.append($0) }
            let finish: (Bool, String) -> Void = { reachable, outcome in
                guard !completed else { return }
                completed = true
                let path = connection.currentPath
                let interfaces: [(NWInterface.InterfaceType, String)] = [
                    (.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "wired"),
                    (.loopback, "loopback"), (.other, "other")
                ]
                let used = interfaces.filter { path?.usesInterfaceType($0.0) == true }.map(\.1)
                let route = path.map {
                    "path=\($0.status), reason=\($0.unsatisfiedReason), interfaces=\(used.joined(separator: "+"))"
                } ?? "path=none"
                let details = "\(outcome), \(states.suffix(6).joined(separator: " > ")), \(route)"
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: ProbeResult(reachable: reachable, details: details))
            }
            var response = Data()
            func receiveProxyResponse() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, ended, error in
                    guard !completed else { return }
                    if let data { response.append(data) }
                    guard response.count <= 4096 else { finish(false, "proxy=headers-too-large"); return }
                    if response.range(of: Data("\r\n\r\n".utf8)) != nil {
                        guard let status = proxyStatus(response) else { finish(false, "proxy=invalid-response"); return }
                        finish((200...299).contains(status), "proxy=http-\(status)")
                    } else if let error {
                        finish(false, "proxy=receive(\(errorCode(error)))")
                    } else if ended {
                        finish(false, "proxy=eof-before-headers")
                    } else {
                        receiveProxyResponse()
                    }
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .preparing: recordState("preparing")
                case .waiting(let error): recordState("waiting(\(errorCode(error)))")
                case .ready:
                    guard viaLocalProxy else { finish(true, "ready"); return }
                    recordState("proxy-tcp-ready")
                    // This diagnostic sends only CONNECT headers, never pairing credentials.
                    let request = Data("CONNECT 10.7.0.1:49152 HTTP/1.1\r\nHost: 10.7.0.1:49152\r\n\r\n".utf8)
                    connection.send(content: request, completion: .contentProcessed { error in
                        guard !completed else { return }
                        if let error { finish(false, "proxy=send(\(errorCode(error)))"); return }
                        recordState("proxy-request-sent")
                        receiveProxyResponse()
                    })
                case .failed(let error): finish(false, "failed(\(errorCode(error)))")
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 4) { finish(false, "timeout=4s") }
        }
    }

    static func proxyStatus(_ response: Data) -> Int? {
        guard let end = response.range(of: Data("\r\n".utf8)),
              let line = String(data: response[..<end.lowerBound], encoding: .ascii) else { return nil }
        let fields = line.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count >= 3, ["HTTP/1.0", "HTTP/1.1"].contains(fields[0]),
              fields[1].utf8.count == 3, fields[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let code = Int(fields[1]), (100...599).contains(code) else { return nil }
        return code
    }

    #if DEBUG
    // All fields are confined to the probe's serial queue, including timeout and cleanup.
    private final class EchoState: @unchecked Sendable {
        var finished = false
        var accepted = false
        var verified = false
        var clientStarted = false
        var connections: [NWConnection] = []
        var clientState = "none"
        var port: UInt16 = 0
        var browser: NWBrowser?
        var discoveredInterfaces = Set<String>()
        var clientPath = "none"
        var serverPath = "none"
        var clientUsesPeer = false
        var serverUsesPeer = false
    }

    // A bounded, non-privileged echo distinguishes routing from developer-service rejection.
    static func probeLoopback(host: String = tunnelIP, restrictListener: Bool = false, peerToPeer: Bool = false) async -> ProbeResult {
        await withCheckedContinuation { continuation in
            let parameters = NWParameters.tcp
            // Match the interface exclusions observed on the device's developer service.
            if restrictListener || peerToPeer { parameters.prohibitedInterfaceTypes = [.cellular, .loopback] }
            parameters.includePeerToPeer = peerToPeer
            let serviceName = "aurora-" + UUID().uuidString
            let listener: NWListener
            do { listener = try NWListener(using: parameters, on: .any) }
            catch { continuation.resume(returning: ProbeResult(reachable: false, details: "echo=listener-create-failed")); return }
            if peerToPeer { listener.service = NWListener.Service(name: serviceName, type: "_aurora-echo._tcp") }
            let queue = DispatchQueue(label: "com.auroraleelabs.AuroraLocation.echo")
            let challenge = Data(UUID().uuidString.utf8)
            let progress = EchoState()
            @Sendable func finish(_ success: Bool, _ outcome: String) {
                guard !progress.finished else { return }
                progress.finished = true
                listener.stateUpdateHandler = nil
                listener.newConnectionHandler = nil
                listener.cancel()
                progress.browser?.browseResultsChangedHandler = nil
                progress.browser?.stateUpdateHandler = nil
                progress.browser?.cancel()
                progress.browser = nil
                for connection in progress.connections {
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                }
                continuation.resume(returning: ProbeResult(reachable: success,
                    details: "echo=\(outcome) restricted=\(restrictListener || peerToPeer) port=\(progress.port) accepted=\(progress.accepted) verified=\(progress.verified) client=\(progress.clientState) peer=\(peerToPeer) discovered=\(progress.discoveredInterfaces.sorted().joined(separator: "+")) clientPath=\(progress.clientPath) serverPath=\(progress.serverPath)"))
            }
            listener.newConnectionHandler = { connection in
                guard !progress.finished, !progress.accepted else { connection.cancel(); return }
                progress.accepted = true
                progress.connections.append(connection)
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: challenge.count, maximumLength: challenge.count) { data, _, _, _ in
                    guard !progress.finished else { return }
                    guard data == challenge else { finish(false, "challenge-mismatch"); return }
                    progress.verified = true
                    if let path = connection.currentPath {
                        progress.serverPath = path.availableInterfaces.map(\.name).sorted().joined(separator: "+")
                        progress.serverUsesPeer = path.usesInterfaceType(.wifi) && path.availableInterfaces.contains { $0.name == "awdl0" } && !path.usesInterfaceType(.loopback) && !path.usesInterfaceType(.cellular)
                    }
                    connection.send(content: challenge, completion: .contentProcessed { error in
                        if error != nil { finish(false, "server-send-failed") }
                    })
                }
            }
            @Sendable func startClient(_ endpoint: NWEndpoint, _ clientParameters: NWParameters) {
                progress.clientStarted = true
                let client = NWConnection(to: endpoint, using: clientParameters)
                progress.connections.append(client)
                client.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        progress.clientState = "ready"
                        if let path = client.currentPath {
                            progress.clientPath = path.availableInterfaces.map(\.name).sorted().joined(separator: "+")
                            progress.clientUsesPeer = path.usesInterfaceType(.wifi) && path.availableInterfaces.contains { $0.name == "awdl0" } && !path.usesInterfaceType(.loopback) && !path.usesInterfaceType(.cellular)
                        }
                        client.send(content: challenge, completion: .contentProcessed { error in
                            guard !progress.finished else { return }
                            guard error == nil else { finish(false, "client-send-failed"); return }
                            client.receive(minimumIncompleteLength: challenge.count, maximumLength: challenge.count) { data, _, _, _ in
                                guard !progress.finished else { return }
                                let echoed = progress.verified && data == challenge
                                let peerPath = !peerToPeer || (progress.clientUsesPeer && progress.serverUsesPeer)
                                // Probe only the same local peer that answered our nonce. TCP readiness
                                // is diagnostic evidence, never a developer-protocol success result.
                                if peerToPeer, echoed,
                                   case let .hostPort(peerHost, _) = client.currentPath?.remoteEndpoint {
                                    let developer = NWConnection(host: peerHost, port: 49152, using: clientParameters)
                                    progress.connections.append(developer)
                                    developer.stateUpdateHandler = { state in
                                        guard !progress.finished else { return }
                                        switch state {
                                        case .ready: finish(false, "developer-tcp-ready")
                                        case .failed(let error): finish(false, "developer-tcp-failed(\(errorCode(error)))")
                                        case .waiting(let error): progress.clientState = "developer-waiting(\(errorCode(error)))"
                                        default: break
                                        }
                                    }
                                    developer.start(queue: queue)
                                    return
                                }
                                finish(echoed && peerPath, !echoed ? "response-mismatch" : peerPath ? "ok" : "unexpected-interface")
                            }
                        })
                    case .waiting(let error): progress.clientState = "waiting(\(errorCode(error)))"
                    case .failed(let error): progress.clientState = errorCode(error); finish(false, "client-failed")
                    default: break
                    }
                }
                client.start(queue: queue)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !progress.finished, !progress.clientStarted, let assignedPort = listener.port else { return }
                    progress.port = assignedPort.rawValue
                    // emproxy intentionally only reflects the dynamic/private TCP range.
                    guard progress.port >= 49152 else { finish(false, "port-outside-relay-range"); return }
                    if !peerToPeer {
                        startClient(.hostPort(host: NWEndpoint.Host(host), port: assignedPort), .tcp)
                        return
                    }
                    guard progress.browser == nil else { return }
                    let browseParameters = NWParameters.tcp
                    browseParameters.includePeerToPeer = true
                    let browser = NWBrowser(for: .bonjour(type: "_aurora-echo._tcp", domain: nil), using: browseParameters)
                    progress.browser = browser
                    browser.browseResultsChangedHandler = { results, _ in
                        guard !progress.finished, !progress.clientStarted else { return }
                        for result in results {
                            guard case let .service(name, type, domain, _) = result.endpoint, name == serviceName else { continue }
                            progress.discoveredInterfaces.formUnion(result.interfaces.map(\.name))
                            guard let peer = result.interfaces.first(where: { $0.name == "awdl0" }) else { continue }
                            let clientParameters = NWParameters.tcp
                            clientParameters.requiredInterface = peer
                            clientParameters.prohibitedInterfaceTypes = [.cellular, .loopback]
                            startClient(.service(name: name, type: type, domain: domain, interface: peer), clientParameters)
                            return
                        }
                    }
                    browser.stateUpdateHandler = { state in
                        if case .failed(let error) = state { finish(false, "browser-failed(\(errorCode(error)))") }
                    }
                    browser.start(queue: queue)
                case .failed(let error): finish(false, "listener-failed(\(errorCode(error)))")
                default: break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + (peerToPeer ? 12 : 6)) { finish(false, "timeout") }
        }
    }
    #endif
}
