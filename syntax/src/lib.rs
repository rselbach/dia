#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HighlightKind {
    Keyword,
    Operator,
    Comment,
    Label,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HighlightSpan {
    pub start: usize,
    pub end: usize,
    pub kind: HighlightKind,
}

impl HighlightSpan {
    fn new(start: usize, end: usize, kind: HighlightKind) -> Self {
        Self { start, end, kind }
    }
}

const MERMAID_KEYWORDS: &[&str] = &[
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
];

const MERMAID_OPERATOR_PATTERNS: &[&str] =
    &["-.->", "-->", "<--", "==>", "---", "--x", "--o", ":::"];

pub fn highlight_spans(source: &str) -> Vec<HighlightSpan> {
    let mut spans = Vec::new();
    let mut line_offset = 0usize;

    for line in source.split_inclusive('\n') {
        let logical_line = line.strip_suffix('\n').unwrap_or(line);
        highlight_line(logical_line, line_offset, &mut spans);
        line_offset += line.chars().count();
    }

    spans.sort_by_key(|span| (span.start, span.end, span_kind_rank(span.kind)));
    spans.dedup();
    spans
}

pub fn leading_indentation(line: &str) -> String {
    line.chars()
        .take_while(|value| matches!(value, ' ' | '\t'))
        .collect()
}

pub fn auto_indent_insertion(prefix: &str) -> String {
    format!("\n{}", leading_indentation(prefix))
}

fn highlight_line(line: &str, line_offset: usize, spans: &mut Vec<HighlightSpan>) {
    if line.is_empty() {
        return;
    }

    let line_char_len = line.chars().count();
    let leading_whitespace = line
        .chars()
        .take_while(|value| value.is_whitespace())
        .count();

    if line.trim_start().starts_with("%%") {
        spans.push(HighlightSpan::new(
            line_offset + leading_whitespace,
            line_offset + line_char_len,
            HighlightKind::Comment,
        ));
        return;
    }

    highlight_keywords(line, line_offset, spans);
    highlight_operators(line, line_offset, spans);
    highlight_quoted_labels(line, line_offset, spans);
    highlight_pipe_labels(line, line_offset, spans);
}

fn highlight_keywords(line: &str, line_offset: usize, spans: &mut Vec<HighlightSpan>) {
    let mut token_start_byte: Option<usize> = None;
    let mut token_start_char = 0usize;
    let mut char_offset = 0usize;

    for (byte_index, value) in line.char_indices() {
        if is_word_char(value) {
            if token_start_byte.is_none() {
                token_start_byte = Some(byte_index);
                token_start_char = char_offset;
            }
        } else if let Some(start_byte) = token_start_byte.take() {
            let token = &line[start_byte..byte_index];
            if is_mermaid_keyword(token) {
                spans.push(HighlightSpan::new(
                    line_offset + token_start_char,
                    line_offset + char_offset,
                    HighlightKind::Keyword,
                ));
            }
        }

        char_offset += 1;
    }

    if let Some(start_byte) = token_start_byte {
        let token = &line[start_byte..];
        if is_mermaid_keyword(token) {
            spans.push(HighlightSpan::new(
                line_offset + token_start_char,
                line_offset + char_offset,
                HighlightKind::Keyword,
            ));
        }
    }
}

fn highlight_operators(line: &str, line_offset: usize, spans: &mut Vec<HighlightSpan>) {
    for pattern in MERMAID_OPERATOR_PATTERNS {
        for (byte_index, _) in line.match_indices(pattern) {
            let start_chars = line[..byte_index].chars().count();
            let end_chars = start_chars + pattern.chars().count();
            spans.push(HighlightSpan::new(
                line_offset + start_chars,
                line_offset + end_chars,
                HighlightKind::Operator,
            ));
        }
    }
}

fn highlight_quoted_labels(line: &str, line_offset: usize, spans: &mut Vec<HighlightSpan>) {
    let mut quote_start: Option<usize> = None;
    for (index, value) in line.chars().enumerate() {
        if value != '"' {
            continue;
        }

        if let Some(start) = quote_start {
            spans.push(HighlightSpan::new(
                line_offset + start,
                line_offset + index + 1,
                HighlightKind::Label,
            ));
            quote_start = None;
            continue;
        }

        quote_start = Some(index);
    }
}

fn highlight_pipe_labels(line: &str, line_offset: usize, spans: &mut Vec<HighlightSpan>) {
    let mut pipe_start: Option<usize> = None;
    for (index, value) in line.chars().enumerate() {
        if value != '|' {
            continue;
        }

        if let Some(start) = pipe_start {
            if index > start + 1 {
                spans.push(HighlightSpan::new(
                    line_offset + start,
                    line_offset + index + 1,
                    HighlightKind::Label,
                ));
            }
            pipe_start = None;
            continue;
        }

        pipe_start = Some(index);
    }
}

fn is_word_char(value: char) -> bool {
    value.is_ascii_alphanumeric() || value == '_' || value == '-'
}

fn is_mermaid_keyword(token: &str) -> bool {
    MERMAID_KEYWORDS
        .iter()
        .any(|keyword| keyword.eq_ignore_ascii_case(token))
}

fn span_kind_rank(kind: HighlightKind) -> u8 {
    match kind {
        HighlightKind::Comment => 0,
        HighlightKind::Keyword => 1,
        HighlightKind::Operator => 2,
        HighlightKind::Label => 3,
    }
}

#[cfg(test)]
mod tests {
    use super::{auto_indent_insertion, highlight_spans, leading_indentation, HighlightKind};

    #[test]
    fn highlights_mermaid_tokens() {
        let source = "flowchart TD\nA -->|yes| B\n";
        let spans = highlight_spans(source);

        assert!(contains_span_text(
            source,
            &spans,
            HighlightKind::Keyword,
            "flowchart"
        ));
        assert!(contains_span_text(
            source,
            &spans,
            HighlightKind::Keyword,
            "TD"
        ));
        assert!(contains_span_text(
            source,
            &spans,
            HighlightKind::Operator,
            "-->"
        ));
        assert!(contains_span_text(
            source,
            &spans,
            HighlightKind::Label,
            "|yes|"
        ));
    }

    #[test]
    fn treats_comment_lines_as_comment_only() {
        let source = "%% flowchart TD -->|yes|\n";
        let spans = highlight_spans(source);

        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].kind, HighlightKind::Comment);
        assert_eq!(
            slice_chars(source, spans[0].start, spans[0].end),
            "%% flowchart TD -->|yes|"
        );
    }

    #[test]
    fn returns_char_offsets_for_unicode_content() {
        let source = "😀 flowchart TD\n";
        let spans = highlight_spans(source);

        let flowchart_span = spans
            .iter()
            .find(|span| {
                span.kind == HighlightKind::Keyword
                    && slice_chars(source, span.start, span.end) == "flowchart"
            })
            .expect("flowchart keyword span must exist");

        assert_eq!(flowchart_span.start, 2);
    }

    #[test]
    fn preserves_space_and_tab_indentation() {
        assert_eq!(leading_indentation("    line"), "    ");
        assert_eq!(leading_indentation("\t\tline"), "\t\t");
        assert_eq!(leading_indentation("  \t line"), "  \t ");
    }

    #[test]
    fn auto_indent_inserts_newline_plus_leading_whitespace() {
        assert_eq!(auto_indent_insertion("    abc"), "\n    ");
        assert_eq!(auto_indent_insertion("\t\tabc"), "\n\t\t");
        assert_eq!(auto_indent_insertion("abc"), "\n");
    }

    fn contains_span_text(
        source: &str,
        spans: &[super::HighlightSpan],
        kind: HighlightKind,
        want: &str,
    ) -> bool {
        spans
            .iter()
            .filter(|span| span.kind == kind)
            .any(|span| slice_chars(source, span.start, span.end) == want)
    }

    fn slice_chars(source: &str, start: usize, end: usize) -> String {
        source.chars().skip(start).take(end - start).collect()
    }
}
