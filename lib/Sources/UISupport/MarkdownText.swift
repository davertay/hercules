import Foundation
import SwiftUI
import Textual

/// Renders a markdown string as block-level rich text using Textual's `StructuredText` and its
/// default theme. Unlike Apple's inline-only `AttributedString` parsing, this keeps document
/// structure — headings, paragraphs, lists, and fenced code blocks render distinctly — and text
/// stays selectable where the platform supports it.
public struct MarkdownText: View {
    public let markdown: String

    public init(_ markdown: String) {
        self.markdown = markdown
    }

    public var body: some View {
        StructuredText(markdown, parser: Self.parser)
            .textual.textSelection(.enabled)
    }

    /// The block-level Markdown parser `MarkdownText` renders with. Matches `StructuredText`'s
    /// default full-document parsing; exposed so callers and tests can inspect the parsed result.
    public static let parser = AttributedStringMarkdownParser(baseURL: nil)

    /// Parses `markdown` into the same block-level `AttributedString` this view renders. Useful for
    /// asserting that document structure (headings, lists, code blocks) survives parsing.
    public static func attributedString(for markdown: String) throws -> AttributedString {
        try parser.attributedString(for: markdown)
    }
}
