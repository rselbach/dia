package syntax

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func sliceChars(source string, start, end int) string {
	runes := []rune(source)
	return string(runes[start:end])
}

func containsSpanText(source string, spans []HighlightSpan, kind HighlightKind, want string) bool {
	for _, s := range spans {
		if s.Kind != kind {
			continue
		}
		if sliceChars(source, s.Start, s.End) == want {
			return true
		}
	}
	return false
}

func TestHighlightsMermaidTokens(t *testing.T) {
	r := require.New(t)
	source := "flowchart TD\nA -->|yes| B\n"
	spans := HighlightSpans(source)

	r.True(containsSpanText(source, spans, Keyword, "flowchart"))
	r.True(containsSpanText(source, spans, Keyword, "TD"))
	r.True(containsSpanText(source, spans, Operator, "-->"))
	r.True(containsSpanText(source, spans, Label, "|yes|"))
}

func TestCommentLinesAreCommentOnly(t *testing.T) {
	r := require.New(t)
	source := "%% flowchart TD -->|yes|\n"
	spans := HighlightSpans(source)

	r.Len(spans, 1)
	r.Equal(Comment, spans[0].Kind)
	r.Equal("%% flowchart TD -->|yes|", sliceChars(source, spans[0].Start, spans[0].End))
}

func TestCharOffsetsForUnicodeContent(t *testing.T) {
	r := require.New(t)
	source := "\U0001f600 flowchart TD\n"
	spans := HighlightSpans(source)

	found := false
	for _, s := range spans {
		if s.Kind == Keyword && sliceChars(source, s.Start, s.End) == "flowchart" {
			r.Equal(2, s.Start)
			found = true
			break
		}
	}
	r.True(found, "flowchart keyword span must exist")
}

func TestLeadingIndentation(t *testing.T) {
	tests := map[string]struct {
		input string
		want  string
	}{
		"spaces":    {input: "    line", want: "    "},
		"tabs":      {input: "\t\tline", want: "\t\t"},
		"mixed":     {input: "  \t line", want: "  \t "},
		"no indent": {input: "line", want: ""},
		"empty":     {input: "", want: ""},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			r := require.New(t)
			r.Equal(tc.want, leadingIndentation(tc.input))
		})
	}
}

func TestAutoIndentInsertion(t *testing.T) {
	tests := map[string]struct {
		prefix string
		want   string
	}{
		"spaces prefix": {prefix: "    abc", want: "\n    "},
		"tabs prefix":   {prefix: "\t\tabc", want: "\n\t\t"},
		"no indent":     {prefix: "abc", want: "\n"},
		"empty prefix":  {prefix: "", want: "\n"},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			r := require.New(t)
			r.Equal(tc.want, AutoIndentInsertion(tc.prefix))
		})
	}
}

func TestKeywordsCaseInsensitive(t *testing.T) {
	r := require.New(t)
	source := "FLOWCHART td\n"
	spans := HighlightSpans(source)
	r.True(containsSpanText(source, spans, Keyword, "FLOWCHART"))
	r.True(containsSpanText(source, spans, Keyword, "td"))
}

func TestOperatorPatterns(t *testing.T) {
	r := require.New(t)
	source := "A -.-> B --> C <-- D ==> E --- F --x G --o H ::: I\n"
	spans := HighlightSpans(source)

	for _, op := range []string{"-.->", "-->", "<--", "==>", "---", "--x", "--o", ":::"} {
		r.True(containsSpanText(source, spans, Operator, op), "missing operator: %s", op)
	}
}

func TestQuotedLabels(t *testing.T) {
	r := require.New(t)
	source := `A["Hello World"] --> B` + "\n"
	spans := HighlightSpans(source)
	r.True(containsSpanText(source, spans, Label, `"Hello World"`))
}

func TestEmptySource(t *testing.T) {
	r := require.New(t)
	spans := HighlightSpans("")
	r.Empty(spans)
}

func TestIndentedComment(t *testing.T) {
	r := require.New(t)
	source := "    %% this is a comment\n"
	spans := HighlightSpans(source)
	r.Len(spans, 1)
	r.Equal(Comment, spans[0].Kind)
	r.Equal(4, spans[0].Start)
}
