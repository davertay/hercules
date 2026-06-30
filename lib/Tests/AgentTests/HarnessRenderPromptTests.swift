import Foundation
import Testing

@testable import Agent

@Suite("Harness.renderPrompt")
struct HarnessRenderPromptTests {
    let root = URL(fileURLWithPath: "/tmp/inputs")

    @Test func nilInputsPassesPromptVerbatim() {
        let result = Harness.renderPrompt(prompt: "hello", inputs: nil)
        #expect(result == "hello")
    }

    @Test func emptyRelativePathsPassesPromptVerbatim() {
        let bundle = InputBundle(root: root, relativePaths: [])
        let result = Harness.renderPrompt(prompt: "hello", inputs: bundle)
        #expect(result == "hello")
    }

    @Test func singlePathAppendsFooterWithAbsolutePath() {
        let bundle = InputBundle(root: root, relativePaths: ["a.txt"])
        let result = Harness.renderPrompt(prompt: "hello", inputs: bundle)
        #expect(result == "hello\n\nFiles available (read with your file-read tool):\n- /tmp/inputs/a.txt")
    }

    @Test func multiplePathsAppendFooterWithAbsolutePaths() {
        let bundle = InputBundle(root: root, relativePaths: ["a.txt", "b.md"])
        let result = Harness.renderPrompt(prompt: "hello", inputs: bundle)
        #expect(
            result
                == "hello\n\nFiles available (read with your file-read tool):\n- /tmp/inputs/a.txt\n- /tmp/inputs/b.md"
        )
    }

    @Test func nestedRelativePathResolvesAgainstRoot() {
        let bundle = InputBundle(root: root, relativePaths: ["phases/design/summary.md"])
        let result = Harness.renderPrompt(prompt: "hello", inputs: bundle)
        #expect(
            result
                == "hello\n\nFiles available (read with your file-read tool):\n- /tmp/inputs/phases/design/summary.md"
        )
    }
}
