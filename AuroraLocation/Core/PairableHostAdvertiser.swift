// Derived in part from Locus, Copyright (c) 2026 Locus contributors, MIT.
import Foundation
import Network

@MainActor
final class PairableHostAdvertiser {
    private var listener: NWListener?
    private var relay: PairRelay?

    func publish(port: UInt16, identifier: String, name: String, model: String,
                 authTag: String, version: String, minimumVersion: String,
                 failure: @escaping () -> Void) {
        stop()
        var txt = NWTXTRecord()
        txt["name"] = name
        txt["identifier"] = identifier
        txt["authTag"] = authTag
        txt["model"] = model
        txt["flags"] = "1"
        txt["ver"] = version
        txt["minVer"] = minimumVersion
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: identifier,
                type: "_remotepairing-pairable-host._tcp", domain: "local", txtRecord: txt)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    if case .failed = state { failure() }
                    if case .waiting = state { failure() }
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] incoming in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener, self.relay == nil,
                          let endpoint = NWEndpoint.Port(rawValue: port) else { incoming.cancel(); return }
                    let outgoing = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
                    let relay = PairRelay(incoming: incoming, outgoing: outgoing, failure: failure)
                    self.relay = relay
                    relay.start()
                }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch { failure() }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        relay?.cancel()
        relay = nil
    }
}

// Network.framework callbacks and ownership stay on the main queue; IO itself is asynchronous.
private final class PairRelay {
    private let incoming: NWConnection
    private let outgoing: NWConnection
    private let failure: () -> Void
    private var stopped = false

    init(incoming: NWConnection, outgoing: NWConnection, failure: @escaping () -> Void) {
        self.incoming = incoming
        self.outgoing = outgoing
        self.failure = failure
    }

    func start() {
        incoming.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.fail() }
        }
        outgoing.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.pump(from: self.incoming, to: self.outgoing)
                self.pump(from: self.outgoing, to: self.incoming)
            case .failed: self.fail()
            default: break
            }
        }
        incoming.start(queue: .main)
        outgoing.start(queue: .main)
    }

    func cancel() {
        guard !stopped else { return }
        stopped = true
        incoming.stateUpdateHandler = nil
        outgoing.stateUpdateHandler = nil
        incoming.cancel()
        outgoing.cancel()
    }

    private func fail() {
        guard !stopped else { return }
        cancel()
        failure()
    }

    private func pump(from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { return }
            guard error == nil else { self.fail(); return }
            to.send(content: data, isComplete: complete, completion: .contentProcessed { [weak self] error in
                guard let self, !self.stopped else { return }
                if error != nil { self.fail(); return }
                if !complete { self.pump(from: from, to: to) }
                // A clean FIN may follow successful SRP. Rust decides pairing success.
            })
        }
    }
}
