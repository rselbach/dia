// Package syntax provides Mermaid syntax highlighting and auto-indent support.
package syntax

import (
	"cmp"
	"slices"
	"strings"
)

// HighlightKind classifies a syntax span.
type HighlightKind int

const (
	Keyword HighlightKind = iota
	Operator
	Comment
	Label
)

// HighlightSpan marks a character range with a syntax kind.
// Start and End are rune (character) offsets, not byte offsets.
type HighlightSpan struct {
	Start int
	End   int
	Kind  HighlightKind
}

var mermaidKeywords = []string{
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
}

var mermaidOperatorPatterns = []string{
	"-.->",
	"-->",
	"<--",
	"==>",
	"---",
	"--x",
	"--o",
	":::",
}

// HighlightSpans returns syntax highlight spans for the given Mermaid source.
// All offsets are rune-based (Unicode scalar values), matching Rust char semantics.
func HighlightSpans(source string) []HighlightSpan {
	var spans []HighlightSpan
	lineOffset := 0

	remainder := source
	for len(remainder) > 0 {
		nlIdx := strings.IndexByte(remainder, '\n')

		var line string
		var consumed int
		switch {
		case nlIdx >= 0:
			line = remainder[:nlIdx]
			consumed = nlIdx + 1
		default:
			line = remainder
			consumed = len(remainder)
		}

		highlightLine(line, lineOffset, &spans)
		lineOffset += runeLen(remainder[:consumed])
		remainder = remainder[consumed:]
	}

	sortSpans(spans)
	spans = dedupSpans(spans)
	return spans
}

// AutoIndentInsertion returns the string to insert for an auto-indent newline,
// preserving the leading whitespace of prefix.
func AutoIndentInsertion(prefix string) string {
	return "\n" + leadingIndentation(prefix)
}

// LeadingIndentation returns the leading whitespace (spaces and tabs) of a line.
func leadingIndentation(line string) string {
	runes := []rune(line)
	i := 0
	for i < len(runes) && (runes[i] == ' ' || runes[i] == '\t') {
		i++
	}
	return string(runes[:i])
}

func highlightLine(line string, lineOffset int, spans *[]HighlightSpan) {
	if len(line) == 0 {
		return
	}

	runes := []rune(line)
	lineCharLen := len(runes)

	leadingWS := 0
	for leadingWS < lineCharLen && (runes[leadingWS] == ' ' || runes[leadingWS] == '\t') {
		leadingWS++
	}

	trimmed := string(runes[leadingWS:])
	if strings.HasPrefix(trimmed, "%%") {
		*spans = append(*spans, HighlightSpan{
			Start: lineOffset + leadingWS,
			End:   lineOffset + lineCharLen,
			Kind:  Comment,
		})
		return
	}

	highlightKeywords(line, lineOffset, spans)
	highlightOperators(line, lineOffset, spans)
	highlightQuotedLabels(runes, lineOffset, spans)
	highlightPipeLabels(runes, lineOffset, spans)
}

func highlightKeywords(line string, lineOffset int, spans *[]HighlightSpan) {
	runes := []rune(line)
	tokenStart := -1
	tokenStartChar := 0

	for charOffset, r := range runes {
		if isWordChar(r) {
			if tokenStart == -1 {
				tokenStart = charOffset
				tokenStartChar = charOffset
			}
			continue
		}

		if tokenStart != -1 {
			token := string(runes[tokenStart:charOffset])
			if isMermaidKeyword(token) {
				*spans = append(*spans, HighlightSpan{
					Start: lineOffset + tokenStartChar,
					End:   lineOffset + charOffset,
					Kind:  Keyword,
				})
			}
			tokenStart = -1
		}
	}

	if tokenStart != -1 {
		token := string(runes[tokenStart:])
		if isMermaidKeyword(token) {
			*spans = append(*spans, HighlightSpan{
				Start: lineOffset + tokenStartChar,
				End:   lineOffset + len(runes),
				Kind:  Keyword,
			})
		}
	}
}

func highlightOperators(line string, lineOffset int, spans *[]HighlightSpan) {
	for _, pattern := range mermaidOperatorPatterns {
		idx := 0
		for {
			pos := strings.Index(line[idx:], pattern)
			if pos < 0 {
				break
			}
			byteStart := idx + pos
			startChars := runeLen(line[:byteStart])
			endChars := startChars + runeLen(pattern)
			*spans = append(*spans, HighlightSpan{
				Start: lineOffset + startChars,
				End:   lineOffset + endChars,
				Kind:  Operator,
			})
			idx = byteStart + len(pattern)
		}
	}
}

func highlightQuotedLabels(runes []rune, lineOffset int, spans *[]HighlightSpan) {
	quoteStart := -1
	for i, r := range runes {
		if r != '"' {
			continue
		}

		if quoteStart != -1 {
			*spans = append(*spans, HighlightSpan{
				Start: lineOffset + quoteStart,
				End:   lineOffset + i + 1,
				Kind:  Label,
			})
			quoteStart = -1
			continue
		}

		quoteStart = i
	}
}

func highlightPipeLabels(runes []rune, lineOffset int, spans *[]HighlightSpan) {
	pipeStart := -1
	for i, r := range runes {
		if r != '|' {
			continue
		}

		if pipeStart != -1 {
			if i > pipeStart+1 {
				*spans = append(*spans, HighlightSpan{
					Start: lineOffset + pipeStart,
					End:   lineOffset + i + 1,
					Kind:  Label,
				})
			}
			pipeStart = -1
			continue
		}

		pipeStart = i
	}
}

func isWordChar(r rune) bool {
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' || r == '-'
}

func isMermaidKeyword(token string) bool {
	return slices.Contains(mermaidKeywords, strings.ToLower(token))
}

func runeLen(s string) int {
	n := 0
	for range s {
		n++
	}
	return n
}

func spanKindRank(kind HighlightKind) int {
	switch kind {
	case Comment:
		return 0
	case Keyword:
		return 1
	case Operator:
		return 2
	case Label:
		return 3
	default:
		return 4
	}
}

func sortSpans(spans []HighlightSpan) {
	slices.SortFunc(spans, func(a, b HighlightSpan) int {
		if c := cmp.Compare(a.Start, b.Start); c != 0 {
			return c
		}
		if c := cmp.Compare(a.End, b.End); c != 0 {
			return c
		}
		return cmp.Compare(spanKindRank(a.Kind), spanKindRank(b.Kind))
	})
}

func dedupSpans(spans []HighlightSpan) []HighlightSpan {
	return slices.CompactFunc(spans, func(a, b HighlightSpan) bool {
		return a.Start == b.Start && a.End == b.End && a.Kind == b.Kind
	})
}
