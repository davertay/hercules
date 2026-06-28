import Foundation
import Testing

@testable import UISupport

@Suite("MarkdownText")
struct MarkdownTextTests {

    /// The presentation-intent kinds (as their string descriptions) across every run, which lets us
    /// assert that block structure survived parsing rather than collapsing into one inline run.
    private func intentKinds(_ markdown: String) throws -> [String] {
        try MarkdownText.attributedString(for: markdown)
            .runs
            .compactMap(\.presentationIntent)
            .flatMap(\.components)
            .map { "\($0.kind)" }
    }

    @Test("Block markdown keeps document structure rather than flattening to one run")
    func preservesBlockStructure() throws {
        let kinds = try intentKinds(
            """
            # Heading

            A paragraph of text.

            - first
            - second

            ```swift
            let x = 1
            ```
            """
        )
        #expect(kinds.contains { $0.contains("header") })
        #expect(kinds.contains { $0.contains("paragraph") })
        #expect(kinds.contains { $0.contains("listItem") })
        #expect(kinds.contains { $0.contains("codeBlock") })
    }

    @Test(#"GFM task-list lines render as a list, not literal "- [ ]" text"#)
    func taskListBecomesList() throws {
        let kinds = try intentKinds(
            """
            - [ ] todo
            - [x] done
            """
        )
        #expect(kinds.contains { $0.contains("unorderedList") })
        #expect(kinds.contains { $0.contains("listItem") })
    }
}
