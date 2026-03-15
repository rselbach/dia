import XCTest
@testable import DiaKit

final class MermaidSyntaxTests: XCTestCase {
    func testHighlightsMermaidTokens() {
        let source = "flowchart TD\nA -->|yes| B\n"
        let spans = MermaidSyntax.highlightSpans(in: source)

        XCTAssertTrue(containsSpanText(source: source, spans: spans, kind: .keyword, want: "flowchart"))
        XCTAssertTrue(containsSpanText(source: source, spans: spans, kind: .keyword, want: "TD"))
        XCTAssertTrue(containsSpanText(source: source, spans: spans, kind: .operator, want: "-->"))
        XCTAssertTrue(containsSpanText(source: source, spans: spans, kind: .label, want: "|yes|"))
    }

    func testTreatsCommentLinesAsCommentOnly() {
        let source = "%% flowchart TD -->|yes|\n"
        let spans = MermaidSyntax.highlightSpans(in: source)

        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .comment)
        XCTAssertEqual(sliceChars(source: source, start: spans[0].start, end: spans[0].end), "%% flowchart TD -->|yes|")
    }

    func testReturnsCharOffsetsForUnicodeContent() {
        let source = "\u{1F600} flowchart TD\n"
        let spans = MermaidSyntax.highlightSpans(in: source)

        let flowchartSpan = spans.first(where: {
            $0.kind == .keyword && sliceChars(source: source, start: $0.start, end: $0.end) == "flowchart"
        })
        XCTAssertNotNil(flowchartSpan, "flowchart keyword span must exist")
        XCTAssertEqual(flowchartSpan?.start, 2)
    }

    func testPreservesSpaceAndTabIndentation() {
        XCTAssertEqual(MermaidSyntax.leadingIndentation("    line"), "    ")
        XCTAssertEqual(MermaidSyntax.leadingIndentation("\t\tline"), "\t\t")
        XCTAssertEqual(MermaidSyntax.leadingIndentation("  \t line"), "  \t ")
    }

    func testAutoIndentInsertsNewlinePlusLeadingWhitespace() {
        XCTAssertEqual(MermaidSyntax.autoIndentInsertion(for: "    abc"), "\n    ")
        XCTAssertEqual(MermaidSyntax.autoIndentInsertion(for: "\t\tabc"), "\n\t\t")
        XCTAssertEqual(MermaidSyntax.autoIndentInsertion(for: "abc"), "\n")
    }

    func testKeywordsAreCaseInsensitive() {
        let source = "Flowchart TD\n"
        let spans = MermaidSyntax.highlightSpans(in: source)
        XCTAssertTrue(containsSpanText(source: source, spans: spans, kind: .keyword, want: "Flowchart"))
    }

    func testQuotedLabels() {
        let source = "A -->|\"Troy Barnes\"| B\n"
        let spans = MermaidSyntax.highlightSpans(in: source)
        XCTAssertTrue(containsSpanText(source: source, spans: spans, kind: .label, want: "\"Troy Barnes\""))
    }

    func testOperatorPatterns() {
        for pattern in MermaidSyntax.operatorPatterns {
            let source = "A \(pattern) B\n"
            let spans = MermaidSyntax.highlightSpans(in: source)
            XCTAssertTrue(
                containsSpanText(source: source, spans: spans, kind: .operator, want: pattern),
                "operator pattern \(pattern) should be highlighted"
            )
        }
    }

    func testEmptySource() {
        let spans = MermaidSyntax.highlightSpans(in: "")
        XCTAssertTrue(spans.isEmpty)
    }

    func testIndentedComment() {
        let source = "    %% this is a comment\n"
        let spans = MermaidSyntax.highlightSpans(in: source)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .comment)
        XCTAssertEqual(spans[0].start, 4)
    }

    // MARK: - Helpers

    private func containsSpanText(source: String, spans: [HighlightSpan], kind: HighlightKind, want: String) -> Bool {
        spans.filter { $0.kind == kind }.contains { span in
            sliceChars(source: source, start: span.start, end: span.end) == want
        }
    }

    private func sliceChars(source: String, start: Int, end: Int) -> String {
        let scalars = Array(source.unicodeScalars)
        let slice = scalars[start..<end]
        return String(String.UnicodeScalarView(slice))
    }
}
