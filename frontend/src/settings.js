const STORAGE_KEY = "dia-settings";

const DEFAULTS = {
    fontFamily: "monospace",
    fontSize: 14,
    diagramTheme: "default",
};

export const FONT_OPTIONS = [
    "monospace",
    "JetBrains Mono",
    "Fira Code",
    "Source Code Pro",
    "Cascadia Code",
    "Ubuntu Mono",
];

// Each theme has:
//   value/label    — identifier + display name
//   previewBg      — background color for the preview pane
//   themeVariables  — (custom only) passed to Mermaid's "base" theme
//
// Custom themes deliberately omit *TextColor / nodeTextColor so Mermaid's
// auto-contrast derivation (via khroma) picks readable text for each fill.
export const THEME_OPTIONS = [
    // Built-in Mermaid themes
    { value: "default", label: "Default", previewBg: "#ffffff" },
    { value: "dark", label: "Dark", previewBg: "#333333" },
    { value: "forest", label: "Forest", previewBg: "#ffffff" },
    { value: "neutral", label: "Neutral", previewBg: "#ffffff" },

    // Custom themes (Mermaid "base" + themeVariables)
    {
        value: "catppuccin", label: "Catppuccin",
        previewBg: "#1e1e2e",
        themeVariables: {
            primaryColor: "#89b4fa",
            primaryBorderColor: "#74c7ec",
            secondaryColor: "#cba6f7",
            secondaryBorderColor: "#b4befe",
            tertiaryColor: "#a6e3a1",
            tertiaryBorderColor: "#94e2d5",
            lineColor: "#bac2de",
            textColor: "#cdd6f4",
        },
    },
    {
        value: "dracula", label: "Dracula",
        previewBg: "#282a36",
        themeVariables: {
            primaryColor: "#bd93f9",
            primaryBorderColor: "#6272a4",
            secondaryColor: "#ff79c6",
            secondaryBorderColor: "#ff79c6",
            tertiaryColor: "#50fa7b",
            tertiaryBorderColor: "#50fa7b",
            lineColor: "#f8f8f2",
            textColor: "#f8f8f2",
        },
    },
    {
        value: "nord", label: "Nord",
        previewBg: "#eceff4",
        themeVariables: {
            primaryColor: "#5e81ac",
            primaryBorderColor: "#4c566a",
            secondaryColor: "#a3be8c",
            secondaryBorderColor: "#4c566a",
            tertiaryColor: "#d08770",
            tertiaryBorderColor: "#4c566a",
            lineColor: "#4c566a",
            textColor: "#2e3440",
        },
    },
    {
        value: "synthwave", label: "Synthwave",
        previewBg: "#1a1a2e",
        themeVariables: {
            primaryColor: "#f72585",
            primaryBorderColor: "#ff6ec7",
            secondaryColor: "#7209b7",
            secondaryBorderColor: "#b5179e",
            tertiaryColor: "#4361ee",
            tertiaryBorderColor: "#4cc9f0",
            lineColor: "#ff6ec7",
            textColor: "#f0e6ff",
        },
    },
    {
        value: "rose", label: "Rose",
        previewBg: "#fff1f2",
        themeVariables: {
            primaryColor: "#e11d48",
            primaryBorderColor: "#be123c",
            secondaryColor: "#fb7185",
            secondaryBorderColor: "#f43f5e",
            tertiaryColor: "#fda4af",
            tertiaryBorderColor: "#fb7185",
            lineColor: "#881337",
            textColor: "#4c0519",
        },
    },
    {
        value: "ocean", label: "Ocean",
        previewBg: "#eaf8ff",
        themeVariables: {
            primaryColor: "#0077b6",
            primaryBorderColor: "#023e8a",
            secondaryColor: "#00b4d8",
            secondaryBorderColor: "#0096c7",
            tertiaryColor: "#48cae4",
            tertiaryBorderColor: "#0096c7",
            lineColor: "#03045e",
            textColor: "#03045e",
        },
    },
    {
        value: "solarized", label: "Solarized",
        previewBg: "#fdf6e3",
        themeVariables: {
            primaryColor: "#268bd2",
            primaryBorderColor: "#2aa198",
            secondaryColor: "#859900",
            secondaryBorderColor: "#859900",
            tertiaryColor: "#b58900",
            tertiaryBorderColor: "#cb4b16",
            lineColor: "#586e75",
            textColor: "#657b83",
        },
    },
];

export function themeEntry(themeValue) {
    return THEME_OPTIONS.find((t) => t.value === themeValue) || THEME_OPTIONS[0];
}

export function mermaidConfig(themeValue) {
    const entry = themeEntry(themeValue);
    const config = { startOnLoad: false, securityLevel: "strict" };
    if (entry.themeVariables) {
        config.theme = "base";
        config.themeVariables = entry.themeVariables;
    } else {
        config.theme = themeValue;
    }
    return config;
}

export function load() {
    try {
        const raw = localStorage.getItem(STORAGE_KEY);
        if (!raw) return { ...DEFAULTS };
        return { ...DEFAULTS, ...JSON.parse(raw) };
    } catch {
        return { ...DEFAULTS };
    }
}

export function save(settings) {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(settings));
}
