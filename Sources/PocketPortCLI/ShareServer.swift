import Foundation
import Network
import PocketPortProtocol

// All listener, child, timer and session callbacks execute on this queue.
final class ShareServer {
    let queue = DispatchQueue(label: "PocketPort.listener")
    private let listener: NWListener
    private var session: Session?
    private var initialSnapshot: FileSnapshot?
    private var children = [ObjectIdentifier: NWConnection]()
    private var reading = Set<ObjectIdentifier>()
    private var ackChildren = Set<ObjectIdentifier>()
    private var stopped = false
    private let shareID: UUID
    private let token: String
    private let host: String
    var onReady: ((ShareLink) throws -> Void)?
    var onStop: ((String, Int32) -> Void)?

    init(host: String, snapshot: FileSnapshot, shareID: UUID = UUID(), token: String = ShareLink.generateToken()) throws {
        self.shareID = shareID
        self.token = token
        self.host = host
        self.initialSnapshot = snapshot
        // No interface or IP version constraint: Network.framework opens a wildcard listener.
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !stopped else { return }
            switch state {
            case .ready:
                guard let snapshot = initialSnapshot, let port = listener.port else { return }
                initialSnapshot = nil
                do {
                    let lifetime = Int(ShareLink.lifetimeSeconds)
                    let deadline = DispatchTime.now() + .seconds(lifetime)
                    let link = try ShareLink(host: host, port: Int(port.rawValue), shareID: shareID,
                        token: token, expiresAtUnixSeconds: Int64(Date().timeIntervalSince1970) + Int64(lifetime))
                    session = Session(link: link, snapshot: snapshot, deadline: deadline)
                    try onReady?(link)
                    queue.asyncAfter(deadline: deadline) { [weak self] in
                        guard let self, session?.acknowledged != true else { return }
                        stop("Share expired.", code: 0)
                    }
                } catch { stop(error.localizedDescription, code: 1) }
            case .failed(let error): stop("Cannot listen for connections: \(error.localizedDescription)", code: 1)
            case .waiting(let error): stop("Listener unavailable: \(error.localizedDescription)", code: 1)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] child in self?.accept(child) }
        listener.start(queue: queue)
    }

    private func accept(_ child: NWConnection) {
        guard !stopped, session != nil, children.count < 32 else { child.cancel(); return }
        let id = ObjectIdentifier(child)
        children[id] = child
        reading.insert(id)
        child.stateUpdateHandler = { [weak self, weak child] state in
            if case .failed = state, let self, let child, children[id] === child { close(id) }
        }
        child.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak child] in
            if let self, let child, children[id] === child, reading.contains(id) { close(id) }
        }
        receive(child, previous: Data())
    }

    private func receive(_ child: NWConnection, previous: Data) {
        let id = ObjectIdentifier(child)
        child.receive(minimumIncompleteLength: 1, maximumLength: Request.maximumBytes + 1 - previous.count) { [weak self, weak child] bytes, _, eof, error in
            guard let self, let child, children[id] === child else { return }
            guard error == nil else { close(id); return }
            var input = previous
            if let bytes { input.append(bytes) }
            do {
                if let request = try Request.parse(input), let reply = session?.respond(request, now: .now()) {
                    if reply.status == 204 {
                        if ackChildren.isEmpty {
                            // Keep other pending requests available for duplicate ACKs. Cancel active downloads.
                            for downloading in downloads { close(downloading) }
                            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.stop("Saved on iPhone.", code: 0) }
                        }
                        ackChildren.insert(id)
                    }
                    send(reply, to: child)
                } else if eof { close(id) }
                else { receive(child, previous: input) }
            } catch { send(Reply(status: 400), to: child) }
        }
    }

    private var downloads = Set<ObjectIdentifier>()
    private func send(_ reply: Reply, to child: NWConnection) {
        let id = ObjectIdentifier(child)
        reading.remove(id)
        if reply.status == 200 { downloads.insert(id) }
        child.send(content: reply.head, contentContext: reply.bytes.isEmpty ? .finalMessage : .defaultMessage, isComplete: true, completion: .contentProcessed { [weak self, weak child] error in
            guard let self, let child, children[id] === child else { return }
            guard error == nil else { close(id); return }
            if reply.bytes.isEmpty { drain(child); return }
            sendBody(reply.bytes, offset: 0, to: child)
        })
    }

    private func sendBody(_ bytes: Data, offset: Int, to child: NWConnection) {
        let id = ObjectIdentifier(child)
        guard children[id] === child, let session, !session.acknowledged, DispatchTime.now() < session.deadline else {
            close(id)
            return
        }
        let end = min(offset + 64 * 1024, bytes.count)
        let final = end == bytes.count
        child.send(content: bytes[offset..<end], contentContext: final ? .finalMessage : .defaultMessage,
                   isComplete: true, completion: .contentProcessed { [weak self, weak child] error in
            guard let self, let child, children[id] === child else { return }
            guard error == nil else { close(id); return }
            if final { drain(child); return }
            #if DEBUG
            if ProcessInfo.processInfo.environment["POCKETPORT_SLOW_TRANSFER"] == "1" {
                queue.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self, weak child] in
                    if let child { self?.sendBody(bytes, offset: end, to: child) }
                }
                return
            }
            #endif
            sendBody(bytes, offset: end, to: child)
        })
    }

    // A processed send can still have bytes in the kernel. Keep the write-half closed
    // while waiting for the peer to finish. A silent peer cannot hold a slot indefinitely.
    private func drain(_ child: NWConnection) {
        let id = ObjectIdentifier(child)
        queue.asyncAfter(deadline: .now() + 2) { [weak self, weak child] in
            if let self, let child, children[id] === child { close(id) }
        }
        child.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self, weak child] _, _, eof, error in
            guard let self, let child, children[id] === child else { return }
            if eof || error != nil { close(id) }
        }
    }

    private func close(_ id: ObjectIdentifier) {
        children.removeValue(forKey: id)?.cancel()
        downloads.remove(id)
        reading.remove(id)
        if ackChildren.remove(id) != nil, ackChildren.isEmpty { stop("Saved on iPhone.", code: 0) }
    }

    func requestStop() { queue.async { self.stop("Share stopped.", code: 0) } }

    func stop(_ message: String, code: Int32) {
        guard !stopped else { return }
        stopped = true
        session = nil
        initialSnapshot = nil
        listener.cancel()
        for child in children.values { child.cancel() }
        children.removeAll()
        onStop?(message, code)
    }
}
