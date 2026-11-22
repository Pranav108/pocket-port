import PocketPortProtocol
import SwiftUI

struct PairedComputersView: View {
    @ObservedObject var model: DirectReceivingModel
    @State private var adding = false
    @State private var renaming: TrustedDevice?
    @State private var removing: TrustedDevice?
    @State private var alias = ""

    var body: some View {
        Form {
            Section {
                Label(model.readiness, systemImage: "wifi")
                Button("Retry Wi-Fi Receiver", action: model.retryReceiving)
            } header: { Text("Receiving") }
            Section("Trusted Computers") {
                ForEach(model.devices) { computer in
                    Menu {
                        Button("Rename Alias") { alias = computer.alias; renaming = computer }
                        Button("Remove Computer", role: .destructive) { removing = computer }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(computer.identity.name)
                                .foregroundStyle(.primary)
                            Text("\(computer.alias) · \(computer.identity.fingerprint)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Add Computer", systemImage: "plus") { adding = true }
            }
        }
        .navigationTitle("Paired Computers")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.refreshSettings() }
        .sheet(isPresented: $adding) { AddComputerView(model: model) }
        .alert("Rename computer alias", isPresented: presence($renaming), presenting: renaming) { computer in
            TextField("Alias", text: $alias)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save") { model.rename(computer, to: alias) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Remove trusted computer?", isPresented: presence($removing), presenting: removing) { computer in
            Button("Remove", role: .destructive) { model.remove(computer) }
            Button("Cancel", role: .cancel) {}
        } message: { computer in
            Text("\(computer.identity.name) will need to pair again before it can send files.")
        }
        .alert("Paired Computers", isPresented: Binding(
            get: { model.settingsError != nil }, set: { if !$0 { model.clearSettingsError() } }
        )) {
            Button("OK", role: .cancel, action: model.clearSettingsError)
        } message: { Text(model.settingsError ?? "") }
    }

    private func presence<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

private struct AddComputerView: View {
    @ObservedObject var model: DirectReceivingModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var services: [LocalDiscovery.Service] = []
    @State private var selected: LocalDiscovery.Service?
    @State private var code = ""
    @State private var searching = false
    @State private var error: String?
    @State private var pairing: Task<Void, Never>?
    @State private var approval: Approval?
    @State private var refresh = UUID()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("On your Mac, run `pocket-port pair`. Select the Mac below and enter the six-digit code shown in Terminal.")
                }
                Section("Nearby Macs") {
                    if searching { ProgressView("Looking for Macs…") }
                    if !searching && services.isEmpty {
                        Text("No Macs found. Check Wi-Fi and Local Network access, and make sure the pairing command is still running.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(services) { service in
                        Button {
                            selected = service
                        } label: {
                            HStack {
                                Text(service.name).foregroundStyle(.primary)
                                Spacer()
                                if selected?.id == service.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    Button("Search Again") { refresh = UUID() }.disabled(searching)
                }
                .disabled(pairing != nil)
                if let selected {
                    Section("Verification Code") {
                        TextField("Six-digit code", text: $code)
                            .keyboardType(.asciiCapableNumberPad)
                            .textContentType(.oneTimeCode)
                        Button("Verify Computer") { startPairing(selected) }
                            .disabled((try? PairVerification.normalize(code)) == nil)
                    }
                    .disabled(pairing != nil)
                }
                if pairing != nil { ProgressView("Verifying computer…") }
                if let error { Section { Text(error).foregroundStyle(.secondary) } }
            }
            .navigationTitle("Add Computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancel(); dismiss() } } }
            .task(id: refresh) { await discover() }
            .onDisappear(perform: cancel)
            .onChange(of: scenePhase) { _, phase in if phase == .background { cancel() } }
            .alert("Trust this computer?", isPresented: Binding(
                get: { approval != nil }, set: { _ in }
            ), presenting: approval) { _ in
                Button("Trust Computer") { finishApproval(true) }
                Button("Cancel", role: .cancel) { finishApproval(false) }
            } message: { pending in
                Text("\(pending.identity.name) · \(pending.identity.fingerprint)\nConfirm the fingerprint matches the one in Terminal.")
            }
        }
        .interactiveDismissDisabled(approval != nil)
    }

    private func discover() async {
        searching = true
        selected = nil
        error = nil
        defer { searching = false }
        do { services = try await LocalDiscovery.browse(type: LocalDiscovery.pairing) }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func startPairing(_ service: LocalDiscovery.Service) {
        error = nil
        pairing = Task {
            defer { pairing = nil }
            do {
                try await model.pair(service: service, code: code) { identity in await confirm(identity) }
                dismiss()
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func confirm(_ identity: DirectIdentity) async -> Bool {
        if Task.isCancelled { return false }
        return await withCheckedContinuation { continuation in
            let id = UUID()
            let timer = Task {
                try? await Task.sleep(for: .seconds(32))
                if !Task.isCancelled, approval?.id == id { finishApproval(false) }
            }
            approval = Approval(id: id, identity: identity, continuation: continuation, timer: timer)
        }
    }

    private func finishApproval(_ accepted: Bool) {
        guard let pending = approval else { return }
        approval = nil
        pending.timer.cancel()
        pending.continuation.resume(returning: accepted)
    }

    private func cancel() {
        pairing?.cancel()
        finishApproval(false)
    }

    private struct Approval {
        let id: UUID
        let identity: DirectIdentity
        let continuation: CheckedContinuation<Bool, Never>
        let timer: Task<Void, Never>
    }
}

struct DirectTransferNotice: View {
    let activity: DirectReceivingModel.Activity
    let dismiss: () -> Void

    var body: some View {
        HStack {
            switch activity {
            case .receiving(let name, let received, let total):
                if total > 0 { ProgressView("Receiving \(name)", value: Double(received), total: Double(total)) }
                else { ProgressView("Receiving \(name)") }
            case .saving(let name):
                ProgressView("Saving \(name)")
            case .saved(let name):
                Label("Saved offline · \(name)", systemImage: "checkmark.circle")
                close
            case .failed(let detail):
                Label(detail, systemImage: "exclamationmark.triangle")
                close
            }
        }
        .font(.subheadline)
        .padding(.vertical, 10)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    private var close: some View {
        Button("Dismiss", systemImage: "xmark", action: dismiss)
            .labelStyle(.iconOnly)
    }
}
