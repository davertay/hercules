import Foundation
import Material
import Testing

@testable import Validate

@Suite("ReviewInspector — markdown rendering")
struct ReviewInspectorMarkdownTests {

    /// The review-Summary pane used to flatten markdown with Apple's inline-only parser; it now
    /// renders through `MarkdownText`. This pins the behaviour change: inline-only drops block
    /// structure, whereas the block parser keeps headings, lists, and fenced code blocks distinct.
    @Test("Review summary renders as block-level markdown rather than flattened inline text")
    func summaryKeepsBlockStructure() throws {
        let summary = """
            ## Findings

            The code reads cleanly. A couple of notes:

            - clear naming
            - missing a test

            ```swift
            assert(value == expected)
            ```
            """

        // Old behaviour: inline-only parsing produced no block presentation intents.
        let inlineOnly = try AttributedString(
            markdown: summary,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        #expect(inlineOnly.runs.compactMap(\.presentationIntent).isEmpty)

        // New behaviour: MarkdownText keeps the document structure.
        let kinds = try MarkdownText.attributedString(for: summary)
            .runs
            .compactMap(\.presentationIntent)
            .flatMap(\.components)
            .map { "\($0.kind)" }
        #expect(kinds.contains { $0.contains("header") })
        #expect(kinds.contains { $0.contains("listItem") })
        #expect(kinds.contains { $0.contains("codeBlock") })
    }
}
