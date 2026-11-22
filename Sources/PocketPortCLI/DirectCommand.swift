import Darwin
import Foundation
import Network
import PocketPortProtocol

enum DirectCommand: Equatable {
    case help, pair(String?), devices, unpair(String), defaultDevice(String?), rename(String, String)
    case send(file: String?, target: String?, project: String?)

    static let helpText = """
    Usage:
      pocket-port pair [--alias <alias>]
      pocket-port devices
      pocket-port rename <alias> <new-alias>
      pocket-port unpair <alias>
      pocket-port default <alias>|--clear
      pocket-port send [--to|-t <alias[,alias...]|all>] [--project <label>] [--] [file]

    Keep PocketPort open on the receiving device and connect both devices to the same Wi-Fi.
    With no file, send uses the only eligible file in the current folder.
    """

    static func parse(_ values: [String]) throws -> Self? {
        guard let command = values.first, ["pair", "devices", "unpair", "default", "rename", "send"].contains(command) else { return nil }
        let args = Array(values.dropFirst())
        if args == ["--help"] || args == ["-h"] { return .help }
        switch command {
        case "pair":
            if args.isEmpty { return .pair(nil) }
            if args.count == 2, args.first == "--alias" { return .pair(try DeviceRegistry.validateAlias(args[1])) }
        case "devices":
            if args.isEmpty { return .devices }
        case "unpair":
            if args.count == 1 { return .unpair(args[0]) }
        case "default":
            if args.count == 1 { return .defaultDevice(args[0] == "--clear" ? nil : args[0]) }
        case "rename":
            if args.count == 2 { return .rename(args[0], args[1]) }
        case "send":
            return try parseSend(args)
        default: break
        }
        throw CLIError(helpText)
    }

    private static func parseSend(_ args: [String]) throws -> Self {
        var iterator = args.makeIterator()
        var file: String?, target: String?, project: String?
        var options = true
        while let argument = iterator.next() {
            if options, argument == "--" {
                options = false
            } else if options, argument == "-t" || argument == "--to" {
                guard target == nil, let value = iterator.next(), !value.isEmpty else {
                    throw CLIError("Supply one --to or -t value with an alias, comma-separated aliases, or all.")
                }
                target = value
            } else if options, argument == "--project" {
                guard project == nil, let value = iterator.next(), value.utf8.count <= ShareMetadata.maximumProjectBytes else {
                    throw CLIError("Supply one --project label of at most \(ShareMetadata.maximumProjectBytes) UTF-8 bytes.")
                }
                project = value
            } else {
                guard file == nil, !options || !argument.hasPrefix("-") else { throw CLIError(helpText) }
                file = argument
            }
        }
        return .send(file: file, target: target, project: project)
    }

    func run() async throws -> Int32 {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("PocketPort/PairedDevices", isDirectory: true)
        let registry = DeviceRegistryStore(directory: directory)
        switch self {
        case .help:
            print(Self.helpText)
        case .pair(let alias):
            try await pair(registry, alias: alias)
        case .devices:
            try await list(registry)
        case .unpair(let alias):
            try registry.update { try $0.remove(id: $0.device(alias: alias).id) }
            print("Unpaired \(alias).")
        case .defaultDevice(let alias):
            try registry.update { registry in
                let device = try alias.map { try registry.device(alias: $0) }
                registry.setDefault(id: device?.id)
            }
            print(alias.map { "Default device: \($0)" } ?? "Default device cleared.")
        case .rename(let old, let new):
            try registry.update { try $0.rename(id: $0.device(alias: old).id, to: new) }
            print("Renamed \(old) to \(new.lowercased()).")
        case .send(let file, let target, let project):
            let snapshot: FileSnapshot
            if let file { snapshot = try FileSnapshot.load(path: file, projectLabel: project) }
            else {
                let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                snapshot = try FileSnapshot.loadOnlyShareableFile(in: cwd, projectLabel: project)
            }
            return try await send(snapshot, to: target, registry: registry)
        }
        return 0
    }

    private func credentials(_ store: DeviceRegistryStore) throws -> DeviceCredentials {
        try store.credentials(name: Host.current().localizedName ?? "Mac", platform: "macOS")
    }

    private func pair(_ store: DeviceRegistryStore, alias: String?) async throws {
        let local = try credentials(store)
        let lock = open(store.directory.appendingPathComponent("pairing.lock").path, O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_RDWR, 0o600)
        guard lock >= 0 else { throw CLIError("Could not start a pairing session.") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw CLIError("Pairing is already open in another Terminal window.") }

        let advertised = String(String.UnicodeScalarView(local.identity.name.unicodeScalars.prefix(12))) + " " + String(local.identity.fingerprint.prefix(6))
        let listener = try DirectListener(name: advertised, type: LocalDiscovery.pairing)
        defer { listener.close() }
        try await listener.start()
        let code = PairVerification.makeCode()
        let deadline = ContinuousClock.now.advanced(by: .seconds(PairVerification.lifetime))
        let timer = Task {
            try await Task.sleep(until: deadline, clock: .continuous)
            listener.close()
        }
        defer { timer.cancel() }
        print("PocketPort Pairing")
        print("Code: \(code.prefix(3))-\(code.suffix(3))")
        print("Expires in 2 minutes · Mac fingerprint: \(local.identity.fingerprint)")
        print("On your phone, open PocketPort → Settings → Paired Computers → Add Computer.")
        print("Select \(advertised) and enter the code. Press Ctrl-C to cancel.")
        fflush(stdout)

        var attempts = 0
        for await connection in listener.connections {
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
            let socket = listener.accept(connection, timeout: max(0, min(seconds, 50)))
            defer { socket.close() }
            guard seconds > 0, attempts < PairVerification.maxAttempts else { break }
            attempts += 1
            do {
                try await socket.start()
                let phone = try await PairVerification.pairAsMac(socket: socket, code: code, credentials: local) { phone in
                    guard ContinuousClock.now < deadline else { throw DirectError.timeout }
                    do { _ = try store.update { try $0.pair(phone, alias: alias) } }
                    catch { throw PairRegistryError(underlying: error) }
                }
                guard let device = try store.load().devices.first(where: { $0.id == phone.id }) else { throw DirectError.authentication }
                print("✓ Device paired successfully")
                print("Name: \(Command.displayText(device.identity.name))")
                print("Alias: \(device.alias)")
                print("Platform: \(device.identity.platform)")
                return
            } catch let error as PairRegistryError {
                throw error.underlying
            } catch {
                if attempts >= PairVerification.maxAttempts { throw CLIError("Too many pairing attempts. Run pocketport pair to generate a new code.") }
                print("Pairing attempt did not complete. Check the code and try again.")
                fflush(stdout)
            }
        }
        throw CLIError("The pairing window closed. Run pocketport pair to get a new code.")
    }

    private func list(_ store: DeviceRegistryStore) async throws {
        let registry = try store.load()
        print("ALIAS\tPLATFORM\tSTATUS\tNAME")
        if registry.devices.isEmpty {
            print("No paired devices. Run pocketport pair.")
            return
        }
        let local = try credentials(store)
        let candidates: [LocalDiscovery.Service]
        do { candidates = try await services(for: registry.devices) }
        catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            candidates = []
        }
        let online = await withTaskGroup(of: String?.self, returning: Set<String>.self) { group in
            for device in registry.devices {
                group.addTask {
                    do {
                        let socket = try await connect(device, credentials: local, services: candidates, timeout: 5)
                        defer { socket.close() }
                        try await DirectFileWire.ping(socket)
                        return device.id
                    } catch { return nil }
                }
            }
            var seen = Set<String>()
            for await id in group { if let id { seen.insert(id) } }
            return seen
        }
        if !online.isEmpty { try store.update { db in for id in online { db.seen(id: id) } } }
        for device in registry.devices {
            let status = online.contains(device.id) ? "Online" : "Offline"
            let label = device.alias + (registry.defaultID == device.id ? " (default)" : "")
            print("\(label)\t\(device.identity.platform)\t\(status)\t\(Command.displayText(device.identity.name))")
        }
    }

    private func send(_ snapshot: FileSnapshot, to aliases: String?, registry store: DeviceRegistryStore) async throws -> Int32 {
        let registry = try store.load()
        let targets: [TrustedDevice]
        if let selected = try registry.targets(aliases) { targets = selected }
        else { targets = [try interactiveDevice(registry.devices)] }
        let local = try credentials(store)
        let discovery: Result<[LocalDiscovery.Service], any Error>
        do { discovery = .success(try await services(for: targets)) }
        catch { discovery = .failure(error) }
        let contentID = ShareMetadata.digest(of: Data([snapshot.metadata.filename, snapshot.metadata.project ?? "",
                                                    snapshot.metadata.sha256].joined(separator: "\u{0}").utf8))
        let awake = try PowerAssertion()
        defer { withExtendedLifetime(awake) {} }
        var failures = 0
        for device in targets {
            do {
                let socket = try await connect(device, credentials: local, services: discovery.get(), timeout: 100)
                defer { socket.close() }
                let id = try store.update { try $0.transferID(deviceID: device.id, contentID: contentID) }
                let offer = DirectOffer(id: id, metadata: snapshot.metadata, byteCount: snapshot.bytes.count)
                let size = ByteCountFormatter.string(fromByteCount: Int64(snapshot.bytes.count), countStyle: .file)
                print("\(device.alias): Sharing \(Command.displayText(snapshot.metadata.filename)) (\(size))")
                fflush(stdout)
                var marker = 0
                let interactive = isatty(STDOUT_FILENO) == 1
                try await DirectFileWire.send(snapshot.bytes, offer: offer, over: socket) { sent in
                    let percent = sent * 100 / snapshot.bytes.count
                    if interactive, percent >= marker {
                        print("\r\(device.alias): \(percent)% handed to the connection", terminator: percent == 100 ? "\n" : "")
                        fflush(stdout)
                        marker = min(100, percent + 5)
                    }
                }
                print("✓ \(device.alias): Saved on device.")
                do { try store.update { $0.finish(deviceID: device.id, id: id) } }
                catch { print("\(device.alias): The receipt was verified, but the local retry record could not be cleared.") }
            } catch {
                failures += 1
                print("\(device.alias): Transfer not confirmed. \(error.localizedDescription)")
            }
        }
        if targets.count > 1 { print("Saved on \(targets.count - failures) of \(targets.count) devices.") }
        return failures == 0 ? 0 : 1
    }

    private func interactiveDevice(_ devices: [TrustedDevice]) throws -> TrustedDevice {
        guard isatty(STDIN_FILENO) == 1 else {
            throw CLIError("Several devices are paired. Specify --to <alias> or set a default device.")
        }
        for (index, device) in devices.enumerated() {
            print("\(index + 1)) \(device.alias) · \(Command.displayText(device.identity.name))")
        }
        print("Select a device: ", terminator: "")
        fflush(stdout)
        guard let line = readLine(), let index = Int(line), (1...devices.count).contains(index) else {
            throw DirectError.cancelled
        }
        return devices[index - 1]
    }

    private func services(for targets: [TrustedDevice]) async throws -> [LocalDiscovery.Service] {
        try await LocalDiscovery.browse(type: LocalDiscovery.receiving, names: Set(targets.map(\.identity.serviceName)))
    }

    private func connect(_ device: TrustedDevice, credentials: DeviceCredentials,
                         services: [LocalDiscovery.Service], timeout: TimeInterval) async throws -> DirectSocket {
        var failure = DirectError.offline as Error
        let tls = DirectTLS(credentials: credentials, trustedIDs: [device.id])
        for service in services where service.name == device.identity.serviceName || service.name.hasPrefix(device.identity.serviceName + " (") {
            let socket = DirectSocket(endpoint: service.endpoint, tls: tls, timeout: timeout)
            do {
                try await socket.start(handshakeTimeout: 5)
                guard try socket.peerID() == device.id else { throw DirectError.authentication }
                return socket
            } catch {
                socket.close()
                failure = error
            }
        }
        throw failure
    }
}

private struct PairRegistryError: Error {
    let underlying: any Error
}
