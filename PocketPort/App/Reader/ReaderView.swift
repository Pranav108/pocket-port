import SwiftUI
import QuickLook

struct ReaderView: View {
    let importID: UUID
    let store: ImportStore
    let showSaved: Bool
    @State private var filename = "Document"
    @State private var state = StateOfDocument.loading

    private enum StateOfDocument {
        case loading, failed, loaded([MarkdownBlock]), preview(URL)
    }

    var body: some View {
        Group {
            if case .preview(let url) = state {
                VStack(alignment: .leading, spacing: 0) {
                    if showSaved {
                        savedBadge.padding(.horizontal, 20).padding(.vertical, 12)
                    }
                    LocalFilePreview(url: url, filename: filename)
                }
            } else {
                document
            }
        }
        .background(.background)
        .navigationTitle(filename)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: importID) {
            state = .loading
            do {
                let item = try await store.preview(id: importID)
                filename = item.record.filename
                if item.record.format == .markdown {
                    let blocks = try await Task.detached(priority: .userInitiated) {
                        let data = try Data(contentsOf: item.url, options: [.mappedIfSafe])
                        return try MarkdownBlockMapper.blocks(from: String(decoding: data, as: UTF8.self))
                    }.value
                    try Task.checkCancellation()
                    state = .loaded(blocks)
                } else {
                    try Task.checkCancellation()
                    state = .preview(item.url)
                }
            } catch {
                if !Task.isCancelled { state = .failed }
            }
        }
    }

    private var document: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                switch state {
                case .loading:
                    ProgressView("Opening document")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                case .failed:
                    ContentUnavailableView("Couldn’t open this file.", systemImage: "doc.badge.exclamationmark")
                case .loaded(let blocks):
                    if showSaved { savedBadge }
                    if blocks.isEmpty { Text("Empty document").foregroundStyle(.secondary) }
                    ForEach(blocks) { BlockView(block: $0) }
                case .preview:
                    EmptyView()
                }
            }
            .frame(maxWidth: 660, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private var savedBadge: some View {
        Label {
            Text("Saved offline")
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .pocketPortGlass(in: Capsule())
    }
}

private struct LocalFilePreview: UIViewControllerRepresentable {
    let url: URL
    let filename: String

    func makeCoordinator() -> PreviewSource { PreviewSource(url: url, filename: filename) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class PreviewSource: NSObject, QLPreviewControllerDataSource, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?

        init(url: URL, filename: String) {
            previewItemURL = url
            previewItemTitle = filename
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { self }
    }
}

private struct BlockView: View {
    let block: MarkdownBlock
    var depth = 0
    var ordered = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var children: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(block.children) { child in
                BlockView(block: child, depth: depth, ordered: block.kind == .orderedList)
            }
        }
    }

    @ViewBuilder var body: some View {
        switch block.kind {
        case .paragraph, .tableCell:
            Text(block.text).textSelection(.enabled)
        case .header(let level):
            Text(block.text)
                .font(level == 1 ? .system(.largeTitle, design: .serif) :
                    level == 2 ? .system(.title2, design: .serif) : level == 3 ? .title3 : .headline)
                .bold().accessibilityHeading(headingLevel(level)).textSelection(.enabled)
        case .blockQuote:
            children.padding(.leading, 12)
                .overlay(alignment: .leading) { Capsule().fill(.secondary.opacity(0.4)).frame(width: 3) }
        case .orderedList, .unorderedList:
            children
        case .listItem(let ordinal):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(block.children) { child in
                    if child.id == block.children.first?.id {
                        let nestedList = child.kind == .orderedList || child.kind == .unorderedList
                        let stacked = nestedList && depth >= (typeSize.isAccessibilitySize ? 1 : 3)
                        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
                        layout {
                            marker(ordinal)
                            BlockView(block: child, depth: depth + 1)
                        }
                    } else {
                        BlockView(block: child, depth: depth + 1)
                            .padding(.leading, depth < (typeSize.isAccessibilitySize ? 1 : 3) ? 14 : 0)
                    }
                }
            }.accessibilityElement(children: .contain)
        case .codeBlock:
            ScrollView(.horizontal) {
                Text(verbatim: String(block.text.characters))
                    .font(.system(.callout, design: .monospaced))
                    .fixedSize().textSelection(.enabled).padding(10)
            }.background(.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        case .table(let columns):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    ForEach(block.children) { row in
                        GridRow {
                            ForEach(columns.indices, id: \.self) { index in
                                let cell = row.children.first { $0.kind == .tableCell(columnIndex: index) }
                                Text(cell?.text ?? AttributedString())
                                    .fontWeight(row.kind == .tableHeaderRow ? .semibold : .regular)
                                    .frame(maxWidth: 280, alignment: .leading)
                                    .gridColumnAlignment(columns[index].alignment == .right ? .trailing :
                                        columns[index].alignment == .center ? .center : .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        if row.kind == .tableHeaderRow { Divider().gridCellUnsizedAxes(.horizontal) }
                    }
                }.padding(8)
            }.background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        case .thematicBreak: Divider()
        default: children
        }
    }

    private func headingLevel(_ level: Int) -> AccessibilityHeadingLevel {
        switch level {
        case 1: return .h1
        case 2: return .h2
        case 3: return .h3
        case 4: return .h4
        case 5: return .h5
        default: return .h6
        }
    }

    @ViewBuilder private func marker(_ ordinal: Int) -> some View {
        if let checked = block.checked {
            Image(systemName: checked ? "checkmark.square" : "square")
                .accessibilityLabel("Task")
                .accessibilityValue(checked ? "Checked" : "Unchecked")
        } else {
            Text(ordered ? "\(ordinal)." : "•").foregroundStyle(.secondary)
        }
    }
}
