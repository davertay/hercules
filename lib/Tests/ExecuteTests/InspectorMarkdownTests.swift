import Foundation
import Material
import Testing

@testable import Execute

@Suite("InspectorPane — markdown rendering")
struct InspectorMarkdownTests {

    /// The Issue-body pane used to flatten markdown with Apple's inline-only parser; it now renders
    /// through `MarkdownText`. This pins the behaviour change: inline-only drops block structure,
    /// whereas the block parser keeps headings, lists, and fenced code blocks distinct.
    @Test("Issue body renders as block-level markdown rather than flattened inline text")
    func issueBodyKeepsBlockStructure() throws {
        let body = """
            ## Goal

            Implement the thing.

            - [ ] write it
            - [x] test it

            ```swift
            let x = 1
            ```
            """

        // Old behaviour: inline-only parsing produced no block presentation intents.
        let inlineOnly = try AttributedString(
            markdown: body,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        #expect(inlineOnly.runs.compactMap(\.presentationIntent).isEmpty)

        // New behaviour: MarkdownText keeps the document structure.
        let kinds = try MarkdownText.attributedString(for: body)
            .runs
            .compactMap(\.presentationIntent)
            .flatMap(\.components)
            .map { "\($0.kind)" }
        #expect(kinds.contains { $0.contains("header") })
        #expect(kinds.contains { $0.contains("listItem") })
        #expect(kinds.contains { $0.contains("codeBlock") })
    }
}
