import Foundation

public enum HighlightKind: Equatable, Hashable, Sendable {
    case keyword
    case `operator`
    case comment
    case label
}

public struct HighlightSpan: Equatable, Hashable, Sendable {
    public let start: Int
    public let end: Int
    public let kind: HighlightKind

    public init(start: Int, end: Int, kind: HighlightKind) {
        self.start = start
        self.end = end
        self.kind = kind
    }
}

public enum MermaidSyntax {
    public static let keywords: Set<String> = [
        "flowchart",
        "graph",
        "sequencediagram",
        "classdiagram",
        "statediagram",
        "statediagram-v2",
        "erdiagram",
        "journey",
        "gantt",
        "pie",
        "mindmap",
        "timeline",
        "quadrantchart",
        "gitgraph",
        "subgraph",
        "end",
        "direction",
        "classdef",
        "class",
        "click",
        "linkstyle",
        "style",
        "section",
        "title",
        "participant",
        "actor",
        "loop",
        "alt",
        "else",
        "opt",
        "par",
        "and",
        "critical",
        "break",
        "rect",
        "note",
        "activate",
        "deactivate",
        "tb",
        "bt",
        "lr",
        "rl",
        "td",
        "dt",
    ]

    public static let operatorPatterns: [String] = [
        "-.->", "-->", "<--", "==>", "---", "--x", "--o", ":::",
    ]

    public static func highlightSpans(in source: String) -> [HighlightSpan] {
        var spans: [HighlightSpan] = []
        var lineOffset = 0

        for line in splitLinesPreservingTerminators(source) {
            let logical = line.hasSuffix("\n") ? String(line.dropLast()) : line
            highlightLine(logical, lineOffset: lineOffset, spans: &spans)
            lineOffset += line.unicodeScalars.count
        }

        spans.sort {
            ($0.start, $0.end, kindRank($0.kind)) < ($1.start, $1.end, kindRank($1.kind))
        }

        var deduped: [HighlightSpan] = []
        for span in spans {
            guard span != deduped.last else { continue }
            deduped.append(span)
        }

        return deduped
    }

    public static func autoIndentInsertion(for prefix: String) -> String {
        "\n\(leadingIndentation(prefix))"
    }

    public static func leadingIndentation(_ line: String) -> String {
        String(line.prefix(while: { $0 == " " || $0 == "\t" }))
    }

    // MARK: - Private

    private static func splitLinesPreservingTerminators(_ source: String) -> [String] {
        guard !source.isEmpty else { return [] }

        var result: [String] = []
        var current = source.startIndex

        while current < source.endIndex {
            guard let newlineIndex = source[current...].firstIndex(of: "\n") else {
                result.append(String(source[current...]))
                break
            }

            let lineEnd = source.index(after: newlineIndex)
            result.append(String(source[current..<lineEnd]))
            current = lineEnd
        }

        return result
    }

    private static func highlightLine(_ line: String, lineOffset: Int, spans: inout [HighlightSpan]) {
        guard !line.isEmpty else { return }

        let scalars = Array(line.unicodeScalars)
        let leadingWS = scalars.prefix(while: {
            CharacterSet.whitespaces.contains($0)
        }).count

        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        if trimmed.hasPrefix("%%") {
            spans.append(HighlightSpan(
                start: lineOffset + leadingWS,
                end: lineOffset + scalars.count,
                kind: .comment
            ))
            return
        }

        highlightKeywords(line, lineOffset: lineOffset, spans: &spans)
        highlightOperators(line, lineOffset: lineOffset, spans: &spans)
        highlightQuotedLabels(line, lineOffset: lineOffset, spans: &spans)
        highlightPipeLabels(line, lineOffset: lineOffset, spans: &spans)
    }

    private static func highlightKeywords(_ line: String, lineOffset: Int, spans: inout [HighlightSpan]) {
        var tokenStartChar: Int?
        var tokenStartIndex: String.UnicodeScalarView.Index?
        var charOffset = 0

        for (index, scalar) in line.unicodeScalars.enumerated() {
            let char = Character(scalar)
            if isWordChar(char) {
                if tokenStartChar == nil {
                    tokenStartChar = index
                    tokenStartIndex = line.unicodeScalars.index(line.unicodeScalars.startIndex, offsetBy: index)
                }
            } else if let startChar = tokenStartChar, let startIdx = tokenStartIndex {
                let endIdx = line.unicodeScalars.index(line.unicodeScalars.startIndex, offsetBy: index)
                let token = String(line.unicodeScalars[startIdx..<endIdx])
                if isMermaidKeyword(token) {
                    spans.append(HighlightSpan(
                        start: lineOffset + startChar,
                        end: lineOffset + index,
                        kind: .keyword
                    ))
                }
                tokenStartChar = nil
                tokenStartIndex = nil
            }

            charOffset = index + 1
        }

        if let startChar = tokenStartChar, let startIdx = tokenStartIndex {
            let token = String(line.unicodeScalars[startIdx...])
            if isMermaidKeyword(token) {
                spans.append(HighlightSpan(
                    start: lineOffset + startChar,
                    end: lineOffset + charOffset,
                    kind: .keyword
                ))
            }
        }
    }

    private static func highlightOperators(_ line: String, lineOffset: Int, spans: inout [HighlightSpan]) {
        for pattern in operatorPatterns {
            var searchRange = line.startIndex..<line.endIndex
            while let matchRange = line.range(of: pattern, range: searchRange) {
                let startChars = line.unicodeScalars.distance(
                    from: line.unicodeScalars.startIndex,
                    to: matchRange.lowerBound.samePosition(in: line.unicodeScalars) ?? line.unicodeScalars.startIndex
                )
                let endChars = startChars + pattern.unicodeScalars.count
                spans.append(HighlightSpan(
                    start: lineOffset + startChars,
                    end: lineOffset + endChars,
                    kind: .operator
                ))
                searchRange = matchRange.upperBound..<line.endIndex
            }
        }
    }

    private static func highlightQuotedLabels(_ line: String, lineOffset: Int, spans: inout [HighlightSpan]) {
        var quoteStart: Int?
        for (index, scalar) in line.unicodeScalars.enumerated() {
            guard scalar == "\"" else { continue }

            if let start = quoteStart {
                spans.append(HighlightSpan(
                    start: lineOffset + start,
                    end: lineOffset + index + 1,
                    kind: .label
                ))
                quoteStart = nil
            } else {
                quoteStart = index
            }
        }
    }

    private static func highlightPipeLabels(_ line: String, lineOffset: Int, spans: inout [HighlightSpan]) {
        var pipeStart: Int?
        for (index, scalar) in line.unicodeScalars.enumerated() {
            guard scalar == "|" else { continue }

            if let start = pipeStart {
                if index > start + 1 {
                    spans.append(HighlightSpan(
                        start: lineOffset + start,
                        end: lineOffset + index + 1,
                        kind: .label
                    ))
                }
                pipeStart = nil
            } else {
                pipeStart = index
            }
        }
    }

    private static func isWordChar(_ char: Character) -> Bool {
        char.isASCII && (char.isLetter || char.isNumber || char == "_" || char == "-")
    }

    private static func isMermaidKeyword(_ token: String) -> Bool {
        keywords.contains(token.lowercased())
    }

    private static func kindRank(_ kind: HighlightKind) -> Int {
        switch kind {
        case .comment: 0
        case .keyword: 1
        case .operator: 2
        case .label: 3
        }
    }
}
