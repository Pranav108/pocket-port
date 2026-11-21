import Foundation
import Combine
import PocketPortProtocol

enum ImportFailure: Equatable {
    case invalidQR, transfer(TransferError), storage

    var message: String {
        switch self {
        case .invalidQR: return "This QR code isn’t a PocketPort link."
        case .storage: return "Couldn’t save this file on your iPhone. Check available storage and retry."
        case .transfer(.expired): return "This share link expired. Run pocket-port again and scan the new code."
        case .transfer(.unavailable): return "This share is no longer available. Scan a fresh code."
        case .transfer(.localNetworkDenied): return "Allow Local Network access so PocketPort can reach your Mac."
        case .transfer(.unreachable): return "Couldn’t reach your Mac. Check that both devices are on the same Wi-Fi and the helper is running."
        case .transfer(.incomplete): return "The download didn’t finish or couldn’t be verified."
        }
    }

    var canRetry: Bool {
        switch self {
        case .invalidQR, .transfer(.expired), .transfer(.unavailable): return false
        default: return true
        }
    }
}

@MainActor
final class ImportCoordinator: ObservableObject {
    enum Phase: Equatable {
        case scanning, downloading, saving, committed(ImportRecord), failed(ImportFailure)
    }
    @Published private(set) var phase = Phase.scanning
    let store: ImportStore
    private let transfer: any ShareTransferring
    private var operation: Task<Void, Never>?
    private var lastLink: ShareLink?
    private var generation = UUID()

    init(store: ImportStore, transfer: any ShareTransferring) {
        self.store = store
        self.transfer = transfer
    }

    func reset() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        lastLink = nil
        phase = .scanning
    }

    func scan(_ value: String) {
        guard phase == .scanning else { return }
        guard let link = try? ShareLink(scannedValue: value) else {
            phase = .failed(.invalidQR)
            return
        }
        start(link)
    }

    func retry() {
        guard case .failed(let error) = phase, error.canRetry, let lastLink else { return }
        start(lastLink)
    }

    private func start(_ link: ShareLink) {
        lastLink = link
        guard !link.isExpired(at: Date(), allowingClockSkew: true) else {
            phase = .failed(.transfer(.expired))
            return
        }
        let current = generation
        phase = .downloading
        operation = Task {
            do {
                let record: ImportRecord
                if let saved = try await store.existing(id: link.shareID) {
                    try Task.checkCancellation()
                    record = saved
                } else {
                    let downloaded = try await transfer.download(link)
                    try Task.checkCancellation()
                    phase = .saving
                    record = try await store.commit(downloaded, shareID: link.shareID)
                }
                if generation == current { phase = .committed(record) }
                Task { [transfer] in
                    do { try await transfer.acknowledge(link) }
                    catch TransferError.expired { }
                    catch TransferError.unavailable { }
                    catch {
                        if !link.isExpired(at: Date()) { try? await transfer.acknowledge(link) }
                    }
                }
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                if let error = error as? TransferError { phase = .failed(.transfer(error)) }
                else if error is CancellationError { phase = .scanning }
                else { phase = .failed(.storage) }
            }
        }
    }
}
