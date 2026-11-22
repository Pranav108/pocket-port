import PocketPortProtocol
import SwiftUI
import UIKit

struct ImportedFilesView: View {
    @ObservedObject var coordinator: ImportCoordinator
    @ObservedObject var wifi: WiFiAvailability
    @ObservedObject var direct: DirectReceivingModel
    @Environment(\.scenePhase) private var scenePhase
    let fixturesEnabled: Bool
    @AppStorage("confirmBeforeDeleting") private var confirmBeforeDeleting = true
    @State private var files: [ImportRecord] = []
    @State private var unavailable = false
    @State private var scanning = false
    @State private var showingWiFiRequired = false
    @State private var scannerLostWiFi = false
    @State private var showingSettings = false
    @State private var showingFilters = false
    @State private var path: [UUID] = []
    @State private var savedID: UUID?
    @State private var query = ""
    @State private var filter = FileFilter()
    @State private var pendingDelete: ImportRecord?
    @State private var showingDeleteConfirmation = false
    @State private var sharedFile: SharedFile?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            filesList
                .background { PocketPortCanvas() }
                .navigationTitle("Files")
                .searchable(text: $query, prompt: "Search file names")
                .toolbar { fileToolbar }
                .navigationDestination(for: UUID.self) { id in
                    ReaderView(importID: id, store: coordinator.store, showSaved: savedID == id)
                }
                .sheet(isPresented: $scanning, onDismiss: scannerDismissed) {
                    ScannerSheet(coordinator: coordinator, fixturesEnabled: fixturesEnabled)
                }
                .sheet(isPresented: $showingSettings) {
                    FilesSettingsView(confirmBeforeDeleting: $confirmBeforeDeleting,
                                      byteCount: files.reduce(0) { $0 + Int64($1.byteCount) },
                                      isEmpty: files.isEmpty,
                                      direct: direct,
                                      clearFiles: clearFiles)
                }
                .sheet(isPresented: $showingFilters) {
                    FileFilterSheet(filter: $filter)
                }
                .sheet(item: $sharedFile) { file in
                    FileShareSheet(file: file)
                }
                .alert("Delete file?", isPresented: $showingDeleteConfirmation, presenting: pendingDelete) { record in
                    Button("Delete", role: .destructive) { delete(record) }
                    Button("Cancel", role: .cancel) {}
                } message: { record in
                    Text("Delete the downloaded copy of \(record.filename) from this iPhone?")
                }
                .alert("PocketPort", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) { errorMessage = nil }
                } message: {
                    Text(errorMessage ?? "")
                }
                .onChange(of: coordinator.phase) { _, phase in
                    if case .committed = phase { scanning = false }
                    else { closeIdleScannerIfOffline() }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let activity = direct.activity {
                        DirectTransferNotice(activity: activity, dismiss: direct.dismissActivity)
                    }
                }
                .onChange(of: direct.importEvent) { _, _ in Task { await refresh() } }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    direct.updateAvailability(foreground: phase == .active, wifi: wifi.isAvailable)
                }
                .onChange(of: wifi.isAvailable) { _, available in
                    direct.updateAvailability(foreground: scenePhase == .active, wifi: available)
                    if available == true { showingWiFiRequired = false }
                    closeIdleScannerIfOffline()
                }
                .task { await refresh() }
                .onChange(of: path) { _, next in if next.isEmpty { savedID = nil } }
        }
    }

    private var visibleFiles: [ImportRecord] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return files.filter { record in
            (search.isEmpty || record.filename.localizedStandardContains(search)) && filter.includes(record)
        }
    }

    private var filesList: some View {
        let items = visibleFiles
        return List {
            if filter.isActive {
                Section {
                    HStack {
                        if let kind = filter.kind {
                            Button { filter.kind = nil } label: {
                                Label(kind.rawValue, systemImage: "xmark.circle")
                            }
                            .accessibilityLabel("Remove \(kind.rawValue) filter")
                            .pocketPortActionStyle()
                        }
                        if filter.usesDateRange {
                            Button("Dates", systemImage: "xmark.circle") { filter.usesDateRange = false }
                                .accessibilityLabel("Remove date range filter")
                                .pocketPortActionStyle()
                        }
                    }
                    .buttonStyle(.borderless)
                    .listRowBackground(Color.clear)
                }
            }
            if !items.isEmpty {
                Section {
                    ForEach(items) { record in
                        NavigationLink(value: record.id) { fileRow(record) }
                            .accessibilityIdentifier("import-\(record.id.uuidString)")
                            .swipeActions(allowsFullSwipe: false) {
                                Button("Delete", systemImage: "trash", role: .destructive) { requestDelete(record) }
                                Button("Share", systemImage: "square.and.arrow.up") { share(record) }
                                    .tint(.teal)
                            }
                    }
                } footer: {
                    Text(items.count == 1 ? "1 file" : "\(items.count) files")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .overlay {
            if items.isEmpty { emptyState }
        }
    }

    @ToolbarContentBuilder
    private var fileToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Settings", systemImage: "gearshape") { showingSettings = true }
                .accessibilityIdentifier("files-settings")
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: openScanner) {
                Label("Scan", systemImage: "qrcode.viewfinder").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("scan")
            .disabled(wifi.isAvailable == nil)
            .popover(isPresented: $showingWiFiRequired) {
                WiFiRequiredPopover { showingWiFiRequired = false }
            }
        }
        ToolbarItem(placement: .bottomBar) {
            Button("Filter", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") {
                showingFilters = true
            }
            .accessibilityIdentifier("files-filter")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if unavailable {
            ContentUnavailableView {
                Label("Couldn’t open Files", systemImage: "exclamationmark.circle")
            } actions: {
                Button("Retry", systemImage: "arrow.clockwise") { Task { await refresh() } }
                    .pocketPortActionStyle(prominent: true)
            }
        } else if !files.isEmpty || !query.isEmpty || filter.isActive {
            ContentUnavailableView("No matching files", systemImage: "magnifyingglass",
                                   description: Text("Try a different name, type, or date range."))
                .allowsHitTesting(false)
        } else {
            ContentUnavailableView {
                VStack(spacing: 14) {
                    Image(systemName: "doc.text")
                        .font(.system(.largeTitle, weight: .medium))
                        .foregroundStyle(.teal)
                        .padding(24)
                        .pocketPortGlass(in: Circle())
                        .accessibilityHidden(true)
                    Text("No imported files").font(.title2.weight(.semibold))
                }
            } description: {
                Text("Tap Scan to import a file from your Mac.")
            }
            .allowsHitTesting(false)
        }
    }

    private func fileRow(_ record: ImportRecord) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.filename).font(.headline)
                if let project = record.project {
                    Text(project).font(.subheadline).foregroundStyle(.secondary)
                }
                Text("\(record.importedAt.formatted(.dateTime.month(.abbreviated).day().year())) · \(ByteCountFormatter.string(fromByteCount: Int64(record.byteCount), countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } icon: {
            Image(systemName: fileIcon(record.format))
                .font(.body.weight(.medium))
                .foregroundStyle(.teal)
                .accessibilityHidden(true)
        }
    }

    private func fileIcon(_ format: ShareFileFormat?) -> String {
        switch format {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .html: return "chevron.left.forwardslash.chevron.right"
        default: return "doc.text"
        }
    }

    private func openScanner() {
        guard wifi.isAvailable == true else {
            showingWiFiRequired = true
            return
        }
        coordinator.reset()
        scanning = true
    }

    private func closeIdleScannerIfOffline() {
        guard scanning, wifi.isAvailable == false, coordinator.phase == .scanning else { return }
        scannerLostWiFi = true
        scanning = false
    }

    private func scannerDismissed() {
        if case .committed(let record) = coordinator.phase {
            savedID = record.id
            path.append(record.id)
        }
        coordinator.reset()
        if scannerLostWiFi {
            scannerLostWiFi = false
            showingWiFiRequired = wifi.isAvailable == false
        }
        Task { await refresh() }
    }

    private func refresh() async {
        do {
            files = try await coordinator.store.list()
            unavailable = false
        } catch {
            unavailable = true
        }
    }

    private func requestDelete(_ record: ImportRecord) {
        if confirmBeforeDeleting {
            pendingDelete = record
            showingDeleteConfirmation = true
        } else {
            delete(record)
        }
    }

    private func delete(_ record: ImportRecord) {
        Task {
            do { try await coordinator.store.delete(id: record.id) }
            catch { errorMessage = "The downloaded file couldn’t be deleted." }
            await refresh()
        }
    }

    private func clearFiles() async throws {
        do {
            try await coordinator.store.clear()
        } catch {
            await refresh()
            throw error
        }
        await refresh()
    }

    private func share(_ record: ImportRecord) {
        Task {
            do { sharedFile = try await coordinator.store.share(id: record.id) }
            catch { errorMessage = "The downloaded file couldn’t be prepared for sharing." }
        }
    }
}

private struct WiFiRequiredPopover: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.title2.weight(.medium))
                .foregroundStyle(.teal)
                .accessibilityHidden(true)
            Text("Wi-Fi isn’t connected")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("wifi-required")
            Text("Connect to a Wi-Fi network, then tap Scan again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("OK", action: dismiss)
                .pocketPortActionStyle(prominent: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(idealWidth: 248, maxWidth: 248, alignment: .leading)
        .padding(20)
        .presentationCompactAdaptation(typeSize.isAccessibilitySize ? .sheet : .popover)
    }
}

private struct FileFilter {
    var kind: ShareFileFormat?
    var usesDateRange = false
    var start = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
    var end = Date.now

    var isActive: Bool { kind != nil || usesDateRange }

    func includes(_ record: ImportRecord) -> Bool {
        guard kind == nil || record.format == kind else { return false }
        guard usesDateRange else { return true }
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: record.importedAt)
        return day >= calendar.startOfDay(for: start) && day <= calendar.startOfDay(for: end)
    }
}

private struct FileFilterSheet: View {
    @Binding var filter: FileFilter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker("File Type", selection: $filter.kind) {
                    Text("All").tag(Optional<ShareFileFormat>.none)
                    ForEach(ShareFileFormat.allCases, id: \.self) { format in
                        Text(format.rawValue).tag(Optional(format))
                    }
                }
                Section("Imported date") {
                    Toggle("Date Range", isOn: $filter.usesDateRange)
                    if filter.usesDateRange {
                        DatePicker("From", selection: $filter.start, in: ...filter.end, displayedComponents: .date)
                        DatePicker("To", selection: $filter.end, in: filter.start..., displayedComponents: .date)
                    }
                }
                Button("Reset Filters") { filter = FileFilter() }
                    .disabled(!filter.isActive)
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDragIndicator(.visible)
    }
}

private struct FileShareSheet: UIViewControllerRepresentable {
    let file: SharedFile

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
        let directory = file.url.deletingLastPathComponent()
        controller.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: directory)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
