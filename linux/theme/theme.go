// Package theme provides the Mermaid theme catalog and JS config generation.
package theme

import (
	"fmt"
	"strings"
)

// DefaultThemeID is the fallback theme identifier.
const DefaultThemeID = "default"

// ThemeInfo describes a single Mermaid theme.
type ThemeInfo struct {
	ID                string
	Label             string
	PreviewBackground string
	ErrorColor        string
}

type themeDef struct {
	ThemeInfo
	variables [][2]string
}

var catppuccinVars = [][2]string{
	{"primaryColor", "#89b4fa"},
	{"primaryBorderColor", "#74c7ec"},
	{"secondaryColor", "#cba6f7"},
	{"secondaryBorderColor", "#b4befe"},
	{"tertiaryColor", "#a6e3a1"},
	{"tertiaryBorderColor", "#94e2d5"},
	{"lineColor", "#bac2de"},
	{"textColor", "#cdd6f4"},
}

var draculaVars = [][2]string{
	{"primaryColor", "#bd93f9"},
	{"primaryBorderColor", "#6272a4"},
	{"secondaryColor", "#ff79c6"},
	{"secondaryBorderColor", "#ff79c6"},
	{"tertiaryColor", "#50fa7b"},
	{"tertiaryBorderColor", "#50fa7b"},
	{"lineColor", "#f8f8f2"},
	{"textColor", "#f8f8f2"},
}

var nordVars = [][2]string{
	{"primaryColor", "#5e81ac"},
	{"primaryBorderColor", "#4c566a"},
	{"secondaryColor", "#a3be8c"},
	{"secondaryBorderColor", "#4c566a"},
	{"tertiaryColor", "#d08770"},
	{"tertiaryBorderColor", "#4c566a"},
	{"lineColor", "#4c566a"},
	{"textColor", "#2e3440"},
}

var synthwaveVars = [][2]string{
	{"primaryColor", "#f72585"},
	{"primaryBorderColor", "#ff6ec7"},
	{"secondaryColor", "#7209b7"},
	{"secondaryBorderColor", "#b5179e"},
	{"tertiaryColor", "#4361ee"},
	{"tertiaryBorderColor", "#4cc9f0"},
	{"lineColor", "#ff6ec7"},
	{"textColor", "#f0e6ff"},
}

var roseVars = [][2]string{
	{"primaryColor", "#e11d48"},
	{"primaryBorderColor", "#be123c"},
	{"secondaryColor", "#fb7185"},
	{"secondaryBorderColor", "#f43f5e"},
	{"tertiaryColor", "#fda4af"},
	{"tertiaryBorderColor", "#fb7185"},
	{"lineColor", "#881337"},
	{"textColor", "#4c0519"},
}

var oceanVars = [][2]string{
	{"primaryColor", "#0077b6"},
	{"primaryBorderColor", "#023e8a"},
	{"secondaryColor", "#00b4d8"},
	{"secondaryBorderColor", "#0096c7"},
	{"tertiaryColor", "#48cae4"},
	{"tertiaryBorderColor", "#0096c7"},
	{"lineColor", "#03045e"},
	{"textColor", "#03045e"},
}

var solarizedVars = [][2]string{
	{"primaryColor", "#268bd2"},
	{"primaryBorderColor", "#2aa198"},
	{"secondaryColor", "#859900"},
	{"secondaryBorderColor", "#859900"},
	{"tertiaryColor", "#b58900"},
	{"tertiaryBorderColor", "#cb4b16"},
	{"lineColor", "#586e75"},
	{"textColor", "#657b83"},
}

var themes = []themeDef{
	{ThemeInfo: ThemeInfo{ID: "default", Label: "Default", PreviewBackground: "#ffffff", ErrorColor: "#b91c1c"}},
	{ThemeInfo: ThemeInfo{ID: "dark", Label: "Dark", PreviewBackground: "#333333", ErrorColor: "#f38ba8"}},
	{ThemeInfo: ThemeInfo{ID: "forest", Label: "Forest", PreviewBackground: "#ffffff", ErrorColor: "#b91c1c"}},
	{ThemeInfo: ThemeInfo{ID: "neutral", Label: "Neutral", PreviewBackground: "#ffffff", ErrorColor: "#b91c1c"}},
	{ThemeInfo: ThemeInfo{ID: "catppuccin", Label: "Catppuccin", PreviewBackground: "#1e1e2e", ErrorColor: "#f38ba8"}, variables: catppuccinVars},
	{ThemeInfo: ThemeInfo{ID: "dracula", Label: "Dracula", PreviewBackground: "#282a36", ErrorColor: "#f38ba8"}, variables: draculaVars},
	{ThemeInfo: ThemeInfo{ID: "nord", Label: "Nord", PreviewBackground: "#eceff4", ErrorColor: "#b91c1c"}, variables: nordVars},
	{ThemeInfo: ThemeInfo{ID: "synthwave", Label: "Synthwave", PreviewBackground: "#1a1a2e", ErrorColor: "#f38ba8"}, variables: synthwaveVars},
	{ThemeInfo: ThemeInfo{ID: "rose", Label: "Rose", PreviewBackground: "#fff1f2", ErrorColor: "#b91c1c"}, variables: roseVars},
	{ThemeInfo: ThemeInfo{ID: "ocean", Label: "Ocean", PreviewBackground: "#eaf8ff", ErrorColor: "#b91c1c"}, variables: oceanVars},
	{ThemeInfo: ThemeInfo{ID: "solarized", Label: "Solarized", PreviewBackground: "#fdf6e3", ErrorColor: "#b91c1c"}, variables: solarizedVars},
}

// Themes returns the full list of available theme descriptors.
func Themes() []ThemeInfo {
	out := make([]ThemeInfo, len(themes))
	for i, td := range themes {
		out[i] = td.ThemeInfo
	}
	return out
}

// NormalizeThemeID returns themeID if it matches a known theme, otherwise DefaultThemeID.
func NormalizeThemeID(themeID string) string {
	for _, td := range themes {
		if td.ID == themeID {
			return td.ID
		}
	}
	return DefaultThemeID
}

// MermaidConfigJS generates the JS configuration object literal for mermaid.initialize().
func MermaidConfigJS(themeID string) string {
	td := findTheme(themeID)

	parts := []string{
		`startOnLoad: false`,
		`securityLevel: "strict"`,
	}

	switch {
	case td.variables != nil:
		parts = append(parts, `theme: "base"`)
		varParts := make([]string, len(td.variables))
		for i, kv := range td.variables {
			varParts[i] = fmt.Sprintf(`%s: "%s"`, kv[0], kv[1])
		}
		parts = append(parts, fmt.Sprintf("themeVariables: { %s }", strings.Join(varParts, ", ")))
	default:
		parts = append(parts, fmt.Sprintf(`theme: "%s"`, td.ID))
	}

	return fmt.Sprintf("{ %s }", strings.Join(parts, ", "))
}

func findTheme(themeID string) themeDef {
	for _, td := range themes {
		if td.ID == themeID {
			return td
		}
	}
	return themes[0]
}
