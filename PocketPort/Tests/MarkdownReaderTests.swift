import XCTest
@testable import PocketPort

final class MarkdownReaderTests: XCTestCase {
    private func fixture(_ name: String) throws -> [MarkdownBlock] {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "md"))
        return try MarkdownBlockMapper.blocks(from: String(contentsOf: url, encoding: .utf8))
    }

    private func flatten(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
        blocks.flatMap { [$0] + flatten($0.children) }
    }

    func testNumberingTasksAndNesting() throws {
        let blocks = try fixture("ReaderStress")
        let list = try XCTUnwrap(blocks.first { $0.kind == .orderedList })
        XCTAssertEqual(list.children.map(\.kind), [.listItem(ordinal: 3), .listItem(ordinal: 4)])
        let nested = try XCTUnwrap(list.children.first?.children.last)
        XCTAssertEqual(nested.kind, .unorderedList)
        XCTAssertEqual(nested.children.compactMap(\.checked), [true, false])
        XCTAssertEqual(nested.children.last?.children.last?.kind, .orderedList)
        XCTAssertEqual(nested.children.first?.children.first.map { String($0.text.characters) }, "Completed locally.")
        let quote = try XCTUnwrap(blocks.first { $0.kind == .blockQuote })
        XCTAssertEqual(quote.children.map(\.kind), [.paragraph, .unorderedList])
    }

    func testCheckboxRequiresALiteralMarkerAndPreservesFormattedContent() throws {
        let blocks = try MarkdownBlockMapper.blocks(from: #"""
        - [ ] **bold**
        - \[ ] literal
        - `[x] code`
        - [X] *italic*
        """#)
        let items = try XCTUnwrap(blocks.first?.children)
        XCTAssertEqual(items.map(\.checked), [false, nil, nil, true])
        XCTAssertEqual(items.compactMap { $0.children.first.map { String($0.text.characters) } },
                       ["bold", "[ ] literal", "[x] code", "italic"])
    }

    func testEmptyAndTabSeparatedTasks() throws {
        let items = try XCTUnwrap(MarkdownBlockMapper.blocks(from: "- [x]\n- [ ]\ttext\n- [x]suffix").first?.children)
        XCTAssertEqual(items.map(\.checked), [true, false, nil])
        XCTAssertEqual(items.compactMap { $0.children.first.map { String($0.text.characters) } },
                       ["", "text", "[x]suffix"])
    }

    func testLinkedImageAltAndHostlessLinksStayInert() throws {
        let blocks = try MarkdownBlockMapper.blocks(from: """
        [![remote](https://img.example/a)](https://example.org) and [![local](a.png)](https://example.org).
        [before ![alt](img) after](https://example.org) [bad](https:relative) [missing](http:///path)
        [web](https://host.example)
        """)
        let text = try XCTUnwrap(blocks.first?.text)
        XCTAssertTrue(String(text.characters).contains("remote and local"))
        XCTAssertTrue(String(text.characters).contains("before alt after"))
        XCTAssertEqual(text.runs.compactMap(\.link).map(\.absoluteString), ["https://host.example"])
        XCTAssertTrue(text.runs.allSatisfy { $0.imageURL == nil })
    }

    func testLinksImagesAndHTML() throws {
        let all = flatten(try fixture("ReaderStress"))
        let runs = all.flatMap { Array($0.text.runs) }
        XCTAssertEqual(Set(runs.compactMap { $0.link?.scheme }), ["https", "http", "mailto"])
        XCTAssertEqual(runs.compactMap(\.link).count, 3)
        XCTAssertTrue(runs.allSatisfy { $0.imageURL == nil })
        let text = all.map { String($0.text.characters) }.joined(separator: "\n")
        for visible in ["relative", "Remote diagram", "Local diagram", "Inline content"] {
            XCTAssertTrue(text.contains(visible))
        }
        XCTAssertFalse(text.contains("Hidden HTML"))
        XCTAssertFalse(text.contains("<strong>"))
        XCTAssertTrue(runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
    }

    func testTableAndFence() throws {
        let blocks = try fixture("ReaderStress")
        let table = try XCTUnwrap(blocks.first { if case .table = $0.kind { return true }; return false })
        guard case .table(let columns) = table.kind else { return XCTFail("Expected table") }
        XCTAssertEqual(columns.map(\.alignment), [.left, .center, .right])
        XCTAssertEqual(table.children.first?.kind, .tableHeaderRow)
        XCTAssertEqual(table.children.count, 3)
        XCTAssertEqual(table.children.last?.children.last?.kind, .tableCell(columnIndex: 2))
        let code = try XCTUnwrap(blocks.first { $0.kind == .codeBlock(languageHint: "sh") })
        XCTAssertTrue(code.text.characters.starts(with: "  shasum"))
        XCTAssertTrue(String(code.text.characters).hasSuffix("\n    echo \"second line\"\n"))
    }

    func testActualPlansAndEmptyDocument() throws {
        for name in ["2026-11-21-pocketport-implementation-plan", "TransferDevicePlan"] {
            let all = flatten(try fixture(name))
            XCTAssertTrue(all.contains { $0.kind == .header(level: 1) })
            XCTAssertTrue(all.contains { $0.checked == false })
            XCTAssertTrue(all.contains { if case .codeBlock = $0.kind { return true }; return false })
        }
        XCTAssertTrue(try MarkdownBlockMapper.blocks(from: "").isEmpty)
    }

    func testMermaidFenceRetainsDiagramSource() throws {
        let blocks = try MarkdownBlockMapper.blocks(from: """
        > ```mermaid
        > flowchart LR
        >     A["Draft <notes>"] --> B["Review"]
        > ```

        ```swift
        print("ordinary code")
        ```
        """)
        let diagram = try XCTUnwrap(blocks.first?.children.first)
        XCTAssertEqual(diagram.kind, .codeBlock(languageHint: "mermaid"))
        XCTAssertEqual(String(diagram.text.characters), "flowchart LR\n    A[\"Draft <notes>\"] --> B[\"Review\"]\n")
        XCTAssertEqual(blocks.last?.kind, .codeBlock(languageHint: "swift"))
    }
}
