import Foundation

struct MarkdownBlock: Identifiable, Sendable {
    let id: Int
    let kind: PresentationIntent.Kind
    var text: AttributedString
    var children: [MarkdownBlock]
    var checked: Bool?
}

enum MarkdownBlockMapper {
    private final class Node {
        let id: Int
        let kind: PresentationIntent.Kind
        var children = [Node]()
        var text = AttributedString()
        var task: Bool?

        init(_ id: Int, _ kind: PresentationIntent.Kind) {
            self.id = id
            self.kind = kind
        }

        func block() -> MarkdownBlock {
            return MarkdownBlock(id: id, kind: kind, text: text, children: children.map { $0.block() }, checked: task)
        }
    }

    private static func allowsLink(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": return url.host?.isEmpty == false
        case "mailto": return true
        default: return false
        }
    }

    static func blocks(from source: String) throws -> [MarkdownBlock] {
        let document = try AttributedString(markdown: source, options: .init(
            interpretedSyntax: .full, appliesSourcePositionAttributes: true))
        var nodes = [Int: Node]()
        var roots = [Node]()
        for run in document.runs {
            let style = run.inlinePresentationIntent
            guard style?.contains(.inlineHTML) != true, style?.contains(.blockHTML) != true,
                  let path = run.presentationIntent?.components else { continue }
            var parent: Node?
            var listItem: Node?
            for component in path.reversed() {
                let node: Node
                if let existing = nodes[component.identity] {
                    node = existing
                } else {
                    node = Node(component.identity, component.kind)
                    nodes[node.id] = node
                    if let parent { parent.children.append(node) } else { roots.append(node) }
                }
                if case .listItem = node.kind { listItem = node }
                parent = node
            }
            guard let leaf = parent else { continue }
            var inline = AttributedString(String(document[run.range].characters))
            inline.inlinePresentationIntent = style
            let sourceRange = run.markdownSourcePosition.flatMap { Range<String.Index>($0, in: source) }
            if run.imageURL == nil, let url = run.link, allowsLink(url), let sourceRange,
               !source[sourceRange].contains("![") {
                // A linked image may have only the outer URL in Foundation's attributes.
                // In mixed image/text labels Foundation merges the entire label into one run.
                inline.link = url
            }
            if let item = listItem, item.task == nil, item.children.first === leaf, leaf.text.characters.isEmpty,
               case .paragraph = leaf.kind, style == nil, let sourceRange {
                let rest = source[sourceRange.lowerBound...]
                let marker = rest.prefix(3)
                let separator = rest.dropFirst(3).first
                if ["[ ]", "[x]", "[X]"].contains(String(marker)), inline.characters.starts(with: marker),
                   separator == nil || separator?.isNewline == true || separator == " " || separator == "\t" {
                    item.task = marker.lowercased() == "[x]"
                    inline.characters.removeFirst(3)
                    if inline.characters.first == " " || inline.characters.first == "\t" {
                        inline.characters.removeFirst()
                    }
                }
            }
            leaf.text.append(inline)
        }
        return roots.map { $0.block() }
    }
}
